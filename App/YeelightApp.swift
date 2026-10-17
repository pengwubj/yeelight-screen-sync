import SwiftUI
import AppKit
import ScreenCaptureKit

struct ControlCard<Content:View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Label(title,systemImage:symbol).font(.system(size:17,weight:.semibold))
            content
        }
        .padding(22)
        .frame(maxWidth:.infinity,alignment:.topLeading)
        .background(Color.white.opacity(0.055),in:RoundedRectangle(cornerRadius:20))
        .overlay(RoundedRectangle(cornerRadius:20).strokeBorder(Color.white.opacity(0.08)))
    }
}

struct ContentView: View {
    @EnvironmentObject var model: LightModel
    private let amber = Color(red:1,green:0.72,blue:0.36)
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:8) {
                        Text("YEELIGHT").font(.system(size:11,weight:.bold,design:.rounded)).tracking(4).foregroundStyle(amber)
                        Text("灯光与屏幕同步").font(.system(size:30,weight:.semibold))
                        Text("桌面照明，随画面变换的氛围。").font(.system(size:13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing:7) {
                        Circle().fill(model.connected ? Color.green : .gray).frame(width:7,height:7)
                        Text(model.syncing ? "同步中" : (model.connected ? "已连接" : "未连接")).font(.system(size:12,weight:.medium))
                    }.padding(.horizontal,12).padding(.vertical,8).background(.white.opacity(0.07),in:Capsule())
                }
                HStack(spacing:10) {
                    Image(systemName:"wifi").foregroundStyle(.secondary)
                    TextField("挂灯 IP 地址",text:$model.ip).textFieldStyle(.roundedBorder).frame(width:170)
                        .disabled(model.busy || model.syncing)
                        .onSubmit { model.connect() }
                        .onChange(of:model.ip) { model.endpointChanged() }
                    Button("连接") { model.connect() }.disabled(model.busy || model.syncing)
                    Button("搜索设备") { model.discover() }.disabled(model.busy || model.syncing)
                    if model.devices.count > 1 {
                        Menu("选择设备") {
                            ForEach(model.devices) { light in
                                Button("\(light.model) · \(light.ip)") { model.ip = light.ip; model.connect() }
                            }
                        }.disabled(model.busy || model.syncing)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button { model.operation { try await model.readState() } } label: { Image(systemName:"arrow.clockwise") }
                        .help("读取设备状态").disabled(!model.connected || model.busy)
                }
                HStack(alignment:.top,spacing:18) {
                    ControlCard(title:"主灯",symbol:"light.overhead.right") {
                        powerRow(isOn:model.mainOn) { model.mainPower() }
                        valueSlider("亮度",value:$model.mainBrightness,range:1...100,valueText:"\(Int(model.mainBrightness))%",disabled:!model.mainOn) {
                            model.setValue("set_bright",value:Int(model.mainBrightness))
                        }
                        valueSlider("色温",value:$model.temperature,range:2700...6500,valueText:"\(Int(model.temperature)) K",disabled:!model.mainOn) {
                            model.setValue("set_ct_abx",value:Int(model.temperature))
                        }
                        HStack { Text("暖光"); Spacer(); Text("冷光") }.font(.system(size:11)).foregroundStyle(.secondary)
                    }
                    ControlCard(title:"氛围灯",symbol:"light.beacon.max") {
                        powerRow(isOn:model.ambientOn,disabled:model.syncing) { model.ambientPower() }
                        valueSlider("亮度",value:$model.ambientBrightness,range:1...100,valueText:"\(Int(model.ambientBrightness))%",disabled:!model.ambientOn) {
                            model.setValue("bg_set_bright",value:Int(model.ambientBrightness))
                        }
                        ColorPicker("颜色",selection:Binding(get:{model.ambientColor},set:{model.chooseColor($0)}),supportsOpacity:false)
                            .disabled(!model.connected || model.busy || model.syncing || !model.ambientOn)
                        HStack(spacing:12) {
                            ForEach(Array([0xff0000,0xff8800,0x00ff00,0x00ffff,0x0000ff,0x9900ff,0xffffff].enumerated()),id:\.offset) { index,hex in
                                Button { model.chooseColor(RGB(packed:hex).color) } label: {
                                    Circle().fill(RGB(packed:hex).color).frame(width:23,height:23).overlay(Circle().stroke(.white.opacity(0.2)))
                                }.buttonStyle(.plain).accessibilityLabel(["红色","橙色","绿色","青色","蓝色","紫色","白色"][index])
                            }
                        }.disabled(!model.connected || model.busy || model.syncing || !model.ambientOn)
                    }
                }
                ControlCard(title:"屏幕主色同步",symbol:"display") {
                    HStack(alignment:.top,spacing:22) {
                        RoundedRectangle(cornerRadius:16)
                            .fill(model.syncing ? model.preview.color.gradient : Color.white.opacity(0.07).gradient)
                            .frame(width:120,height:115)
                            .overlay(VStack(spacing:8) {
                                Image(systemName:model.syncing ? "waveform.path" : "display").font(.system(size:26))
                                Text(model.syncing ? model.preview.hex : "等待同步").font(.system(size:12,weight:.medium,design:.monospaced))
                            }.foregroundStyle(model.syncing && max(model.preview.r,model.preview.g,model.preview.b) > 140 ? Color.black.opacity(0.7) : .white))
                        VStack(alignment:.leading,spacing:14) {
                            HStack {
                                Text("采集屏幕").foregroundStyle(.secondary)
                                Picker("采集屏幕",selection:$model.selectedDisplay) {
                                    if model.displays.isEmpty { Text(model.isDemo ? "演示显示器 · 2560×1440" : "默认主屏幕").tag(UInt32(0)) }
                                    ForEach(model.displays,id:\.displayID) { display in
                                        Text(displayName(display)).tag(display.displayID)
                                    }
                                }.labelsHidden().frame(maxWidth:260).disabled(model.syncing || model.busy)
                                Button { model.loadDisplays() } label:{ Image(systemName:"arrow.clockwise") }.help("获取屏幕列表").disabled(model.syncing || model.busy)
                            }
                            HStack {
                                Text("更新频率").foregroundStyle(.secondary)
                                Picker("更新频率",selection:$model.fps) {
                                    Text("5 次/秒").tag(5.0)
                                    Text("10 次/秒").tag(10.0)
                                    Text("20 次/秒").tag(20.0)
                                }.labelsHidden().pickerStyle(.segmented).frame(width:280).disabled(model.syncing || model.busy)
                            }
                            HStack {
                                Text("平滑过渡").foregroundStyle(.secondary)
                                Text("柔和").font(.system(size:11)).foregroundStyle(.secondary)
                                Slider(value:$model.smoothing,in:0.08...0.8).frame(maxWidth:190)
                                Text("灵敏").font(.system(size:11)).foregroundStyle(.secondary)
                            }
                        }.font(.system(size:12))
                        Spacer(minLength:0)
                    }
                    HStack {
                        VStack(alignment:.leading,spacing:4) {
                            Text(model.syncing ? "\(model.isDemo ? "模拟" : "已发送") \(model.sentFrames) 次颜色更新" : "提取画面主色，自动更新氛围灯").font(.system(size:13))
                            Text("画面仅在本机内存处理 · 不保存截图 · 停止后保留最后颜色").font(.system(size:11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            if model.syncing { model.operation { await model.stopSync() } }
                            else { model.startSync() }
                        } label: {
                            Label(model.syncing ? "停止同步" : "开始同步",systemImage:model.syncing ? "stop.fill" : "play.fill")
                                .padding(.horizontal,12).padding(.vertical,7)
                        }.buttonStyle(.borderedProminent).tint(model.syncing ? .red : amber).foregroundStyle(.black)
                            .disabled(!model.connected || model.busy)
                    }
                }
                if let error = model.errorMessage {
                    HStack(alignment:.top) {
                        Image(systemName:"exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(error).font(.system(size:12)).textSelection(.enabled)
                        Spacer()
                        if model.permissionMissing { Button("打开系统设置") { model.openPrivacySettings() } }
                        Button { model.errorMessage = nil } label:{ Image(systemName:"xmark") }.buttonStyle(.plain)
                    }.padding(12).background(.orange.opacity(0.1),in:RoundedRectangle(cornerRadius:12))
                }
                HStack {
                    Text(model.status)
                    Spacer()
                    Text("局域网直连 · 主灯与氛围灯独立控制")
                }.font(.system(size:11)).foregroundStyle(.secondary)
            }.padding(30)
        }
        .background(LinearGradient(colors:[Color(red:0.075,green:0.09,blue:0.13),Color(red:0.045,green:0.05,blue:0.075)],startPoint:.topLeading,endPoint:.bottomTrailing))
        .preferredColorScheme(.dark)
        .frame(minWidth:820,minHeight:710)
        .task { if !model.connected && !model.ip.isEmpty { model.connect() } }
    }

    private func displayName(_ display: SCDisplay) -> String {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == display.displayID }
        return "\(screen?.localizedName ?? "显示器") · \(display.width)×\(display.height)"
    }

    private func powerRow(isOn: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            Text(isOn ? "已开启" : "已关闭").foregroundStyle(isOn ? .primary : .secondary)
            Spacer()
            Button(action:action) {
                Image(systemName:"power").font(.system(size:18,weight:.medium)).frame(width:44,height:34)
            }.buttonStyle(.bordered).tint(isOn ? amber : .gray)
                .disabled(!model.connected || model.busy || disabled)
                .accessibilityLabel(isOn ? "关闭灯光" : "开启灯光")
        }
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, valueText: String, disabled: Bool, commit: @escaping () -> Void) -> some View {
        VStack(spacing:7) {
            HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(valueText).monospacedDigit() }.font(.system(size:12))
            Slider(value:value,in:range,step:1,onEditingChanged:{ editing in if !editing { commit() } })
                .tint(amber).disabled(!model.connected || model.busy || disabled)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps:true) }
}

@main struct YeelightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = LightModel()
    init() {
        if CommandLine.arguments.contains("--self-test") { CoreTests.run(); exit(0) }
    }
    var body: some Scene {
        WindowGroup("Yeelight 控制台") { ContentView().environmentObject(model) }
            .defaultSize(width:900,height:780)
            .commands {
                CommandGroup(replacing:.newItem) {}
                CommandMenu("灯光") {
                    Button("刷新状态") { model.operation { try await model.readState() } }.keyboardShortcut("r")
                    Button("停止屏幕同步") { model.operation { await model.stopSync() } }.keyboardShortcut(".")
                        .disabled(!model.syncing)
                }
            }
    }
}
