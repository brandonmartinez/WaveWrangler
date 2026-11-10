import AppKit
import SwiftUI

struct ReviewPlaybackPosition: Equatable {
    let row: Int
    let fraction: Double

    static func locate(_ time: Double?, in rows: [FillerReviewRow]) -> Self? {
        guard let time, time.isFinite else { return nil }
        var last: Int?
        for (index, row) in rows.enumerated() where row.issue == nil {
            guard row.start.isFinite, row.end.isFinite, row.end > row.start else { continue }
            if time < row.end {
                return Self(row: index, fraction: max(0, (time - row.start) / (row.end - row.start)))
            }
            last = index
        }
        return last.map { Self(row: $0, fraction: 1) }
    }
}

/// Native row geometry keeps the line aligned with Table's virtualized rows and scroll offset.
struct ReviewPlaybackIndicator: NSViewRepresentable {
    let rows: [FillerReviewRow]
    let alignedTime: Double?

    func makeNSView(context: Context) -> IndicatorView { IndicatorView() }

    func updateNSView(_ view: IndicatorView, context: Context) {
        view.position = ReviewPlaybackPosition.locate(alignedTime, in: rows)
        view.rowCount = rows.count
        view.line.setAccessibilityValue(alignedTime.flatMap { $0.isFinite ? AlignmentPresentation.formatTime($0) : nil })
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: IndicatorView, coordinator: ()) { view.stop() }

    final class IndicatorView: NSView {
        var position: ReviewPlaybackPosition?
        var rowCount = 0
        let line = NSView()
        private weak var table: NSTableView?
        private var scrollObservation: NotificationObservation?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        init() {
            super.init(frame: .zero)
            setAccessibilityElement(false)
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.systemRed.cgColor
            line.setAccessibilityElement(true)
            line.setAccessibilityRole(.staticText)
            line.setAccessibilityLabel("Playback position")
            line.setAccessibilityIdentifier("ww.review.playbackPosition")
            line.isHidden = true
            addSubview(line)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            if table == nil {
                var ancestor = superview
                while let view = ancestor {
                    if let found = Self.findTable(in: view) {
                        table = found
                        if let clip = found.enclosingScrollView?.contentView {
                            clip.postsBoundsChangedNotifications = true
                            scrollObservation = NotificationObservation(NotificationCenter.default.addObserver(
                                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                            ) { [weak self] _ in
                                MainActor.assumeIsolated { self?.needsLayout = true }
                            })
                        }
                        break
                    }
                    ancestor = view.superview
                }
            }
            updateLine()
        }

        private func updateLine() {
            line.isHidden = true
            guard let position, let table, table.numberOfRows == rowCount,
                  position.row < table.numberOfRows,
                  let clip = table.enclosingScrollView?.contentView else { return }
            let row = convert(table.rect(ofRow: position.row), from: table)
            let visible = convert(clip.bounds, from: clip).intersection(bounds)
            let y = row.minY + row.height * position.fraction
            guard !visible.isEmpty, y >= visible.minY, y <= visible.maxY else { return }
            line.frame = NSRect(x: visible.minX, y: min(max(y - 1, visible.minY), visible.maxY - 2),
                                width: visible.width, height: 2)
            line.isHidden = false
        }

        private static func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let table = findTable(in: child) { return table }
            }
            return nil
        }

        func stop() {
            scrollObservation = nil
            table = nil
        }
    }
}
