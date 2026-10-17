import Foundation

@main struct TransportCheck {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 5, args[1] == "127.0.0.1",
                  let tcp = UInt16(args[2]), let udp = UInt16(args[3]) else {
                throw LightFailure("Test harness accepts loopback and explicit test ports only")
            }
            let mode = args[4]
            let client = LightClient(tcpPort:tcp,udpPort:udp,timeout:mode == "timeout" ? 0.2 : 2,
                                     keepAliveInterval:mode == "stale-ack" ? 0.05 : 8,
                                     sessionTimeout:mode == "stale-ack" ? 0.3 : 35)
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let result = try await client.command(ip:args[1],method:"get_prop",params:["main_power","bg_power","bg_rgb"])
                guard result == ["off","on","16711680"] else { throw LightFailure("Unexpected TCP result") }
                if mode == "error" || mode == "timeout" { throw LightFailure("Expected TCP failure was not raised") }
            } catch {
                if mode == "error", error.localizedDescription.contains("rejected") { print("PASS: TCP device error"); return }
                if mode == "timeout", error.localizedDescription.contains("超时"),
                   ProcessInfo.processInfo.systemUptime-start < 0.7 { print("PASS: absolute TCP deadline"); return }
                throw error
            }
            do { try await client.openSession(ip:args[1],generation:42) }
            catch {
                if mode == "bad-token" { print("PASS: invalid UDP token rejected"); return }
                throw error
            }
            if mode == "bad-token" { throw LightFailure("Invalid token was accepted") }
            if mode == "stale-ack" {
                for _ in 0..<15 {
                    try await Task.sleep(nanoseconds:50_000_000)
                    do { try await client.heartbeat(generation:42) }
                    catch {
                        guard error.localizedDescription.contains("失去响应") else { throw error }
                        print("PASS: unrelated UDP packets cannot keep session alive"); return
                    }
                }
                throw LightFailure("Unrelated UDP ACK incorrectly kept session alive")
            }
            try await client.sendColor(RGB(0,255,0),generation:41)
            for tick in 0..<400 {
                if tick % 10 == 0 { try await client.heartbeat(generation:42) }
                try await client.sendColor(RGB(255,0,0),generation:42)
                try await Task.sleep(nanoseconds:100_000_000)
            }
            await client.closeSession()
            try await client.sendColor(RGB(0,255,0),generation:42)
            print("PASS: 400 UDP updates, 40 seconds of heartbeat, stale generations ignored")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n",stderr)
            exit(1)
        }
    }
}
