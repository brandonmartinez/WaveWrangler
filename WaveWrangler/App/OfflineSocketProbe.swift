#if DEBUG
import AppKit
import Darwin
import Foundation
import Security

/// Synthetic, bounded diagnostic only. The UI runner supplies listening loopback peers; no speech data,
/// model, user content, remote address, or production entry point is involved.
@MainActor
enum OfflineSocketProbe {
    static let pasteboard = NSPasteboard.Name("com.brandonmartinez.wavewrangler.offline-diagnostic")
    private static var startupDescriptors: [Descriptor] = []

    struct Descriptor: Codable {
        let number: Int32
        let kind: String
        let connected: Bool
    }

    struct Cell: Codable {
        let family: String
        let operation: String
        let outcome: String
        let errorNumber: Int32?
    }

    struct Report: Codable {
        let pid: Int32
        let descriptorScanTruncated: Bool
        let startupDescriptors: [Descriptor]
        let sandbox: String
        let networkClient: String
        let networkServer: String
        let cells: [Cell]
    }

    static func captureStartupDescriptors() {
        guard UserDefaults.standard.bool(forKey: "WWUITestHooks"),
              UserDefaults.standard.bool(forKey: "WWOfflineSocketProbe") else { return }
        let limit = min(getdtablesize(), 16_384)
        startupDescriptors = (0..<limit).compactMap { number in
            guard fcntl(number, F_GETFD) != -1 else { return nil }
            var info = stat()
            let kind: String
            if fstat(number, &info) == 0 {
                switch info.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFSOCK): kind = "socket"
                case mode_t(S_IFIFO): kind = "pipe"
                case mode_t(S_IFREG): kind = "file"
                case mode_t(S_IFCHR): kind = "device"
                default: kind = "other"
                }
            } else {
                kind = "unknown"
            }
            var peer = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            return Descriptor(number: number, kind: kind,
                              connected: withUnsafeMutablePointer(to: &peer) {
                                  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                      getpeername(number, $0, &length) == 0
                                  }
                              })
        }
    }

    static func runIfRequested() {
        guard PersistenceEnvironment.isUITestRun,
              UserDefaults.standard.bool(forKey: "WWOfflineSocketProbe") else { return }
        let report = Report(
            pid: getpid(), descriptorScanTruncated: getdtablesize() > 16_384,
            startupDescriptors: startupDescriptors,
            sandbox: entitlement("com.apple.security.app-sandbox"),
            networkClient: entitlement("com.apple.security.network.client"),
            networkServer: entitlement("com.apple.security.network.server"),
            cells: ["IPv4", "IPv6"].flatMap { family in
                let domain = family == "IPv4" ? AF_INET : AF_INET6
                let tcp = UserDefaults.standard.integer(forKey: "WWOfflineTCP\(family)")
                let udp = UserDefaults.standard.integer(forKey: "WWOfflineUDP\(family)")
                return probe(family: family, domain: domain, tcpPort: tcp, udpPort: udp)
            } + [
                Cell(family: "localhost hostname", operation: "connect", outcome: "not-exercised-no-DNS", errorNumber: nil),
                Cell(family: "preconnected", operation: "send/receive",
                     outcome: startupDescriptors.contains(where: \.connected) ? "unexpected-inherited-socket" : "not-injected",
                     errorNumber: nil)
            ]
        )
        do {
            let data = try JSONEncoder().encode(report)
            let board = NSPasteboard(name: pasteboard)
            board.clearContents()
            guard board.setData(data, forType: .init("com.brandonmartinez.wavewrangler.offline-diagnostic.json")) else {
                NSLog("Offline socket diagnostic: result publication failed")
                return
            }
        } catch {
            NSLog("Offline socket diagnostic: encoding failed: %@", String(describing: error))
        }
    }

    private static func entitlement(_ key: String) -> String {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return "unavailable" }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, key as CFString, &error)
        if let error { error.release(); return "error" }
        guard let value else { return "absent" }
        guard let number = value as? NSNumber else { return "unexpected" }
        return number.boolValue ? "true" : "false"
    }

    private static func address(domain: Int32, port: Int) -> (sockaddr_storage, socklen_t)? {
        guard (0...65_535).contains(port) else { return nil }
        var result = sockaddr_storage()
        if domain == AF_INET {
            var value = sockaddr_in()
            value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            value.sin_family = sa_family_t(AF_INET)
            value.sin_port = in_port_t(port).bigEndian
            value.sin_addr = in_addr(s_addr: in_addr_t(0x7f00_0001).bigEndian)
            withUnsafeBytes(of: &value) { bytes in
                withUnsafeMutableBytes(of: &result) { $0.copyBytes(from: bytes) }
            }
            return (result, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        var value = sockaddr_in6()
        value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        value.sin6_family = sa_family_t(AF_INET6)
        value.sin6_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET6, "::1", &value.sin6_addr) == 1 else { return nil }
        withUnsafeBytes(of: &value) { bytes in
            withUnsafeMutableBytes(of: &result) { $0.copyBytes(from: bytes) }
        }
        return (result, socklen_t(MemoryLayout<sockaddr_in6>.size))
    }

    private static func probe(family: String, domain: Int32, tcpPort: Int, udpPort: Int) -> [Cell] {
        var cells: [Cell] = []
        let payload = [UInt8]("synthetic".utf8)
        for (transport, kind, port) in [("TCP", SOCK_STREAM, tcpPort), ("UDP", SOCK_DGRAM, udpPort)] {
            let prefix = "\(family)/\(transport)"
            guard let (endpoint, length) = address(domain: domain, port: port) else {
                for operation in ["connect", "bind", "send", "receive"] + (transport == "TCP" ? ["listen"] : []) {
                    cells.append(Cell(family: prefix, operation: operation, outcome: "missing-peer", errorNumber: nil))
                }
                continue
            }
            var peer = endpoint
            for operation in ["connect", "bind", "send", "receive"] {
                let fd = socket(domain, kind, 0)
                guard fd >= 0 else {
                    cells.append(Cell(family: prefix, operation: operation, outcome: "socket-failed", errorNumber: errno))
                    continue
                }
                defer { close(fd) }
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                var noSigPipe: Int32 = 1
                guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    cells.append(Cell(family: prefix, operation: operation, outcome: "socket-setup-failed", errorNumber: errno))
                    continue
                }
                let value: Int
                switch operation {
                case "connect":
                    value = Int(withUnsafePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
                    })
                case "bind":
                    guard let (localEndpoint, localLength) = address(domain: domain, port: 0) else { preconditionFailure() }
                    var local = localEndpoint
                    value = Int(withUnsafePointer(to: &local) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, localLength) }
                    })
                    let bindError = value == 0 ? nil : errno
                    if transport == "TCP" {
                        if value == 0 {
                            let listening = listen(fd, 1)
                            cells.append(Cell(family: prefix, operation: "listen",
                                              outcome: listening == 0 ? "success" : (errno == EPERM ? "denied" : "inconclusive"),
                                              errorNumber: listening == 0 ? nil : errno))
                        } else {
                            cells.append(Cell(family: prefix, operation: "listen",
                                              outcome: "not-reachable-after-bind", errorNumber: bindError))
                        }
                    }
                case "send":
                    value = payload.withUnsafeBytes { bytes in
                        withUnsafePointer(to: &peer) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, bytes.baseAddress, bytes.count, 0, $0, length)
                            }
                        }
                    }
                default:
                    var buffer = [UInt8](repeating: 0, count: 32)
                    value = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                }
                let code = value < 0 ? errno : nil
                let peerIsReachable = operation == "connect" || operation == "bind" || (transport == "UDP" && operation == "send")
                let outcome = value >= 0 ? "success" :
                    (peerIsReachable ? (code == EPERM || code == EACCES ? "denied" : "inconclusive") : "not-reachable")
                cells.append(Cell(family: prefix, operation: operation, outcome: outcome, errorNumber: code))
            }
        }
        let raw = socket(domain, SOCK_RAW, domain == AF_INET ? IPPROTO_ICMP : IPPROTO_ICMPV6)
        let rawError = raw < 0 ? errno : nil
        cells.append(Cell(family: family, operation: "raw-create",
                          outcome: raw >= 0 ? "success" : ((rawError == EPERM || rawError == EACCES) ? "denied" : "inconclusive"),
                          errorNumber: rawError))
        if raw >= 0 {
            defer { close(raw) }
            guard let (endpoint, size) = address(domain: domain, port: 0) else { preconditionFailure() }
            var local = endpoint
            let sent = payload.withUnsafeBytes { bytes in
                withUnsafePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(raw, bytes.baseAddress, bytes.count, 0, $0, size)
                    }
                }
            }
            let sendError = sent < 0 ? errno : nil
            cells.append(Cell(family: family, operation: "raw-send",
                              outcome: sent >= 0 ? "success" : ((sendError == EPERM || sendError == EACCES) ? "denied" : "inconclusive"),
                              errorNumber: sendError))
        } else {
            cells.append(Cell(family: family, operation: "raw-send",
                              outcome: "not-reachable-after-create", errorNumber: rawError))
        }
        return cells
    }
}
#endif
