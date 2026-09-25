import Foundation
import Observation

/// Asks the app to open a new private window. The toolbar, the File menu,
/// and the command palette arm the request; the next window that appears
/// consumes it and enters private mode before its first frame.
///
/// The flag is consumed by exactly one window, so a double click cannot
/// turn two windows private — the second opens as a normal window, the
/// same way a second ⌘N behaves.
@MainActor
@Observable
public final class PrivateWindowRequest {
    public static let shared = PrivateWindowRequest()

    private(set) public var isPending = false

    private init() {}

    /// Marks the next window to appear as private. The caller is responsible
    /// for actually opening the window (`openWindow(id: "main")`).
    public func arm() {
        isPending = true
    }

    /// The next window that appears takes the request.
    @discardableResult
    public func consume() -> Bool {
        guard isPending else { return false }
        isPending = false
        return true
    }
}
