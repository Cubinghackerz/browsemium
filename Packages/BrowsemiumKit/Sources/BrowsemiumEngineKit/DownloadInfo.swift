import BrowsemiumCore
import Foundation

/// One download, as the window sees it. Both engines report progress with the
/// same shape so the downloads panel, the toolbar indicator and the database
/// writer stay engine-agnostic.
public struct DownloadInfo: Sendable, Identifiable {
    public let id: UUID
    public let tabID: TabID?
    public let suggestedFilename: String
    public let destinationURL: URL?
    public let bytesReceived: Int64
    public let totalBytes: Int64
    public let isFinished: Bool
    public let failureMessage: String?

    public init(
        id: UUID,
        tabID: TabID?,
        suggestedFilename: String,
        destinationURL: URL?,
        bytesReceived: Int64,
        totalBytes: Int64,
        isFinished: Bool,
        failureMessage: String?
    ) {
        self.id = id
        self.tabID = tabID
        self.suggestedFilename = suggestedFilename
        self.destinationURL = destinationURL
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.isFinished = isFinished
        self.failureMessage = failureMessage
    }
}
