import SwiftUI
import AppKit
import ScreenCaptureKit

@MainActor final class LightModel: ObservableObject {
    @Published var ip: String
    @Published var connected = false
    @Published var busy = false
    @Published var status = "连接挂灯，开始控制"
    @Published var errorMessage: String?
    @Published var mainOn = false
    @Published var mainBrightness = 100.0
    @Published var temperature = 4000.0
    @Published var ambientOn = false
    @Published var ambientBrightness = 100.0
    @Published var ambientColor = Color.red
    @Published var devices: [DiscoveredLight] = []
    @Published var displays: [SCDisplay] = []
    @Published var selectedDisplay: UInt32 = 0
    @Published var fps = 10.0
    @Published var smoothing = 0.25
    @Published var syncing = false
    @Published var preview = RGB(255,0,0)
    @Published var sentFrames = 0
    @Published var permissionMissing = false

    let isDemo: Bool
    let client: any LightTransport
    private let sampler: any ScreenSampling
    private var heartbeatTask: Task<Void,Never>?
    private var colorLoop: Task<Void,Never>?
    private var generation = 0
    private var previousColor: RGB?
    private var sending = false
    private var lastSent: RGB?
    private var colorTask: Task<Void,Never>?
    private var targetColor: RGB?
    private var stoppingSync = false
    private var operationInProgress = false
    private var captureError: String?

    init(client: (any LightTransport)? = nil, sampler: (any ScreenSampling)? = nil,
         demo: Bool = CommandLine.arguments.contains("--demo")) {
        self.client = client ?? LightClient()
        self.sampler = sampler ?? ScreenSampler()
        self.isDemo = demo
        self.ip = demo ? "192.0.2.42" : UserDefaults.standard.string(forKey:"lightIP") ?? ""
        if demo {
            connected = true; mainOn = true; ambientOn = true
            mainBrightness = 80; ambientBrightness = 70
            ambientColor = RGB(packed:0x6384ff).color
            status = "演示模式 · 示例数据，不访问设备或屏幕"
        }
    }

    private func updateBusy() { busy = operationInProgress || stoppingSync }

    func endpointChanged() {
        colorTask?.cancel(); colorTask = nil
        connected = isDemo
    }

    func operation(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        operationInProgress = true
        updateBusy()
        errorMessage = nil
        Task {
            defer { operationInProgress = false; updateBusy() }
            do { try await action() }
            catch { errorMessage = error.localizedDescription; status = "操作未完成" }
        }
    }

    func readState() async throws {
        if isDemo { return }
        let names = ["main_power","power","bright","ct","bg_power","bg_bright","bg_rgb"]
        let result = try await client.command(ip:ip,method:"get_prop",params:names)
        guard result.count == names.count else { throw LightFailure("设备状态回应不完整") }
        mainOn = (result[0].isEmpty ? result[1] : result[0]) == "on"
        mainBrightness = Double(result[2]) ?? 100
        temperature = Double(result[3]) ?? 4000
        ambientOn = result[4] == "on"
        ambientBrightness = Double(result[5]) ?? 100
        if let packed = Int(result[6]) { ambientColor = RGB(packed:packed).color }
        connected = true
        UserDefaults.standard.set(ip,forKey:"lightIP")
        status = syncing ? "屏幕同步中" : "已连接 · \(ip)"
    }

    func connect() {
        if isDemo { return }
        guard !ip.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            errorMessage = "请先输入挂灯 IP，或点击搜索设备"
            return
        }
        operation { [self] in
            connected = false
            do { try await readState() }
            catch {
                // Retry a read after discovery if the first network access was denied.
                _ = try? await client.discover()
                try await readState()
            }
        }
    }

    func discover() {
        if isDemo { return }
        operation { [self] in
            status = "正在搜索局域网…"
            devices = try await client.discover()
            guard !devices.isEmpty else { throw LightFailure("未发现设备，请检查 Yeelight App 中的局域网控制") }
            if devices.count == 1 { ip = devices[0].ip; try await readState() }
            else { status = "发现 \(devices.count) 台设备，请选择" }
        }
    }

    func mainPower() {
        if isDemo { mainOn.toggle(); return }
        operation { [self] in
            // Firmware may link master power with both channels. Preserve ambient power.
            let values = try await client.command(ip:ip,method:"get_prop",params:["main_power","bg_power"])
            guard values.count == 2 else { throw LightFailure("无法读取双通道状态") }
            let target = values[0] == "on" ? "off" : "on"
            _ = try await client.command(ip:ip,method:"set_power",params:[target,"sudden",0])
            _ = try await client.command(ip:ip,method:"bg_set_power",params:[values[1],"sudden",0])
            try await readState()
        }
    }

    func ambientPower() {
        guard !syncing else { return }
        if isDemo { ambientOn.toggle(); return }
        operation { [self] in
            _ = try await client.command(ip:ip,method:"bg_set_power",params:[ambientOn ? "off" : "on","sudden",0])
            try await readState()
        }
    }

    func setValue(_ method: String, value: Int) {
        if isDemo { return }
        operation { [self] in
            _ = try await client.command(ip:ip,method:method,params:[value,"smooth",300])
            // Smooth commands acknowledge before the transition finishes.
            try await Task.sleep(nanoseconds:350_000_000)
            try await readState()
        }
    }

    func chooseColor(_ color: Color) {
        guard !syncing else { return }
        ambientColor = color
        if isDemo { return }
        colorTask?.cancel()
        let targetIP = ip
        colorTask = Task {
            do {
                try await Task.sleep(nanoseconds:350_000_000)
                while busy { try await Task.sleep(nanoseconds:100_000_000) }
                guard !syncing, connected, ip == targetIP else { return }
                setValue("bg_set_rgb",value:RGB(color:color).packed)
            } catch {}
        }
    }

    func loadDisplays() {
        operation { [self] in try await updateDisplays() }
    }

    func updateDisplays() async throws {
        if isDemo { return }
        if !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
            permissionMissing = true
            throw LightFailure("需要屏幕录制权限。请在系统设置中允许 Yeelight Screen Sync，然后重新打开 App")
        }
        do {
            displays = try await ScreenSampler.displays()
            permissionMissing = false
            if !displays.contains(where:{$0.displayID == selectedDisplay}) { selectedDisplay = displays.first?.displayID ?? 0 }
        } catch {
            permissionMissing = !CGPreflightScreenCaptureAccess()
            if permissionMissing { throw LightFailure("需要屏幕录制权限。请在系统设置中允许 Yeelight Screen Sync，然后重新打开 App") }
            throw error
        }
    }

    func startSync() {
        guard connected, !syncing else { return }
        colorTask?.cancel(); colorTask = nil
        if isDemo {
            syncing = true; ambientOn = true; preview = RGB(packed:0x6384ff)
            sentFrames = 128; status = "演示模式 · 屏幕同步效果预览"
            return
        }
        operation { [self] in
            generation += 1
            let current = generation
            targetColor = nil
            captureError = nil
            do {
                try await updateDisplays()
                guard let display = displays.first(where:{$0.displayID == selectedDisplay}) else { throw LightFailure("没有可用的屏幕") }
                try await client.openSession(ip:ip,generation:current)
                try await sampler.start(display:display,fps:Int(fps),onColor:{ [weak self] color in
                    Task { @MainActor in self?.received(color,generation:current) }
                },onError:{ [weak self] message in
                    Task { @MainActor in
                        guard let self, self.generation == current else { return }
                        self.captureError = message
                        guard self.syncing else { return }
                        await self.stopSync()
                        self.errorMessage = "屏幕采集中断：\(message)"
                    }
                })
                _ = try await client.command(ip:ip,method:"bg_set_power",params:["on","sudden",0])
                _ = try await client.command(ip:ip,method:"bg_set_bright",params:[Int(ambientBrightness),"sudden",0])
                if let captureError { throw LightFailure("屏幕采集中断：\(captureError)") }
                previousColor = nil; lastSent = nil; sentFrames = 0
                syncing = true; ambientOn = true; status = "屏幕同步中"
                let interval = UInt64(1_000_000_000 / fps)
                colorLoop = Task { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(nanoseconds:interval)
                            guard let self, self.syncing, self.generation == current else { return }
                            await self.renderColor(generation:current)
                        } catch { return }
                    }
                }
                heartbeatTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(nanoseconds:1_000_000_000)
                            guard let self, self.syncing, self.generation == current else { return }
                            try await self.client.heartbeat(generation:current)
                        } catch is CancellationError { return }
                        catch {
                            guard let self else { return }
                            await self.stopSync()
                            self.errorMessage = error.localizedDescription
                            return
                        }
                    }
                }
            } catch {
                await sampler.stop()
                await client.closeSession()
                throw error
            }
        }
    }

    private func received(_ color: RGB, generation current: Int) {
        guard current == generation else { return }
        targetColor = color
    }

    private func renderColor(generation current: Int) async {
        guard syncing, current == generation, let color = targetColor else { return }
        let smoothed = previousColor?.blended(with:color,amount:smoothing) ?? color
        previousColor = smoothed
        if preview.packed != smoothed.packed { preview = smoothed }
        guard !sending, lastSent?.packed != smoothed.packed else { return }
        sending = true
        defer { sending = false }
        do {
            try await client.sendColor(smoothed,generation:current)
            guard syncing, current == generation else { return }
            lastSent = smoothed; sentFrames += 1; ambientColor = smoothed.color
        } catch {
            guard current == generation else { return }
            await stopSync()
            errorMessage = error.localizedDescription
        }
    }

    func stopSync() async {
        guard !stoppingSync else { return }
        stoppingSync = true
        updateBusy()
        defer { stoppingSync = false; updateBusy() }
        generation += 1
        syncing = false
        heartbeatTask?.cancel(); heartbeatTask = nil
        colorLoop?.cancel(); colorLoop = nil
        targetColor = nil
        if !isDemo {
            await sampler.stop()
            await client.closeSession()
        }
        status = isDemo ? "演示模式 · 同步已停止" : "同步已停止 · 保留最后的灯光颜色"
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

extension RGB {
    var color: Color { Color(red:r/255,green:g/255,blue:b/255) }
    init(color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .red
        self.init(c.redComponent*255,c.greenComponent*255,c.blueComponent*255)
    }
}
