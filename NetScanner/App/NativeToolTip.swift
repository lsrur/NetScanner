import AppKit
import SwiftUI

extension View {
    /// Tooltip that also works inside `Table` cells, where `.help()` never shows on macOS.
    func cellToolTip(_ text: String) -> some View {
        overlay(NativeToolTip(text: text))
    }
}

/// An AppKit view carrying `toolTip`. AppKit picks the tooltip owner by hit-testing on mouse
/// moves, so the view must be hittable then; for clicks, drags and scrolls it steps aside so
/// row selection, double-click and context menus still reach the table.
private struct NativeToolTip: NSViewRepresentable {
    let text: String

    final class ToolTipView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                 .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                 .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel:
                nil
            default:
                super.hitTest(point)
            }
        }
    }

    func makeNSView(context: Context) -> ToolTipView {
        let view = ToolTipView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: ToolTipView, context: Context) {
        view.toolTip = text
    }
}
