import Foundation

/// Bundle these notices with any binary distribution that links WWExport, and surface them in About.
public enum ExportLicensing {
    public static let lameVersion = "3.100"
    public static let lameSourceSHA256 = "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
    public static var lameLicenseURL: URL {
        Bundle.module.url(forResource: "COPYING", withExtension: nil, subdirectory: "Licenses")!
    }
    public static var lameNoticeURL: URL {
        Bundle.module.url(forResource: "LICENSE", withExtension: nil, subdirectory: "Licenses")!
    }
}
