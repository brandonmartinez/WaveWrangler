import AppKit
import Foundation
import Testing
import WWCore
@testable import WWEpisodeSetup

@Suite("Source status presentation (states §3)")
struct SourceStatusTests {
    @Test func inspectorWordingMatchesTheCatalog() {
        #expect(LocationStatus.known.presentation.inspectorText == "At its saved location")
        #expect(LocationStatus.missing(sameNamedFileAtOriginalLocation: false).presentation.inspectorText == "Not found")
        #expect(LocationStatus.unknown(reason: "x").presentation.inspectorText == "Location unknown — x")
        #expect(AccessStatus.granted.presentation.inspectorText == "WaveWrangler has permission")
        #expect(AccessStatus.refreshing.presentation.inspectorText == "Refreshing permission…")
        #expect(AccessStatus.needsPermission.presentation.inspectorText == "WaveWrangler needs your permission again")
        #expect(AccessStatus.denied.presentation.inspectorText == "macOS or the file's owner denied access")
        #expect(ResidencyStatus.local.presentation.inspectorText == "On this Mac")
        #expect(ResidencyStatus.cloudOnly.presentation.inspectorText == "In the cloud — not downloaded")
        #expect(ResidencyStatus.unknown.presentation.inspectorText == "Can't tell if it's downloaded")
        #expect(TransferStatus.queued.presentation.inspectorText == "Waiting to download")
        #expect(TransferStatus.downloading(fraction: 0.42).presentation.inspectorText == "Downloading — 42%")
        #expect(TransferStatus.downloading(fraction: nil).presentation.inspectorText == "Downloading — progress unknown")
        #expect(TransferStatus.noConnection.presentation.inspectorText == "Can't download — no network connection")
        #expect(TransferStatus.downloadsOff.presentation.inspectorText == "Downloads are off")
        #expect(IdentityStatus.notChecked.presentation.inspectorText == "Not checked")
        #expect(IdentityStatus.detailsMatch.presentation.inspectorText == "File details match what WaveWrangler recorded (audio not compared)")
    }

    @Test func summaryWordingMatchesTheCatalog() {
        #expect(AccessStatus.needsPermission.presentation.summaryText == "Needs permission")
        #expect(AccessStatus.denied.presentation.summaryText == "Access denied")
        #expect(LocationStatus.missing(sameNamedFileAtOriginalLocation: true).presentation.summaryText == "Not found")
        #expect(LocationStatus.moved(newFolder: nil).presentation.summaryText == "Moved")
        #expect(IdentityStatus.mismatch(differences: "x").presentation.summaryText == "Different file")
        #expect(IdentityStatus.changed(differences: "x", acceptedByUser: false).presentation.summaryText == "File changed")
        #expect(TransferStatus.downloading(fraction: 0.42).presentation.summaryText == "Downloading 42%")
        #expect(TransferStatus.downloading(fraction: nil).presentation.summaryText == "Downloading…")
        #expect(TransferStatus.failed(reason: "x").presentation.summaryText == "Download failed")
        #expect(ResidencyStatus.cloudOnly.presentation.summaryText == "Not downloaded")
        #expect(ResidencyStatus.unknown.presentation.summaryText == "Download state unknown")
    }

    @Test func deniedIsNeverShownAsNotFound() {
        let denied = SourceStatusSnapshot(location: .known, access: .denied, residency: .local, identity: .notChecked)
        #expect(denied.summary.text == "Access denied")
        #expect(!denied.summary.accessibilityValue.localizedCaseInsensitiveContains("not found"))
        #expect(AccessStatus.denied.presentation.symbolName != AccessStatus.needsPermission.presentation.symbolName)
    }

    @Test func priorityOrderAndVoiceOverValueFollowSection3_6() {
        let snapshot = SourceStatusSnapshot(location: .known, access: .needsPermission, residency: .cloudOnly, transfer: .idle, identity: .notChecked)
        #expect(snapshot.summary.text == "Needs permission")
        #expect(snapshot.summary.displayText == "Needs permission +1 more")
        #expect(snapshot.summary.accessibilityValue == "Needs permission; not downloaded; file details not checked")
        #expect(snapshot.summary.needsAttention)

        let downloading = SourceStatusSnapshot(location: .known, access: .granted, residency: .cloudOnly, transfer: .downloading(fraction: 0.42), identity: .notChecked)
        #expect(downloading.summary.text == "Downloading 42%", "priority 4 outranks Not downloaded")
        #expect(!downloading.summary.needsAttention)

        let ready = SourceStatusSnapshot(location: .known, access: .granted, residency: .local, transfer: .idle, identity: .detailsMatch)
        #expect(ready.summary.text == "Ready")
        #expect(ready.summary.accessibilityValue == "Ready")
        #expect(SourceStatusSnapshot.checking.summary.text == "Checking…")
    }

    @Test func needsAttentionIsPriorities1To3AndFailedOrNoConnection() {
        func attention(_ s: SourceStatusSnapshot) -> Bool { s.summary.needsAttention }
        let base = SourceStatusSnapshot(location: .known, access: .granted, residency: .local, transfer: .idle, identity: .notChecked)
        var s = base; s.transfer = .failed(reason: "x"); #expect(attention(s))
        s = base; s.transfer = .noConnection; #expect(attention(s))
        s = base; s.transfer = .cancelled; #expect(!attention(s))
        s = base; s.residency = .cloudOnly; #expect(!attention(s))
        s = base; s.location = .moved(newFolder: nil); #expect(attention(s))
        s = base; s.identity = .changed(differences: "x", acceptedByUser: true); #expect(!attention(s))
    }

    /// A-03 / mapping completeness: every combination of the five dimensions yields a non-generic summary
    /// (never "Offline"), a VoiceOver value, five inspector rows, and distinct inspector text per state.
    @Test func everyCombinationMapsToDistinctNonGenericText() {
        let all = SourceStatusCatalog.allSnapshots
        #expect(all.count == 7 * 6 * 4 * 11 * 6)
        let forbidden = ["offline", "unavailable", "error"]
        var inspectorTuples = Set<[String]>()
        for snapshot in all {
            let summary = snapshot.summary
            let texts = [summary.text, summary.accessibilityValue] + snapshot.dimensions.map(\.inspectorText)
            for text in texts {
                #expect(!text.isEmpty)
                for word in forbidden { #expect(!text.lowercased().contains(word), "\(text)") }
            }
            #expect(snapshot.dimensions.map(\.dimension) == SourceDimension.allCases)
            inspectorTuples.insert(snapshot.dimensions.map(\.inspectorText))
        }
        #expect(inspectorTuples.count == all.count, "each combination is distinguishable in the inspector")

        func distinct<T>(_ values: [T], _ text: (T) -> String) -> Bool { Set(values.map(text)).count == values.count }
        #expect(distinct(SourceStatusCatalog.allLocations) { $0.presentation.inspectorText })
        #expect(distinct(SourceStatusCatalog.allAccess) { $0.presentation.inspectorText })
        #expect(distinct(SourceStatusCatalog.allResidency) { $0.presentation.inspectorText })
        #expect(distinct(SourceStatusCatalog.allTransfers) { $0.presentation.inspectorText })
        #expect(distinct(SourceStatusCatalog.allIdentity) { $0.presentation.inspectorText })
    }

    /// No state differs only by tint: non-normal values carry a symbol or a progress/spinner indicator.
    @Test func everyNonNormalValueHasShapeNotJustColour() {
        let presentations = SourceStatusCatalog.allLocations.map(\.presentation) + SourceStatusCatalog.allAccess.map(\.presentation)
            + SourceStatusCatalog.allResidency.map(\.presentation) + SourceStatusCatalog.allTransfers.map(\.presentation)
            + SourceStatusCatalog.allIdentity.map(\.presentation)
        for p in presentations where p.spokenIssue != nil || p.summaryText != nil {
            #expect(p.indicator != .none, "\(p.inspectorText)")
        }
    }

    @Test func percentagesAreNeverInventedOrOutOfRange() {
        #expect(TransferStatus.downloading(fraction: 1.7).presentation.summaryText == "Downloading 100%")
        #expect(TransferStatus.downloading(fraction: -1).presentation.summaryText == "Downloading 0%")
        #expect(TransferStatus.downloading(fraction: .nan).presentation.summaryText == "Downloading 0%")
        #expect(TransferStatus.downloading(fraction: nil).presentation.indicator == .indeterminate)
    }

    /// A-01: every symbol name resolves on this host (deployment target check runs in CI on macOS 26).
    @Test(arguments: SourceStatusCatalog.symbolNames)
    func symbolResolves(_ name: String) {
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }

    @Test func catalogListsEverySymbolTheMappingUses() {
        let presentations = SourceStatusCatalog.allLocations.map(\.presentation) + SourceStatusCatalog.allAccess.map(\.presentation)
            + SourceStatusCatalog.allResidency.map(\.presentation) + SourceStatusCatalog.allTransfers.map(\.presentation)
            + SourceStatusCatalog.allIdentity.map(\.presentation)
        for name in presentations.compactMap(\.symbolName) {
            #expect(SourceStatusCatalog.symbolNames.contains(name), "\(name)")
        }
    }
}
