import BrowsemiumCore
import Foundation
import WebKit

@MainActor
public final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    public struct DownloadInfo: Sendable, Identifiable {
        public let id: UUID
        public let tabID: TabID?
        public let suggestedFilename: String
        public let destinationURL: URL?
        public let bytesReceived: Int64
        public let totalBytes: Int64
        public let isFinished: Bool
        public let failureMessage: String?
    }

    public var onUpdate: ((DownloadInfo) -> Void)?

    private var infos: [ObjectIdentifier: DownloadInfo] = [:]
    private var pollers: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let destinationPolicy = DownloadDestinationPolicy()

    public func allDownloads() -> [DownloadInfo] {
        infos.values.sorted { $0.suggestedFilename < $1.suggestedFilename }
    }

    func adopt(_ download: WKDownload, tabID: TabID?, eventHandler: @escaping (TabRuntimeEvent) -> Void) {
        let key = ObjectIdentifier(download)
        let id = UUID()
        download.delegate = self
        let initial = DownloadInfo(
            id: id,
            tabID: tabID,
            suggestedFilename: download.originalRequest?.url?.lastPathComponent ?? "download",
            destinationURL: nil,
            bytesReceived: 0,
            totalBytes: 0,
            isFinished: false,
            failureMessage: nil
        )
        infos[key] = initial
        eventHandler(.downloadStarted(id))
        pollProgress(for: download, key: key, eventHandler: eventHandler)
    }

    private func pollProgress(
        for download: WKDownload,
        key: ObjectIdentifier,
        eventHandler: @escaping (TabRuntimeEvent) -> Void
    ) {
        pollers[key]?.cancel()
        pollers[key] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, var info = self.infos[key] else { return }
                let progress = download.progress
                info = DownloadInfo(
                    id: info.id,
                    tabID: info.tabID,
                    suggestedFilename: info.suggestedFilename,
                    destinationURL: info.destinationURL,
                    bytesReceived: progress.completedUnitCount,
                    totalBytes: progress.totalUnitCount,
                    isFinished: info.isFinished,
                    failureMessage: info.failureMessage
                )
                self.infos[key] = info
                self.onUpdate?(info)
                if progress.isFinished || progress.isCancelled {
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func update(
        _ download: WKDownload,
        key: ObjectIdentifier,
        transform: (DownloadInfo) -> DownloadInfo
    ) {
        guard let info = infos[key] else { return }
        let updated = transform(info)
        infos[key] = updated
        onUpdate?(updated)
    }

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let key = ObjectIdentifier(download)
        do {
            let destination = try destinationPolicy.destination(forSuggestedFilename: suggestedFilename)
            update(download, key: key) { info in
                DownloadInfo(
                    id: info.id,
                    tabID: info.tabID,
                    suggestedFilename: suggestedFilename,
                    destinationURL: destination,
                    bytesReceived: info.bytesReceived,
                    totalBytes: info.totalBytes,
                    isFinished: false,
                    failureMessage: nil
                )
            }
            return destination
        } catch {
            update(download, key: key) { info in
                DownloadInfo(
                    id: info.id,
                    tabID: info.tabID,
                    suggestedFilename: suggestedFilename,
                    destinationURL: nil,
                    bytesReceived: 0,
                    totalBytes: 0,
                    isFinished: true,
                    failureMessage: error.localizedDescription
                )
            }
            return nil
        }
    }

    public func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        pollers[key]?.cancel()
        pollers[key] = nil
        guard let info = infos[key] else { return }
        let finished = DownloadInfo(
            id: info.id,
            tabID: info.tabID,
            suggestedFilename: info.suggestedFilename,
            destinationURL: info.destinationURL,
            bytesReceived: info.bytesReceived,
            totalBytes: info.totalBytes,
            isFinished: true,
            failureMessage: nil
        )
        infos[key] = finished
        onUpdate?(finished)
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        pollers[key]?.cancel()
        pollers[key] = nil
        guard let info = infos[key] else { return }
        let failed = DownloadInfo(
            id: info.id,
            tabID: info.tabID,
            suggestedFilename: info.suggestedFilename,
            destinationURL: info.destinationURL,
            bytesReceived: info.bytesReceived,
            totalBytes: info.totalBytes,
            isFinished: true,
            failureMessage: error.localizedDescription
        )
        infos[key] = failed
        onUpdate?(failed)
    }
}
