import AppKit
let w = NSWorkspace.shared
print("increaseContrast=\(w.accessibilityDisplayShouldIncreaseContrast) reduceMotion=\(w.accessibilityDisplayShouldReduceMotion) reduceTransparency=\(w.accessibilityDisplayShouldReduceTransparency) voiceOver=\(w.isVoiceOverEnabled) bodyFont=\(NSFont.preferredFont(forTextStyle: .body).pointSize)")
