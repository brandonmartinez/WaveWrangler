import Foundation

/// Bundle these notices with any binary distribution that links WWExport; surface them in Help > Software Licenses.
public enum ExportLicensing {
    public struct Notice: Sendable, Identifiable {
        public let id: String
        public let title: String
        public let text: String
        public init(id: String, title: String, text: String) {
            self.id = id
            self.title = title
            self.text = text
        }
    }

    /// Reads the actual linked resource bundle. Missing resources fail visibly in the licenses window.
    public static func notices() throws -> [Notice] {
        try [
            ("WaveWrangler-MIT.txt", "WaveWrangler - MIT"),
            ("COPYING", "LAME - LGPL-2.0-or-later"),
            ("LAME-Library-Notice.txt", "LAME - copyright and library grant"),
            ("LICENSE", "LAME - upstream usage notice"),
            ("Source-and-Relinking.txt", "LAME - source, replacement, and release gates"),
        ].map { name, title in
            guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Licenses") else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Missing bundled software license: \(name)"])
            }
            return Notice(id: name, title: title, text: try String(contentsOf: url, encoding: .utf8))
        }
    }
    public static let lameVersion = "3.100"
    public static let lameSourceSHA256 = "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
    public static var lameLicenseURL: URL {
        Bundle.module.url(forResource: "COPYING", withExtension: nil, subdirectory: "Licenses")!
    }
    public static var lameNoticeURL: URL {
        Bundle.module.url(forResource: "LICENSE", withExtension: nil, subdirectory: "Licenses")!
    }
}
