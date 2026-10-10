#if DEBUG
import Darwin
import Foundation
import Security

/// Headless, generated-only app-process diagnostic. A matching sandbox log is still required
/// for every denial candidate; this command never declares offline acceptance.
enum OfflineContainmentProbe {
    private static let maxDescriptors: Int32 = 16_384

    private static func inventory(_ phase: String) -> Bool {
        let count = getdtablesize()
        guard count > 0, count <= maxDescriptors else {
            print("WW_OFFLINE phase=\(phase) inventory=STOP reason=unbounded")
            return false
        }
        var open = 0
        for fd in 0..<count {
            if fcntl(fd, F_GETFD) == -1 {
                if errno == EBADF { continue }
                print("WW_OFFLINE phase=\(phase) inventory=STOP reason=fcntl errno=\(errno)")
                return false
            }
            open += 1
            var info = stat()
            guard fstat(fd, &info) == 0 else {
                print("WW_OFFLINE phase=\(phase) inventory=STOP reason=fstat errno=\(errno)")
                return false
            }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) {
                var address = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let peer = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getpeername(fd, $0, &length)
                    }
                }
                print("WW_OFFLINE phase=\(phase) inventory=STOP reason=inherited-socket connected=\(peer == 0 ? 1 : 0)")
                return false
            }
            guard fd < 3 else {
                print("WW_OFFLINE phase=\(phase) inventory=STOP reason=unexpected-descriptor")
                return false
            }
        }
        print("WW_OFFLINE phase=\(phase) pid=\(getpid()) descriptors=\(open) sockets=0 inventory=stdio-only")
        return true
    }

    private enum Entitlement: String {
        case absent, enabled, disabled, unknown
    }

    private static func entitlement(_ key: String) -> Entitlement {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return .unknown }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, key as CFString, &error)
        if let error {
            error.release()
            return .unknown
        }
        guard let value else { return .absent }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return .unknown
        }
        return number.boolValue ? .enabled : .disabled
    }

    private static func auditEntitlements() -> Bool {
        let sandbox = entitlement("com.apple.security.app-sandbox")
        let client = entitlement("com.apple.security.network.client")
        let server = entitlement("com.apple.security.network.server")
        guard sandbox == .enabled, client == .absent, server == .absent else {
            print("WW_OFFLINE entitlements=STOP sandbox=\(sandbox.rawValue) client=\(client.rawValue) server=\(server.rawValue)")
            return false
        }
        print("WW_OFFLINE entitlements=self-sandboxed network-client=absent network-server=absent")
        return true
    }

    private static func loopback(_ family: Int32) -> (sockaddr_storage, socklen_t)? {
        var address = sockaddr_storage()
        if family == AF_INET {
            var v4 = sockaddr_in()
            v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            v4.sin_family = sa_family_t(AF_INET)
            v4.sin_port = in_port_t(9).bigEndian
            guard inet_pton(AF_INET, "127.0.0.1", &v4.sin_addr) == 1 else { return nil }
            withUnsafeBytes(of: &v4) { bytes in
                withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
            }
            return (address, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        var v6 = sockaddr_in6()
        v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        v6.sin6_family = sa_family_t(AF_INET6)
        v6.sin6_port = in_port_t(9).bigEndian
        guard inet_pton(AF_INET6, "::1", &v6.sin6_addr) == 1 else { return nil }
        withUnsafeBytes(of: &v6) { bytes in
            withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        }
        return (address, socklen_t(MemoryLayout<sockaddr_in6>.size))
    }

    private enum SocketSetup {
        case ready(Int32)
        case failed(Int32)
    }

    private static func socketFor(_ family: Int32, _ kind: Int32) -> SocketSetup {
        let fd = socket(family, kind, 0)
        guard fd >= 0 else { return .failed(errno) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            close(fd)
            return .failed(code)
        }
        return .ready(fd)
    }

    private static func record(_ family: String, _ operation: String, _ result: Int32, _ code: Int32) -> Bool {
        let outcome = OfflineContainmentPolicy.classify(result, error: code)
        switch outcome {
        case .denialCandidate(let error):
            print("WW_OFFLINE pid=\(getpid()) family=\(family) operation=\(operation) status=DENIAL_CANDIDATE errno=\(error) time=\(Date().timeIntervalSince1970)")
            fflush(stdout)
            usleep(200_000)
            return true
        case .stop(let error):
            print("WW_OFFLINE pid=\(getpid()) family=\(family) operation=\(operation) status=STOP errno=\(error.map(String.init) ?? "none") time=\(Date().timeIntervalSince1970)")
            fflush(stdout)
            return false
        }
    }

    private static func attempt(
        family: Int32, name: String, kind: Int32, operation: String,
        address: sockaddr_storage, length: socklen_t
    ) -> Bool {
        let fd: Int32
        switch socketFor(family, kind) {
        case .ready(let descriptor): fd = descriptor
        case .failed(let code):
            print("WW_OFFLINE family=\(name) operation=\(operation) status=STOP reason=socket-or-nonblocking-setup errno=\(code)")
            return false
        }
        defer { close(fd) }
        var target = address
        if operation == "tcp-bind" || operation == "udp-bind" || operation == "tcp-listen-bind" {
            withUnsafeMutableBytes(of: &target) { bytes in bytes[2] = 0; bytes[3] = 0 }
        }
        print("WW_OFFLINE pid=\(getpid()) family=\(name) operation=\(operation) phase=begin time=\(Date().timeIntervalSince1970)")
        fflush(stdout)
        let result: Int32 = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                switch operation {
                case "tcp-connect", "udp-connect":
                    return connect(fd, pointer, length)
                case "tcp-bind", "udp-bind", "tcp-listen-bind":
                    return bind(fd, pointer, length)
                default:
                    return sendto(fd, nil, 0, 0, pointer, length) < 0 ? -1 : 0
                }
            }
        }
        let code = result < 0 ? errno : 0
        if operation == "tcp-listen-bind" {
            guard record(name, "tcp-listen-prerequisite-bind", result, code) else { return false }
            print("WW_OFFLINE pid=\(getpid()) family=\(name) operation=tcp-listen status=UNREACHABLE_AFTER_DENIED_BIND")
            return true
        }
        return record(name, operation, result, code)
    }

    static func run() -> Int32 {
        guard inventory("startup"), auditEntitlements(), inventory("before-synthetic") else { return 1 }
        guard SpeechProbe.run() == 0 else {
            print("WW_OFFLINE synthetic=STOP")
            return 1
        }
        guard inventory("after-synthetic") else { return 1 }
        for (family, name) in [(Int32(AF_INET), "IPv4-loopback"), (Int32(AF_INET6), "IPv6-loopback")] {
            guard let (address, length) = loopback(family) else {
                print("WW_OFFLINE family=\(name) status=STOP reason=address")
                return 1
            }
            for (kind, operation) in [
                (Int32(SOCK_STREAM), "tcp-connect"),
                (Int32(SOCK_STREAM), "tcp-bind"),
                (Int32(SOCK_STREAM), "tcp-listen-bind"),
                (Int32(SOCK_DGRAM), "udp-bind"),
                (Int32(SOCK_DGRAM), "udp-connect"),
                (Int32(SOCK_DGRAM), "udp-implicit-bind-sendto"),
            ] {
                guard attempt(family: family, name: name, kind: kind, operation: operation,
                              address: address, length: length) else { return 1 }
            }
        }
        guard inventory("after-matrix") else { return 1 }
        print("WW_OFFLINE pid=\(getpid()) overall=UNKNOWN requires=per-cell-sandbox-log-correlation-and-approved-mini")
        return 2
    }
}
#endif
