import Foundation

/// The live browser windows, held weakly, so things that act outside any one
/// window (the `browsemium://` handler's siblings: Shortcuts actions) can
/// find "the window the person is using". A window that closes simply drops
/// out; nothing here keeps a model alive.
@MainActor
public final class LiveWindowIndex {
    public static let shared = LiveWindowIndex()

    private struct Entry {
        weak var model: BrowserWindowModel?
    }

    private var entries: [Entry] = []
    private var activeID: ObjectIdentifier?

    public init() {}

    public func register(_ model: BrowserWindowModel) {
        prune()
        guard !entries.contains(where: { $0.model === model }) else { return }
        entries.append(Entry(model: model))
    }

    public func markActive(_ model: BrowserWindowModel) {
        register(model)
        activeID = ObjectIdentifier(model)
    }

    /// Every live window, oldest first.
    public var models: [BrowserWindowModel] {
        prune()
        return entries.compactMap(\.model)
    }

    /// The window to act on: the one last focused, else the newest ordinary
    /// window, else the newest of any kind.
    public var activeModel: BrowserWindowModel? {
        let live = models
        if let activeID, let match = live.first(where: { ObjectIdentifier($0) == activeID }) { return match }
        return live.last(where: { !$0.session.isPrivate }) ?? live.last
    }

    private func prune() {
        entries.removeAll { $0.model == nil }
        if let activeID, !entries.contains(where: { $0.model.map(ObjectIdentifier.init) == activeID }) {
            self.activeID = nil
        }
    }
}
