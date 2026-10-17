import Foundation
import Darwin

struct LightFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct RGB: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var packed: Int { (Int(r.rounded()).clamped(0, 255) << 16) | (Int(g.rounded()).clamped(0, 255) << 8) | Int(b.rounded()).clamped(0, 255) }
    var hex: String { String(format: "#%06X", packed) }
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    init(packed: Int) { self.init(Double((packed >> 16) & 255), Double((packed >> 8) & 255), Double(packed & 255)) }
    func blended(with other: RGB, amount: Double) -> RGB {
        RGB(r + (other.r-r)*amount, g + (other.g-g)*amount, b + (other.b-b)*amount)
    }
}

extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(high, Swift.max(low, self)) }
}

enum ColorAnalysis {
    // Hue population preserves strong screen colours rather than averaging red/blue to grey.
    // Neutral scenes fall back to their mean. Black bars and the outer 5% are ignored.
    static func dominant(bgra: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> RGB {
        guard width > 0, height > 0, stride >= width * 4 else { return RGB(0,0,0) }
        var sums = Array(repeating: [Double](repeating: 0, count: 4), count: 24)
        var mean = RGB(0,0,0)
        var count = 0, colourful = 0, sampled = 0
        for y in max(0,height/20)..<max(1,height-height/20) {
            for x in max(0,width/20)..<max(1,width-width/20) {
                let p = bgra + y*stride + x*4
                let r = Double(p[2]), g = Double(p[1]), b = Double(p[0])
                sampled += 1
                let hi = max(r,g,b), lo = min(r,g,b), delta = hi-lo
                if hi < 20 { continue }
                mean.r += r; mean.g += g; mean.b += b; count += 1
                let saturation = delta/hi
                if saturation < 0.22 { continue }
                colourful += 1
                var hue: Double
                if hi == r { hue = (g-b)/delta }
                else if hi == g { hue = (b-r)/delta+2 }
                else { hue = (r-g)/delta+4 }
                if hue < 0 { hue += 6 }
                let bin = min(23,Int(hue*4))
                let weight = 0.5+0.5*saturation
                sums[bin][0] += weight
                sums[bin][1] += r*weight
                sums[bin][2] += g*weight
                sums[bin][3] += b*weight
            }
        }
        guard count > 0, Double(count)/Double(max(1,sampled)) > 0.10 else { return RGB(0,0,0) }
        if Double(colourful)/Double(count) >= 0.08 {
            // Adjacent hue buckets count together, avoiding an artificial boundary at red.
            let winner = (0..<24).max { a,b in
                let wa = sums[(a+23)%24][0]+sums[a][0]+sums[(a+1)%24][0]
                let wb = sums[(b+23)%24][0]+sums[b][0]+sums[(b+1)%24][0]
                return wa < wb
            }!
            var combined = [Double](repeating: 0, count: 4)
            for index in [(winner+23)%24,winner,(winner+1)%24] {
                for k in 0..<4 { combined[k] += sums[index][k] }
            }
            if combined[0] > 0 {
                let result = RGB(combined[1]/combined[0],combined[2]/combined[0],combined[3]/combined[0])
                let scale = 255/max(result.r,result.g,result.b,1)
                return RGB(result.r*scale,result.g*scale,result.b*scale)
            }
        }
        return RGB(mean.r/Double(count),mean.g/Double(count),mean.b/Double(count))
    }
}

struct DiscoveredLight: Sendable, Identifiable {
    let ip: String
    let model: String
    var id: String { ip }
}

protocol LightTransport: Actor {
    func command(ip: String, method: String, params: [Any]) async throws -> [String]
    func discover() async throws -> [DiscoveredLight]
    func openSession(ip: String, generation: Int) async throws
    func sendColor(_ color: RGB, generation: Int) async throws
    func heartbeat(generation: Int) async throws
    func closeSession() async
}

// Blocking sockets live exclusively on this actor, never on the UI thread.
actor LightClient: LightTransport {
    private var messageID = 0
    private var udp: Int32 = -1
    private var token = ""
    private var lastHeartbeat = -Double.infinity
    private var lastAck = -Double.infinity
    private var generation = 0
    private var heartbeatIDs = Set<Int>()
    private let tcpPort: UInt16
    private let udpPort: UInt16
    private let timeout: Double
    private let keepAliveInterval: Double
    private let sessionTimeout: Double

    init(tcpPort: UInt16 = 55443, udpPort: UInt16 = 55444, timeout: Double = 3,
         keepAliveInterval: Double = 8, sessionTimeout: Double = 35) {
        self.tcpPort = tcpPort; self.udpPort = udpPort
        self.timeout = max(0.05,timeout)
        self.keepAliveInterval = max(0.01,keepAliveInterval)
        self.sessionTimeout = max(0.05,sessionTimeout)
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func waitForSocket(_ fd: Int32, events: Int16, deadline: Double) throws {
        while true {
            let remaining = deadline - now
            guard remaining > 0 else { throw LightFailure("设备回应超时") }
            var event = pollfd(fd:fd,events:events,revents:0)
            let result = poll(&event,1,Int32(min(remaining * 1000 + 1,Double(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw LightFailure("设备回应超时") }
            return
        }
    }

    static func address(_ ip: String, _ port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { throw LightFailure("请输入正确的 IPv4 地址") }
        return address
    }

    private func connectSocket(_ fd: Int32, _ ip: String, _ port: UInt16) throws {
        var address = try Self.address(ip, port)
        let flags = fcntl(fd,F_GETFL,0)
        _ = fcntl(fd,F_SETFL,flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result < 0 {
            guard errno == EINPROGRESS else { throw LightFailure("连接失败：\(String(cString:strerror(errno)))") }
            try waitForSocket(fd,events:Int16(POLLOUT),deadline:now + timeout)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&length) == 0, error == 0 else { throw LightFailure("设备不可达，请检查 IP 和局域网控制") }
        }
        _ = fcntl(fd,F_SETFL,flags)
        var timeout = timeval(tv_sec:2,tv_usec:500000)
        _ = setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        _ = setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
    }

    func command(ip: String, method: String, params: [Any]) throws -> [String] {
        let fd = socket(AF_INET,SOCK_STREAM,0)
        guard fd >= 0 else { throw LightFailure("无法创建 TCP 连接") }
        defer { Darwin.close(fd) }
        try connectSocket(fd,ip,tcpPort)
        messageID += 1
        let id = messageID
        var packet = try JSONSerialization.data(withJSONObject:["id":id,"method":method,"params":params])
        packet.append(contentsOf:[13,10])
        try packet.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd,raw.baseAddress!+sent,raw.count-sent,0)
                guard n > 0 else { throw LightFailure("命令发送失败") }
                sent += n
            }
        }
        let deadline = now + timeout
        var buffer = Data(), bytes = [UInt8](repeating:0,count:8192)
        while now < deadline {
            try waitForSocket(fd,events:Int16(POLLIN),deadline:deadline)
            let size = recv(fd,&bytes,bytes.count,0)
            guard size > 0 else { throw LightFailure("未收到设备回应；请稍后重试") }
            buffer.append(contentsOf:bytes.prefix(size))
            guard buffer.count <= 65536 else { throw LightFailure("设备回应过大") }
            while let range = buffer.range(of:Data([13,10])) {
                let line = buffer.subdata(in:0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                guard !line.isEmpty,
                      let reply = try JSONSerialization.jsonObject(with:line) as? [String:Any],
                      (reply["id"] as? Int) == id else { continue }
                if let error = reply["error"] { throw LightFailure("设备拒绝命令：\(error)") }
                guard let result = reply["result"] as? [Any] else { throw LightFailure("设备回应格式错误") }
                return result.map { String(describing:$0) }
            }
        }
        throw LightFailure("设备回应超时")
    }

    func discover() throws -> [DiscoveredLight] {
        let fd = socket(AF_INET,SOCK_DGRAM,0)
        guard fd >= 0 else { throw LightFailure("无法创建设备发现连接") }
        defer { Darwin.close(fd) }
        var target = try Self.address("239.255.255.250",1982)
        let data = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: \"ssdp:discover\"\r\nST: wifi_bulb\r\n\r\n".utf8)
        var found: [String:DiscoveredLight] = [:]
        for _ in 0..<2 {
            _ = data.withUnsafeBytes { raw in
                withUnsafePointer(to:&target) { ptr in
                    ptr.withMemoryRebound(to:sockaddr.self,capacity:1) { sendto(fd,raw.baseAddress,raw.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            let deadline = now + 1
            while now < deadline {
                var event = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                guard poll(&event,1,150) > 0 else { continue }
                var bytes = [UInt8](repeating:0,count:8192)
                var source = sockaddr_in()
                var sourceSize = socklen_t(MemoryLayout<sockaddr_in>.size)
                let size = withUnsafeMutablePointer(to:&source) { ptr in
                    ptr.withMemoryRebound(to:sockaddr.self,capacity:1) { recvfrom(fd,&bytes,bytes.count,0,$0,&sourceSize) }
                }
                guard size > 0 else { continue }
                let lines = String(decoding:bytes.prefix(size),as:UTF8.self).components(separatedBy:"\r\n")
                guard lines.first == "HTTP/1.1 200 OK" else { continue }
                var headers: [String:String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of:":") {
                        headers[String(line[..<colon]).lowercased()] = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
                    }
                }
                if let location = headers["location"], let url = URL(string:location),
                   url.scheme == "yeelight", url.user == nil, url.password == nil,
                   (url.port ?? 55443) == 55443, let host = url.host,
                   let advertised = try? Self.address(host,55443),
                   advertised.sin_addr.s_addr == source.sin_addr.s_addr {
                    found[host] = DiscoveredLight(ip:host,model:headers["model"] ?? "Yeelight")
                }
            }
        }
        return found.values.sorted { $0.ip < $1.ip }
    }

    func openSession(ip: String, generation newGeneration: Int) throws {
        closeSession()
        generation = newGeneration
        udp = socket(AF_INET,SOCK_DGRAM,0)
        guard udp >= 0 else { throw LightFailure("无法创建实时连接") }
        do {
            try connectSocket(udp,ip,udpPort)
            token = ""
            let id = try udpSend("udp_sess_new",params:[],authenticated:false)
            var bytes = [UInt8](repeating:0,count:8192)
            let deadline = now + timeout
            while now < deadline {
                try waitForSocket(udp,events:Int16(POLLIN),deadline:deadline)
                let size = recv(udp,&bytes,bytes.count,0)
                guard size > 0 else { break }
                if let reply = try? JSONSerialization.jsonObject(with:Data(bytes.prefix(size))) as? [String:Any],
                   (reply["id"] as? Int) == id, (reply["method"] as? String) == "udp_sess_token",
                   let params = reply["params"] as? [String:Any], let value = params["token"] as? String,
                   value.range(of:"^[0-9a-fA-F]{32}$",options:.regularExpression) != nil {
                    token = value
                    lastAck = now
                    try heartbeat(generation:newGeneration)
                    return
                }
            }
            throw LightFailure("实时会话未连接。请确认型号支持 UDP，且没有其他程序占用")
        } catch { closeSession(); throw error }
    }

    @discardableResult private func udpSend(_ method: String, params: [Any], authenticated: Bool = true) throws -> Int {
        guard udp >= 0 else { throw LightFailure("实时会话已关闭") }
        messageID += 1
        var packet: [String:Any] = ["id":messageID,"method":method,"params":params]
        if authenticated { packet["token"] = token }
        var data = try JSONSerialization.data(withJSONObject:packet)
        data.append(contentsOf:[13,10])
        let sent = data.withUnsafeBytes { Darwin.send(udp,$0.baseAddress,$0.count,0) }
        guard sent == data.count else { throw LightFailure("实时颜色发送失败") }
        return messageID
    }

    func sendColor(_ color: RGB, generation expected: Int) throws {
        guard expected == generation, udp >= 0 else { return }
        try udpSend("bg_set_rgb",params:[color.packed,"sudden",0])
    }

    func heartbeat(generation expected: Int) throws {
        guard expected == generation, udp >= 0 else { return }
        var event = pollfd(fd:udp,events:Int16(POLLIN),revents:0)
        var bytes = [UInt8](repeating:0,count:8192)
        for _ in 0..<32 {
            guard poll(&event,1,0) > 0 else { break }
            let size = recv(udp,&bytes,bytes.count,0)
            if size <= 0 { break }
            if let reply = try? JSONSerialization.jsonObject(with:Data(bytes.prefix(size))) as? [String:Any] {
                guard let id = reply["id"] as? Int, heartbeatIDs.contains(id) else { continue }
                if reply["error"] != nil { throw LightFailure("挂灯拒绝实时会话，请停止后重试") }
                let params = reply["params"] as? [String:Any]
                if params?["token"] as? String == token || (reply["result"] as? [String]) == ["ok"] {
                    heartbeatIDs.remove(id)
                    lastAck = now
                }
            }
        }
        if now - lastAck > sessionTimeout { throw LightFailure("实时会话失去响应，请检查网络后重新启动") }
        if now - lastHeartbeat >= keepAliveInterval {
            let id = try udpSend("udp_sess_keep_alive",params:["keeplive_interval","10"])
            heartbeatIDs.insert(id)
            lastHeartbeat = now
        }
    }

    func closeSession() {
        if udp >= 0 { Darwin.close(udp) }
        udp = -1; token = ""; generation = -1
        lastHeartbeat = -Double.infinity
        heartbeatIDs.removeAll()
    }
}
