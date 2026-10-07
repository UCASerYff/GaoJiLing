import Foundation
import Network

enum NetworkDiagnostics {
    static func run(host: String) async -> [NetworkCheck] {
        await Task.detached(priority: .utility) {
            var checks: [NetworkCheck] = []
            let route = command("/sbin/route", ["-n", "get", "default"], timeout: 3)
            let gateway = route.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("gateway:") }?.dropFirst(8).trimmingCharacters(in: .whitespaces)
            if let gateway, !gateway.isEmpty {
                let ping = command("/sbin/ping", ["-n", "-c", "2", "-W", "1000", gateway], timeout: 4)
                let summary = ping.output.split(separator: "\n").filter { $0.contains("packet loss") || $0.contains("round-trip") }.joined(separator: " · ")
                checks.append(NetworkCheck(title: "默认网关", detail: "\(gateway) · \(summary.isEmpty ? "未收到 ICMP 响应；路由器可能禁止此类探测" : summary)", success: ping.status == 0 ? true : nil))
            } else { checks.append(NetworkCheck(title: "默认网关", detail: "未找到 IPv4 默认网关；可能处于 IPv6 或 VPN 网络。", success: nil)) }
            let dns = command("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", host], timeout: 5)
            let ips = dns.output.split(separator: "\n").filter { $0.contains("ip_address:") || $0.contains("ipv6_address:") }.prefix(4).joined(separator: " · ")
            checks.append(NetworkCheck(title: "DNS 解析", detail: ips.isEmpty ? "系统解析未返回地址；仍将尝试 HTTPS 连接。" : ips, success: ips.isEmpty ? nil : true))
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 10
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "https://\(host)/")!); request.httpMethod = "HEAD"
            let start = Date()
            do {
                let (_, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                checks.append(NetworkCheck(title: "HTTPS 连接", detail: "\(host) · \(Int(Date().timeIntervalSince(start) * 1000)) ms · HTTP \(code)。耗时包含解析、TLS 和服务器响应。", success: true))
                if code >= 400 { checks.append(NetworkCheck(title: "服务状态", detail: "服务器已响应，但返回 HTTP \(code)；可能限制 HEAD 请求或需要登录。", success: nil)) }
            } catch { checks.append(NetworkCheck(title: "HTTPS 连接", detail: error.localizedDescription, success: false)) }
            return checks
        }.value
    }
    private static func command(_ executable: String, _ args: [String], timeout: Double) -> (status: Int32, output: String) {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = pipe; process.standardError = pipe
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if semaphore.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        return (process.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}
