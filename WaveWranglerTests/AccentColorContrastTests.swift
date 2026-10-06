import Foundation
import Testing

/// #138 / WW-007 C04, C07: every `AccentColor` appearance variant keeps white selection text at ≥ 4.5:1 and an
/// accent fill that alone shows state (switch on, checkbox checked) at ≥ 3:1 against the window backgrounds
/// measured on macOS 27.0.1 (`docs/m1/evidence/ww-007-accessibility-responsiveness.md` §7.2, §10). Reads the
/// asset catalog from source, so it runs unhosted.
@Suite("AccentColor contrast")
struct AccentColorContrastTests {
    struct Variant: CustomStringConvertible {
        let dark: Bool
        let highContrast: Bool
        let rgb: (Double, Double, Double)
        var description: String { "\(dark ? "dark" : "light")\(highContrast ? " high-contrast" : "")" }
    }

    /// Window and control backgrounds behind accent fills, measured from screenshots (light: window/content and
    /// grouped-form backgrounds; dark: content, Settings form and sidebar backgrounds, with and without Increase
    /// Contrast).
    static let lightBackgrounds = [0xFFFFFF, 0xECECEC]
    static let darkBackgrounds = [0x1E1E1E, 0x202020, 0x242424]

    static func variants(_ colorSet: String = "AccentColor") throws -> [Variant] {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "WaveWrangler/Assets.xcassets/\(colorSet).colorset/Contents.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let colors = try #require(json["colors"] as? [[String: Any]])
        return try colors.map { entry in
            let appearances = entry["appearances"] as? [[String: String]] ?? []
            let color = try #require(entry["color"] as? [String: Any])
            #expect(color["color-space"] as? String == "srgb")
            let components = try #require(color["components"] as? [String: String])
            func channel(_ key: String) throws -> Double {
                let text = try #require(components[key])
                let value = text.hasPrefix("0x") ? Double(Int(text.dropFirst(2), radix: 16) ?? -1) / 255 : Double(text) ?? -1
                #expect((0...1).contains(value), "\(key) = \(text)")
                return value
            }
            return Variant(dark: appearances.contains { $0["appearance"] == "luminosity" && $0["value"] == "dark" },
                           highContrast: appearances.contains { $0["appearance"] == "contrast" && $0["value"] == "high" },
                           rgb: (try channel("red"), try channel("green"), try channel("blue")))
        }
    }

    static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    static func luminance(hex: Int) -> Double {
        luminance((Double(hex >> 16 & 0xFF) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255))
    }

    static func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    @Test func coversLightDarkAndBothHighContrastAppearances() throws {
        let variants = try Self.variants()
        #expect(variants.count == 4)
        for dark in [false, true] {
            for highContrast in [false, true] {
                #expect(variants.contains { $0.dark == dark && $0.highContrast == highContrast },
                        "missing \(dark ? "dark" : "light")\(highContrast ? " high-contrast" : "") variant")
            }
        }
    }

    @Test func whiteSelectionTextReachesFourPointFive() throws {
        for variant in try Self.variants() {
            let ratio = Self.ratio(1, Self.luminance(variant.rgb))
            #expect(ratio >= 4.5, "white on the \(variant) accent: \(ratio)")
        }
    }

    @Test func highContrastVariantsAreAtLeastAsStrongForWhiteText() throws {
        let variants = try Self.variants()
        for dark in [false, true] {
            let normal = try #require(variants.first { $0.dark == dark && !$0.highContrast })
            let high = try #require(variants.first { $0.dark == dark && $0.highContrast })
            #expect(Self.ratio(1, Self.luminance(high.rgb)) > Self.ratio(1, Self.luminance(normal.rgb)), "\(high)")
        }
    }

    @Test func accentFillStandsOutFromWindowBackgrounds() throws {
        for variant in try Self.variants() {
            for background in variant.dark ? Self.darkBackgrounds : Self.lightBackgrounds {
                let ratio = Self.ratio(Self.luminance(variant.rgb), Self.luminance(hex: background))
                #expect(ratio >= 3, "\(variant) accent vs #\(String(background, radix: 16)): \(ratio)")
            }
        }
    }

    /// Dark sheet backgrounds measured behind checkboxes on macOS 27.0.1 (#139: Import Review sheet, #363636 with
    /// Increase Contrast; #2D2D2D without).
    static let darkSheetBackgrounds = [0x2D2D2D, 0x363636]

    /// #139: `CheckboxTint` equals `AccentColor` except in dark + Increase Contrast, where a checked box's fill must
    /// stand out from the dark sheet (≥ 3:1) while its white checkmark stays ≥ 3:1 on the fill. (AppKit renders the
    /// fill slightly lighter than the tint, ≈ +0.03 luminance, which helps the first and is covered by the second's
    /// margin; the rendered values are measured by `testAccentTintedControls`.)
    @Test func checkboxTintFillAndCheckmark() throws {
        let accent = try Self.variants()
        let checkbox = try Self.variants("CheckboxTint")
        #expect(checkbox.count == 4)
        for variant in checkbox {
            let lum = Self.luminance(variant.rgb)
            #expect(Self.ratio(1, lum) >= 3, "white checkmark on the \(variant) checkbox fill: \(Self.ratio(1, lum))")
            let backgrounds = variant.dark ? Self.darkBackgrounds + Self.darkSheetBackgrounds : Self.lightBackgrounds
            if variant.dark && variant.highContrast {
                for background in backgrounds {
                    let ratio = Self.ratio(lum, Self.luminance(hex: background))
                    #expect(ratio >= 3, "\(variant) checkbox fill vs #\(String(background, radix: 16)): \(ratio)")
                }
            } else {
                let same = accent.first { $0.dark == variant.dark && $0.highContrast == variant.highContrast }
                #expect(same.map { $0.rgb == variant.rgb } == true, "\(variant) checkbox tint equals the accent")
            }
        }
    }
}
