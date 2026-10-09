import AppKit
import Darwin
import Foundation
import XCTest

@MainActor
final class OfflineSocketDiagnosticUITests: XCTestCase {
    // Opt in on a leased GUI host with TEST_RUNNER_WW_OFFLINE_DIAGNOSTIC=1.
    // A skipped diagnostic is never evidence of an offline speech boundary.
    private struct Descriptor: Decodable {
        let number: Int32
        let kind: String
        let connected: Bool
    }

    private struct Cell: Decodable {
        let family: String
        let operation: String
        let outcome: String
        let errorNumber: Int32?
    }

    private struct Report: Decodable {
        let pid: Int32
        let descriptorScanTruncated: Bool
        let startupDescriptors: [Descriptor]
        let sandbox: String
        let networkClient: String
        let networkServer: String
        let cells: [Cell]
    }

    private struct Peer {
        let socket: Int32
        let port: UInt16
    }

    private func listeningPeer(domain: Int32, kind: Int32) throws -> Peer {
        let fd = socket(domain, kind, 0)
        guard fd >= 0 else { throw NSError(domain: "loopback socket", code: Int(errno)) }
        do {
            var address = sockaddr_storage()
            let size: socklen_t
            if domain == AF_INET {
                var loopback = sockaddr_in()
                loopback.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                loopback.sin_family = sa_family_t(AF_INET)
                loopback.sin_addr = in_addr(s_addr: in_addr_t(0x7f00_0001).bigEndian)
                withUnsafeBytes(of: &loopback) { bytes in
                    withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
                }
                size = socklen_t(MemoryLayout<sockaddr_in>.size)
            } else {
                var loopback = sockaddr_in6()
                loopback.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                loopback.sin6_family = sa_family_t(AF_INET6)
                guard inet_pton(AF_INET6, "::1", &loopback.sin6_addr) == 1 else {
                    throw NSError(domain: "IPv6 loopback unavailable", code: -1)
                }
                withUnsafeBytes(of: &loopback) { bytes in
                    withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
                }
                size = socklen_t(MemoryLayout<sockaddr_in6>.size)
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
            }
            guard bound == 0 else { throw NSError(domain: "loopback bind", code: Int(errno)) }
            if kind == SOCK_STREAM {
                guard listen(fd, 1) == 0 else { throw NSError(domain: "loopback listen", code: Int(errno)) }
            }
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard named == 0 else { throw NSError(domain: "loopback getsockname", code: Int(errno)) }
            let port: UInt16
            if domain == AF_INET {
                port = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port.bigEndian }
                }
            } else {
                port = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port.bigEndian }
                }
            }
            return Peer(socket: fd, port: port)
        } catch {
            close(fd)
            throw error
        }
    }

    func testBoundedInAppSocketDenial() throws {
        guard ProcessInfo.processInfo.environment["WW_OFFLINE_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Offline diagnostic not requested; run the selector on a leased GUI host")
        }
        let board = NSPasteboard(name: NSPasteboard.Name("com.brandonmartinez.wavewrangler.offline-diagnostic"))
        board.clearContents()
        let peers = try [
            listeningPeer(domain: AF_INET, kind: SOCK_STREAM),
            listeningPeer(domain: AF_INET, kind: SOCK_DGRAM),
            listeningPeer(domain: AF_INET6, kind: SOCK_STREAM),
            listeningPeer(domain: AF_INET6, kind: SOCK_DGRAM),
        ]
        defer { peers.forEach { close($0.socket) } }
        let bundle = "com.brandonmartinez.wavewrangler"
        let before = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES",
                               "-WWUITestHooks", "YES", "-WWOfflineSocketProbe", "YES",
                               "-WWOfflineTCPIPv4", "\(peers[0].port)", "-WWOfflineUDPIPv4", "\(peers[1].port)",
                               "-WWOfflineTCPIPv6", "\(peers[2].port)", "-WWOfflineUDPIPv6", "\(peers[3].port)"]
        app.launch()
        defer { app.terminate() }
        let type = NSPasteboard.PasteboardType("com.brandonmartinez.wavewrangler.offline-diagnostic.json")
        let ready = Acceptance.waitFor(timeout: 10) { board.data(forType: type) != nil }
        XCTAssertTrue(ready, "The in-app diagnostic must publish a report")
        let report = try JSONDecoder().decode(Report.self, from: XCTUnwrap(board.data(forType: type)))
        let launched = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
            .subtracting(before)
        let evidence: [String: Any] = [
            "pid": report.pid, "newAppPIDs": launched.sorted(),
            "descriptorScanTruncated": report.descriptorScanTruncated,
            "startupDescriptors": report.startupDescriptors.map { ["number": $0.number, "kind": $0.kind, "connected": $0.connected] as [String: Any] },
            "sandbox": report.sandbox, "networkClient": report.networkClient, "networkServer": report.networkServer,
            "cells": report.cells.map { ["family": $0.family, "operation": $0.operation,
                                          "outcome": $0.outcome, "errno": $0.errorNumber as Any? ?? NSNull()] as [String: Any] },
        ]
        Acceptance.writeEvidence("offline-socket-diagnostic", evidence, test: self)
        XCTAssertEqual(launched, [report.pid], "Evidence must originate in the newly launched app process, not the runner")
        XCTAssertEqual(report.sandbox, "true", "The running signed app must be sandboxed")
        XCTAssertEqual(report.networkClient, "absent", "The running signed app must lack network.client")
        XCTAssertEqual(report.networkServer, "absent", "The running signed app must lack network.server")
        XCTAssertFalse(report.descriptorScanTruncated, "Startup FD scan did not cover the descriptor table")
        XCTAssertTrue(report.startupDescriptors.filter { $0.number > 2 }.isEmpty, "Non-stdio startup FDs need investigation")
        XCTAssertFalse(report.startupDescriptors.contains(where: \.connected), "Inherited connected FD must be investigated")
        var expected = Set(["localhost hostname/connect", "preconnected/send/receive"])
        for family in ["IPv4", "IPv6"] {
            for transport in ["TCP", "UDP"] {
                for operation in ["connect", "bind", "send", "receive"] {
                    expected.insert("\(family)/\(transport)/\(operation)")
                }
            }
            for operation in ["listen"] { expected.insert("\(family)/TCP/\(operation)") }
            for operation in ["raw-create", "raw-send"] { expected.insert("\(family)/\(operation)") }
        }
        XCTAssertEqual(Set(report.cells.map { "\($0.family)/\($0.operation)" }), expected,
                       "Every bounded endpoint and data cell must appear exactly once")
        XCTAssertEqual(report.cells.count, expected.count, "Duplicate cells must not mask a missing case")
        for cell in report.cells {
            let detail = "\(cell.family) \(cell.operation): \(cell.outcome), errno \(String(describing: cell.errorNumber))"
            switch cell.operation {
            case "connect", "bind", "raw-create":
                XCTAssertEqual(cell.outcome, "denied", detail)
                XCTAssertTrue(cell.errorNumber == EPERM || cell.errorNumber == EACCES, detail)
            case "send" where cell.family.hasSuffix("/UDP"), "raw-send" where cell.outcome != "not-reachable-after-create":
                XCTAssertEqual(cell.outcome, "denied", detail)
                XCTAssertTrue(cell.errorNumber == EPERM || cell.errorNumber == EACCES, detail)
            case "listen":
                XCTAssertTrue(cell.outcome == "denied" || cell.outcome == "not-reachable-after-bind", detail)
            case "send", "receive":
                XCTAssertEqual(cell.outcome, "not-reachable", detail)
            case "raw-send":
                XCTAssertEqual(cell.outcome, "not-reachable-after-create", detail)
            default:
                XCTAssertEqual(cell.outcome, "not-injected", detail)
            }
        }
        XCTFail("Endpoint-by-endpoint sandbox violation log correlation and inference start/end FD inventories are not established by this startup-only diagnostic")
    }
}
