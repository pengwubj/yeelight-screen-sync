import Foundation
import SwiftUI
import ScreenCaptureKit

actor FakeTransport: LightTransport {
    private(set) var commands = [String]()
    private(set) var closes = 0
    private(set) var sideEffects = 0
    private var main = "off", background = "off"
    func command(ip: String, method: String, params: [Any]) throws -> [String] {
        commands.append(method)
        sideEffects += 1
        if method == "get_prop" {
            let state = ["main_power":main,"power":main,"bright":"100","ct":"4000",
                         "bg_power":background,"bg_bright":"100","bg_rgb":"16711680"]
            return params.map { state[$0 as? String ?? ""] ?? "" }
        }
        if method == "set_power" { main = params[0] as! String; background = main }
        if method == "bg_set_power" { background = params[0] as! String }
        return ["ok"]
    }
    func discover() -> [DiscoveredLight] { sideEffects += 1; return [] }
    func openSession(ip: String, generation: Int) { sideEffects += 1 }
    func sendColor(_ color: RGB, generation: Int) { sideEffects += 1 }
    func heartbeat(generation: Int) { sideEffects += 1 }
    func closeSession() { closes += 1; sideEffects += 1 }
}

@MainActor final class FakeSampler: ScreenSampling {
    private(set) var stops = 0
    private(set) var starts = 0
    func start(display: SCDisplay, fps: Int, onColor: @escaping @Sendable (RGB) -> Void,
               onError: @escaping @Sendable (String) -> Void) async throws {
        starts += 1
        throw LightFailure("Tests must not capture the real screen")
    }
    func stop() async {
        stops += 1
        try? await Task.sleep(nanoseconds:20_000_000)
    }
}

@main @MainActor struct ModelCheck {
    static func main() async throws {
        let transport = FakeTransport(), sampler = FakeSampler()
        let model = LightModel(client:transport,sampler:sampler,demo:false)
        model.ip = "192.0.2.42"
        model.syncing = true
        async let first: Void = model.stopSync()
        async let second: Void = model.stopSync()
        _ = await (first,second)
        let closes = await transport.closes
        precondition(!model.busy && !model.syncing && sampler.stops == 1 && closes == 1,
                     "Concurrent stop must clean up once and release the busy state")

        model.operation { try await Task.sleep(nanoseconds:80_000_000) }
        model.syncing = true
        await model.stopSync()
        precondition(model.busy,"In-flight manual operation must remain busy")
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(!model.busy,"Busy state must clear after both operations finish")

        model.connected = true
        model.chooseColor(.red)
        model.ip = "192.0.2.43"
        model.endpointChanged()
        try await Task.sleep(nanoseconds:400_000_000)
        let commandsBefore = await transport.commands
        precondition(commandsBefore.isEmpty,"Queued colour must not target a different device")

        model.connected = true
        model.mainPower()
        try await Task.sleep(nanoseconds:80_000_000)
        precondition(model.mainOn && !model.ambientOn,"Main switch must preserve ambient power")

        let demoTransport = FakeTransport(), demoSampler = FakeSampler()
        let demo = LightModel(client:demoTransport,sampler:demoSampler,demo:true)
        demo.connect(); demo.discover(); demo.mainPower(); demo.ambientPower()
        demo.chooseColor(.blue); demo.setValue("bg_set_bright",value:50)
        try await demo.readState()
        try await demo.updateDisplays()
        demo.startSync()
        precondition(demo.syncing && demo.ip == "192.0.2.42")
        await demo.stopSync()
        let demoSideEffects = await demoTransport.sideEffects
        precondition(demoSideEffects == 0 && demoSampler.starts == 0 && demoSampler.stops == 0,
                     "Demo must perform no network or screen operations")
        print("PASS: concurrent stop, overlapping operation, device switch, channel preservation, offline demo")
    }
}
