import Foundation

@main struct NetworkDiagnosticsTests {
    struct Failure: Error { let detail: String }

    static func require(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
        if !condition() { throw Failure(detail: detail) }
    }

    static func main() async throws {
        let output = "route to: default\ngateway: 192.0.2.1\ninterface: en0\n"
        try require(NetworkDiagnostics.ipv4Gateway(status: 0, output: output) == "192.0.2.1", "successful IPv4 gateway")
        try require(NetworkDiagnostics.ipv4Gateway(status: 1, output: output) == nil, "failed route output is ignored")
        try require(NetworkDiagnostics.ipv4Gateway(status: 0, output: "interface: utun0") == nil, "a route can lack a gateway")
        for invalid in ["link#12", "en0", "fe80::1%en0", "0.0.0.0", "192.0.2.256", "router.invalid", "192.0.2.1 extra", "192.0.2.1\0extra"] {
            try require(NetworkDiagnostics.ipv4Gateway(status: 0, output: "   gateway: \(invalid)\n") == nil,
                        "invalid gateway must not be sent to the IPv4 ping probe: \(invalid)")
        }
        print("PASS: IPv4 gateway probe requires a successful routing command and a real IPv4 address")

        guard CommandLine.arguments.count == 2, let origin = URL(string: CommandLine.arguments[1]),
              origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil else {
            throw Failure(detail: "the network fixture requires an explicit loopback origin")
        }
        func request(_ path: String) -> URLRequest {
            var request = URLRequest(url: origin.appendingPathComponent(path))
            request.httpMethod = "HEAD"
            return request
        }

        let baseline = URLSession(configuration: .ephemeral)
        defer { baseline.invalidateAndCancel() }
        let (_, followed) = try await baseline.data(for: request("default-redirect"))
        try require((followed as? HTTPURLResponse)?.statusCode == 204, "the old URLSession setup follows the fixture redirect")

        let crossOrigin = try await NetworkDiagnostics.initialHTTPStatus(for: request("cross-origin"))
        try require(crossOrigin == 302, "the selected origin's 302 response is retained")
        let sameOrigin = try await NetworkDiagnostics.initialHTTPStatus(for: request("same-origin"))
        try require(sameOrigin == 307, "a same-origin redirect also stops at the first response")
        let serverError = try await NetworkDiagnostics.initialHTTPStatus(for: request("server-error"))
        try require(serverError == 503, "a real HTTP server error is kept as a received response")
    }
}
