import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class MixerTrackScrollState {
    var viewportWidth: CGFloat = 0
    var contentWidth: CGFloat = 0
    var offset: CGFloat = 0
    @ObservationIgnored weak var scrollView: NSScrollView?

    var overflows: Bool { viewportWidth > 0 && contentWidth > viewportWidth }
    var maximumOffset: CGFloat { max(0, contentWidth - viewportWidth) }

    func reflect(_ scroll: NSScrollView) {
        let viewport = scroll.contentSize.width
        let content = scroll.documentView?.frame.width ?? 0
        let position = scroll.contentView.bounds.minX
        if viewportWidth != viewport { viewportWidth = viewport }
        if contentWidth != content { contentWidth = content }
        if offset != position { offset = position }
    }

    func scroll(to offset: CGFloat) {
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: min(maximumOffset, max(0, offset)), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// The separate scroller stays outside the shared vertical viewport.
struct MixerTrackScrollView<Content: View>: NSViewRepresentable {
    let state: MixerTrackScrollState
    let contentWidth: CGFloat
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> TrackScrollView {
        let scroll = TrackScrollView()
        scroll.state = state
        state.scrollView = scroll
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.setAccessibilityIdentifier("ww.mixer.speakers")
        let host = NSHostingView(rootView: AnyView(content.frame(width: contentWidth)
            .frame(maxWidth: .infinity, alignment: .leading).wwAppEnvironment()))
        scroll.documentView = host
        return scroll
    }

    func updateNSView(_ scroll: TrackScrollView, context: Context) {
        if let host = scroll.documentView as? NSHostingView<AnyView> {
            host.rootView = AnyView(content.frame(width: contentWidth)
                .frame(maxWidth: .infinity, alignment: .leading).wwAppEnvironment())
        }
        scroll.contentWidth = contentWidth
        scroll.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: TrackScrollView, context: Context) -> CGSize? {
        guard let host = scroll.documentView else { return nil }
        let width = proposal.width ?? contentWidth
        return CGSize(width: width, height: host.fittingSize.height)
    }

    final class TrackScrollView: NSScrollView {
        weak var state: MixerTrackScrollState?
        var contentWidth: CGFloat = 0
        override func layout() {
            super.layout()
            guard let documentView else { return }
            let size = NSSize(width: max(contentWidth, contentSize.width), height: documentView.fittingSize.height)
            if documentView.frame.size != size { documentView.setFrameSize(size) }
            state?.reflect(self)
        }

        override func reflectScrolledClipView(_ clipView: NSClipView) {
            super.reflectScrolledClipView(clipView)
            state?.reflect(self)
        }
    }
}

struct MixerTrackScroller: NSViewRepresentable {
    let state: MixerTrackScrollState
    static var thickness: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) }

    func makeNSView(context: Context) -> TrackScroller {
        let scroller = TrackScroller(frame: NSRect(x: 0, y: 0, width: 200, height: Self.thickness))
        scroller.state = state
        scroller.scrollerStyle = .legacy
        scroller.target = scroller
        scroller.action = #selector(TrackScroller.move)
        scroller.setAccessibilityIdentifier("ww.mixer.trackScrollbar")
        scroller.setAccessibilityLabel("Scroll mixer tracks")
        return scroller
    }

    func updateNSView(_ scroller: TrackScroller, context: Context) {
        scroller.isEnabled = state.overflows
        scroller.knobProportion = state.contentWidth > 0 ? state.viewportWidth / state.contentWidth : 1
        scroller.doubleValue = state.maximumOffset > 0 ? Double(state.offset / state.maximumOffset) : 0
    }

    final class TrackScroller: NSScroller {
        weak var state: MixerTrackScrollState?

        @objc func move() {
            guard let state else { return }
            let offset: CGFloat
            switch hitPart {
            case .decrementLine: offset = state.offset - 40
            case .incrementLine: offset = state.offset + 40
            case .decrementPage: offset = state.offset - state.viewportWidth * 0.9
            case .incrementPage: offset = state.offset + state.viewportWidth * 0.9
            default: offset = CGFloat(doubleValue) * state.maximumOffset
            }
            state.scroll(to: offset)
        }
    }
}
