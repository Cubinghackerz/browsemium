import AppKit
import BrowsemiumExtensions
import SwiftUI
import WebKit

/// Anchors an extension action's popover to the toolbar button that owns it.
/// WebKit hands the app a preloaded `NSPopover`; something has to own the
/// button's view for `show(relativeTo:of:)`, and this is that something.
///
/// The class itself is available on every supported macOS — only the WebKit
/// extension methods are gated — so it can be stored in view state without
/// spreading availability annotations through the toolbar.
@MainActor
final class ExtensionActionPresenter: NSObject {
    private weak var model: BrowserWindowModel?
    private var anchors: [String: NSView] = [:]

    init(model: BrowserWindowModel) {
        self.model = model
        super.init()
    }

    /// The toolbar registers each button's anchor view as it appears.
    func register(_ view: NSView, for extensionID: String) {
        anchors[extensionID] = view
    }
}

@available(macOS 15.4, *)
extension ExtensionActionPresenter: ExtensionActionPopupPresenting {
    func presentActionPopup(
        _ action: WKWebExtension.Action,
        completion: @escaping ((any Error)?) -> Void
    ) {
        guard let popover = action.popupPopover else {
            completion(ExtensionHostError.noActionPopupHost)
            return
        }
        guard let context = action.webExtensionContext,
              let extensionID = model?.extensionID(for: context),
              let anchor = anchors[extensionID],
              anchor.window != nil else {
            completion(ExtensionHostError.noActionPopupHost)
            return
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        completion(nil)
    }
}

/// Reports the NSView it created so a popover can be anchored to it.
struct ToolbarAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onResolve(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onResolve(nsView)
    }
}
