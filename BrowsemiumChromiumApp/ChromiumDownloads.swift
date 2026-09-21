import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation

/// Download progress for every window, keyed by the identifier CEF assigns.
/// Chromium reports bytes directly, so unlike the WebKit engine there is no
/// polling loop here.
@MainActor
final class ChromiumDownloads: DownloadReporting {
    private var observers: [UUID: (DownloadInfo) -> Void] = [:]
    private var order: [UUID] = []
    private var infos: [UUID: DownloadInfo] = [:]

    @discardableResult
    func addObserver(_ handler: @escaping (DownloadInfo) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    func allDownloads() -> [DownloadInfo] {
        order.compactMap { infos[$0] }
    }

    /// Merges a report into the stored download. CEF reports the filename once,
    /// then progress updates that carry only bytes, so an update must not erase
    /// what the first report said.
    func record(_ info: DownloadInfo) {
        if let existing = infos[info.id] {
            infos[info.id] = DownloadInfo(
                id: info.id,
                tabID: existing.tabID,
                suggestedFilename: info.suggestedFilename.isEmpty ? existing.suggestedFilename : info.suggestedFilename,
                destinationURL: info.destinationURL ?? existing.destinationURL,
                bytesReceived: info.bytesReceived,
                totalBytes: info.totalBytes == 0 ? existing.totalBytes : info.totalBytes,
                isFinished: info.isFinished,
                failureMessage: info.failureMessage
            )
        } else {
            infos[info.id] = info
            order.append(info.id)
        }
        let stored = infos[info.id]
        for observer in observers.values {
            observer(stored ?? info)
        }
    }

    func forget(tabID: TabID) {
        let removed = infos.filter { $0.value.tabID == tabID }.map(\.key)
        for id in removed {
            infos[id] = nil
            order.removeAll { $0 == id }
        }
    }

    func removeAll() {
        infos.removeAll()
        order.removeAll()
    }
}
