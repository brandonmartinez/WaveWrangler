import Foundation
import WWCore

/// Device-local, observed state of a library entry (states-and-recovery §5). Never canonical; produced by
/// the persistence lane's reconciliation/observation. `.checking` until observed (ST-01).
public enum LibraryEntryState: Sendable, Equatable {
    case checking
    case available
    case notFound(folderDisplayName: String?)
    case needsPermission
    case locationUnavailable
    case newerFormat
    case damaged
    case outOfDate
    /// Only the canonical `UnavailableRecord` note is known; no fresh observation yet.
    case recordedUnavailable(note: String)
    /// Two different files carry the same show identity (e.g. a Finder copy). Both are kept; nothing is
    /// merged or dropped.
    case identityCollision(otherLocationDisplayName: String?)
    /// No location for this show is recorded on this Mac (e.g. the library came from another Mac or was
    /// restored). A distinct, final state — never an endless "Checking…" (ST-01).
    case locationUnknown
}

public enum LibraryRemedy: String, Sendable, Equatable, CaseIterable {
    case openShow = "Open Show"
    case locate = "Locate…"
    case removeFromLibrary = "Remove from Library…"
    case grantAccess = "Grant Access…"
    case tryAgain = "Try Again"
    case openReadOnly = "Open Read-Only"
    case revertTo = "Revert To…"
    case showInFinder = "Show in Finder"
}

public struct LibraryEntryStatePresentation: Sendable, Equatable {
    public var statusText: String
    /// `nil` = inline spinner.
    public var symbolName: String?
    public var tint: StatusTint
    public var explanation: String?
    public var remedies: [LibraryRemedy]
    /// Counted in the Unavailable sidebar item.
    public var needsAttention: Bool

    public init(_ state: LibraryEntryState, showName: String) {
        switch state {
        case .checking:
            self.init("Checking…", nil, .none, nil, [], false)
        case .available:
            self.init("Available", "checkmark.circle", .none, nil, [.openShow], false)
        case .notFound(let folder):
            let place = folder.map { " at \($0)" } ?? ""
            self.init(
                "Can't find show file", "doc.questionmark", .attention,
                "WaveWrangler can't find “\(showName)”\(place). It may have been moved, renamed or deleted.",
                [.locate, .removeFromLibrary], true
            )
        case .needsPermission:
            self.init(
                "Needs permission", "key.slash", .attention,
                "WaveWrangler needs your permission to open this show again.", [.grantAccess], true
            )
        case .locationUnavailable:
            self.init(
                "Location unavailable", "icloud.slash", .attention,
                "The folder for this show isn't available right now (for example, the cloud service or drive is offline).",
                [.tryAgain], true
            )
        case .newerFormat:
            self.init(
                "Needs newer WaveWrangler", "lock.fill", .none,
                "“\(showName)” was saved by a newer version of WaveWrangler. You can look at it, but editing and saving are turned off so its newer information isn't lost.",
                [.openReadOnly], true
            )
        case .damaged:
            self.init(
                "Can't read show", "exclamationmark.lock", .attention,
                "WaveWrangler could only partly read “\(showName)”. It opened what it could, read-only, and hasn't changed the file.",
                [.openReadOnly, .revertTo], true
            )
        case .outOfDate:
            self.init(
                "Details out of date", "arrow.clockwise", .none,
                "The library's details for this show will update the next time it's opened.", [.openShow], false
            )
        case .locationUnknown:
            self.init(
                "Location unknown", "location.slash", .attention,
                "WaveWrangler doesn't know where “\(showName)” is saved on this Mac. Choose Locate… to find it; WaveWrangler checks the show inside the file, not its name.",
                [.locate, .removeFromLibrary], true
            )
        case .identityCollision(let other):
            let place = other.map { " in “\($0)”" } ?? " somewhere else"
            self.init(
                "Same show in two files", "doc.on.doc", .attention,
                "Another file\(place) has the same show identity as “\(showName)”, for example a copy made in Finder. WaveWrangler keeps both files and hasn't merged or removed either. To keep both as separate shows, open one and choose File › Duplicate.",
                [.showInFinder, .removeFromLibrary], true
            )
        case .recordedUnavailable(let note):
            self.init(
                "Unavailable", "exclamationmark.triangle", .attention,
                "WaveWrangler couldn't open “\(showName)” last time: \(note)", [.tryAgain, .locate, .removeFromLibrary], true
            )
        }
    }

    private init(_ text: String, _ symbol: String?, _ tint: StatusTint, _ explanation: String?, _ remedies: [LibraryRemedy], _ attention: Bool) {
        statusText = text
        symbolName = symbol
        self.tint = tint
        self.explanation = explanation
        self.remedies = remedies
        needsAttention = attention
    }
}

public struct EpisodeSummary: Sendable, Equatable, Identifiable {
    public var id: EpisodeID
    public var number: Int?
    public var title: String

    public init(id: EpisodeID, number: Int?, title: String) {
        self.id = id
        self.number = number
        self.title = title
    }

    public var displayTitle: String {
        number.map { "\($0) \(title)" } ?? title
    }
}

/// Rebuildable, device-local details for one library entry ("as of last open"). Not canonical.
public struct LibraryEntryDetails: Sendable, Equatable {
    public var state: LibraryEntryState
    /// Provider and folder display name, never a full path (IA §3.2).
    public var locationDisplayName: String?
    public var lastOpened: Date?
    /// Last-known episode list; `nil` when never reconciled.
    public var episodes: [EpisodeSummary]?
    public var sourceReferenceCount: Int?

    public init(
        state: LibraryEntryState = .checking,
        locationDisplayName: String? = nil,
        lastOpened: Date? = nil,
        episodes: [EpisodeSummary]? = nil,
        sourceReferenceCount: Int? = nil
    ) {
        self.state = state
        self.locationDisplayName = locationDisplayName
        self.lastOpened = lastOpened
        self.episodes = episodes
        self.sourceReferenceCount = sourceReferenceCount
    }
}

/// The two-level Library sidebar (IA §3.1).
public enum LibrarySidebarItem: Hashable, Sendable {
    case shows
    case recent
    case unavailable
    case collection(CollectionID)

    public var accessibilityIdentifier: String {
        switch self {
        case .shows: "ww.library.sidebar.shows"
        case .recent: "ww.library.sidebar.recent"
        case .unavailable: "ww.library.sidebar.unavailable"
        case .collection(let id): "ww.library.sidebar.collection.\(id)"
        }
    }

    public var collectionID: CollectionID? {
        if case .collection(let id) = self { return id }
        return nil
    }
}

public struct LibrarySidebarRow: Sendable, Equatable, Identifiable {
    public var item: LibrarySidebarItem
    public var title: String
    public var symbolName: String
    /// Visible count text, e.g. "(3)" (IA-09: text, not a coloured dot).
    public var countText: String?
    public var accessibilityLabel: String
    public var accessibilityValue: String

    public var id: LibrarySidebarItem { item }
}

public struct LibrarySidebarSnapshot: Sendable, Equatable {
    public var libraryRows: [LibrarySidebarRow]
    public var collectionRows: [LibrarySidebarRow]
}

/// One row of the entry list (IA §3.2).
public struct LibraryEntryRow: Sendable, Equatable, Identifiable {
    public var showID: ShowID
    public var name: String
    public var kindText: String
    public var episodeCount: Int?
    public var locationText: String
    public var lastOpened: Date?
    public var status: LibraryEntryStatePresentation

    public var id: ShowID { showID }
    public var accessibilityIdentifier: String { "ww.library.entry.\(showID)" }

    public var episodesText: String { episodeCount.map(String.init) ?? "—" }

    /// VoiceOver label for the row: name, plus the full state (no colour-only meaning).
    public var accessibilityLabel: String {
        var parts = [name]
        if let episodeCount { parts.append(episodeCount == 1 ? "1 episode" : "\(episodeCount) episodes") }
        parts.append(locationText)
        parts.append(status.statusText)
        return parts.joined(separator: ", ")
    }
}

public enum LibraryPresentation {
    public static let unknownLocation = "Location unknown"

    public static func displayName(of entry: LibraryShowEntry) -> String {
        if let alias = entry.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty { return alias }
        return entry.lastKnownTitle
    }

    /// Observation wins; otherwise a canonical unavailable note is shown; otherwise "Checking…".
    public static func state(of entry: LibraryShowEntry, details: LibraryEntryDetails?) -> LibraryEntryState {
        if let details, details.state != .checking { return details.state }
        if let note = entry.unavailable?.note { return .recordedUnavailable(note: note) }
        return .checking
    }

    public static func sidebar(library: LibraryModel, details: [ShowID: LibraryEntryDetails]) -> LibrarySidebarSnapshot {
        let showCount = library.entries.count
        let recentCount = library.recentShowIDs.count { library.entry($0) != nil }
        let attention = library.entries.count { entry in
            LibraryEntryStatePresentation(state(of: entry, details: details[entry.showID]), showName: "").needsAttention
        }
        let libraryRows = [
            LibrarySidebarRow(
                item: .shows, title: "Shows", symbolName: "books.vertical", countText: nil,
                accessibilityLabel: "Shows", accessibilityValue: count(showCount, "show", "shows")
            ),
            LibrarySidebarRow(
                item: .recent, title: "Recent", symbolName: "clock", countText: nil,
                accessibilityLabel: "Recent", accessibilityValue: count(recentCount, "item", "items")
            ),
            LibrarySidebarRow(
                item: .unavailable, title: "Unavailable", symbolName: "exclamationmark.triangle",
                countText: attention > 0 ? "(\(attention))" : nil,
                accessibilityLabel: "Unavailable",
                accessibilityValue: attention == 0 ? "None" : (attention == 1 ? "1 item needs attention" : "\(attention) items need attention")
            ),
        ]
        let collectionRows = library.collections.map { collection in
            let members = collection.showIDs.count { library.entry($0) != nil }
            return LibrarySidebarRow(
                item: .collection(collection.id), title: collection.name, symbolName: "rectangle.stack", countText: nil,
                accessibilityLabel: "\(collection.name), collection", accessibilityValue: count(members, "item", "items")
            )
        }
        return LibrarySidebarSnapshot(libraryRows: libraryRows, collectionRows: collectionRows)
    }

    /// Entry rows for a sidebar item, in the item's natural order (Shows: name; Recent: newest first;
    /// collections: user order; Unavailable: name).
    public static func entries(
        for item: LibrarySidebarItem,
        library: LibraryModel,
        details: [ShowID: LibraryEntryDetails],
        selectedIDs: Set<ShowID>? = nil
    ) -> [LibraryEntryRow] {
        let byID = Dictionary(library.entries.map { ($0.showID, $0) }, uniquingKeysWith: { first, _ in first })
        func included(_ id: ShowID) -> Bool { selectedIDs?.contains(id) ?? true }
        func row(_ entry: LibraryShowEntry) -> LibraryEntryRow {
            let detail = details[entry.showID]
            let name = displayName(of: entry)
            return LibraryEntryRow(
                showID: entry.showID,
                name: name,
                kindText: "Show",
                episodeCount: detail?.episodes?.count,
                locationText: detail?.locationDisplayName ?? unknownLocation,
                lastOpened: detail?.lastOpened,
                status: LibraryEntryStatePresentation(state(of: entry, details: detail), showName: name)
            )
        }
        switch item {
        case .shows:
            return library.entries.filter { included($0.showID) }.map(row).sorted(by: nameOrder)
        case .recent:
            return library.recentShowIDs.filter(included).compactMap { byID[$0] }.map(row)
        case .unavailable:
            return library.entries.filter { included($0.showID) }.map(row).filter(\.status.needsAttention).sorted(by: nameOrder)
        case .collection(let id):
            return (library.collection(id)?.showIDs ?? []).filter(included).compactMap { byID[$0] }.map(row)
        }
    }

    private static func nameOrder(_ lhs: LibraryEntryRow, _ rhs: LibraryEntryRow) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.showID.rawValue.uuidString < rhs.showID.rawValue.uuidString : order == .orderedAscending
    }

    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        value == 1 ? "1 \(singular)" : "\(value) \(plural)"
    }

    /// The content-column heading, e.g. "Shows (24)".
    public static func contentTitle(for item: LibrarySidebarItem, library: LibraryModel, rowCount: Int) -> String {
        let name: String = switch item {
        case .shows: "Shows"
        case .recent: "Recent"
        case .unavailable: "Unavailable"
        case .collection(let id): library.collection(id)?.name ?? "Collection"
        }
        return "\(name) (\(rowCount))"
    }
}

/// Result of a background location check for one entry (mirrors the persistence check, without depending
/// on it), tagged with the entry's generation when the check started.
public struct LibraryEntryCheckResult: Sendable, Equatable {
    public enum Observation: Sendable, Equatable {
        case unknown
        case reachable(folderDisplayName: String)
        case notFound(folderDisplayName: String?)
        case needsPermission
        case unavailable
    }

    public var showID: ShowID
    public var generation: Int
    public var observation: Observation

    public init(showID: ShowID, generation: Int, observation: Observation) {
        self.showID = showID
        self.generation = generation
        self.observation = observation
    }
}

public enum LibraryEntryRefresh {
    /// Library entries that still need a check on this Mac, in library order: no details at all (shows another
    /// library or another Mac brought in: Use That Library, Combine, a change from another Mac), or details still
    /// "Checking…" (seeded from this Mac's location records, e.g. for a show removed from the library before
    /// launch and brought back by a combine) with no check running (`inFlight`). Otherwise they'd stay
    /// "Checking…" and be missing from Unavailable (#193).
    public static func unchecked(_ library: LibraryModel, details: [ShowID: LibraryEntryDetails], inFlight: Set<ShowID> = []) -> [ShowID] {
        library.entries.map(\.showID).filter { id in
            guard !inFlight.contains(id) else { return false }
            guard let state = details[id]?.state else { return true }
            return state == .checking
        }
    }

    /// Applies background check results. A result is dropped when the entry changed while the check ran
    /// (its generation moved on: e.g. a show window opened, or an identity collision was found), and an
    /// identity collision is never overwritten by a check.
    public static func apply(
        _ results: [LibraryEntryCheckResult],
        to details: [ShowID: LibraryEntryDetails],
        currentGenerations: [ShowID: Int]
    ) -> [ShowID: LibraryEntryDetails] {
        var updated = details
        for result in results {
            guard currentGenerations[result.showID, default: 0] == result.generation else { continue }
            var entry = updated[result.showID] ?? LibraryEntryDetails()
            if case .identityCollision = entry.state { continue }
            switch result.observation {
            case .unknown:
                entry.state = .locationUnknown
            case .reachable(let folder):
                entry.state = .available
                entry.locationDisplayName = folder
            case .notFound(let folder):
                entry.state = .notFound(folderDisplayName: folder)
            case .needsPermission:
                entry.state = .needsPermission
            case .unavailable:
                entry.state = .locationUnavailable
            }
            updated[result.showID] = entry
        }
        return updated
    }
}

/// Sortable entry-list columns (Name, Location, Status), compared as Finder does (`localizedStandardCompare`).
public enum LibraryEntrySortKey: String, Sendable, CaseIterable {
    case name, location, status

    func compare(_ a: LibraryEntryRow, _ b: LibraryEntryRow) -> ComparisonResult {
        switch self {
        case .name: a.name.localizedStandardCompare(b.name)
        case .location: a.locationText.localizedStandardCompare(b.locationText)
        case .status: a.status.statusText.localizedStandardCompare(b.status.statusText)
        }
    }
}

extension LibraryPresentation {
    /// Rows sorted by the given keys in priority order; stable, and unchanged when there are no keys.
    public static func sorted(_ rows: [LibraryEntryRow], by keys: [(key: LibraryEntrySortKey, ascending: Bool)]) -> [LibraryEntryRow] {
        guard !keys.isEmpty else { return rows }
        return rows.enumerated().sorted { lhs, rhs in
            for (key, ascending) in keys {
                let order = key.compare(lhs.element, rhs.element)
                if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
