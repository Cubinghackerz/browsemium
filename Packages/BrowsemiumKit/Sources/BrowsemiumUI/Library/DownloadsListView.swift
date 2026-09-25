import AppKit
import BrowsemiumData
import SwiftUI

@MainActor
struct DownloadsListView: View {
    let activeDownloads: [BrowserWindowModel.DownloadProgress]
    let history: [DownloadRecord]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if !activeDownloads.isEmpty {
                    sectionTitle("Downloading")
                    ForEach(activeDownloads) { download in
                        ActiveDownloadRow(download: download)
                    }
                }

                if !history.isEmpty {
                    if !activeDownloads.isEmpty {
                        sectionTitle("Recent downloads")
                    }
                    ForEach(history) { download in
                        DownloadHistoryRow(download: download)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color.browsemiumTertiary)
            .padding(.horizontal, 4)
            .padding(.top, 5)
            .padding(.bottom, 2)
    }
}

@MainActor
private struct ActiveDownloadRow: View {
    let download: BrowserWindowModel.DownloadProgress

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(Color.browsemiumPrimary)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(download.filename)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.browsemiumPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let fraction = download.fraction {
                    ProgressView(value: fraction)
                        .tint(Color.browsemiumPrimary)
                        .accessibilityLabel("Download progress for \(download.filename)")
                        .accessibilityValue(download.percentText)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.browsemiumPrimary)
                        .accessibilityLabel("Download progress for \(download.filename)")
                        .accessibilityValue("Starting")
                }

                HStack(spacing: 8) {
                    Text(progressDescription)
                    if let folder = download.destinationURL?.deletingLastPathComponent().lastPathComponent {
                        Text("·")
                        Text("Saving to \(folder)")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Color.browsemiumTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                .fill(Color.browsemiumHover.opacity(0.45))
        )
        .accessibilityElement(children: .contain)
    }

    private var progressDescription: String {
        guard download.totalBytes > 0 else {
            guard download.bytesReceived > 0 else { return "Preparing download…" }
            return "\(formatBytes(download.bytesReceived)) received"
        }
        return "\(download.percentText) · \(formatBytes(download.bytesReceived)) of \(formatBytes(download.totalBytes))"
    }
}

@MainActor
private struct DownloadHistoryRow: View {
    let download: DownloadRecord

    private var isDownloaded: Bool { download.state == .finished }

    var body: some View {
        Button(action: revealInFinder) {
            HStack(spacing: 11) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(statusColor)
                    .frame(width: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(download.suggestedFilename)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detailText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                    Text(download.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.browsemiumTertiary)
                }
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isDownloaded || download.destinationURL == nil)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                .fill(Color.browsemiumHover.opacity(0.28))
        )
        .accessibilityLabel("\(download.suggestedFilename), \(statusText)")
        .accessibilityHint(isDownloaded ? "Shows the downloaded file in Finder" : "")
    }

    private var statusText: String {
        switch download.state {
        case .inProgress: "Interrupted"
        case .finished: "Downloaded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private var statusSymbol: String {
        switch download.state {
        case .inProgress: "arrow.down.circle"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch download.state {
        case .inProgress: .browsemiumSecondary
        case .finished: .browsemiumSuccess
        case .failed: .browsemiumDestructive
        case .cancelled: .browsemiumTertiary
        }
    }

    private var detailText: String {
        if let failureMessage = download.failureMessage, !failureMessage.isEmpty {
            return failureMessage
        }
        if let folder = download.destinationURL?.deletingLastPathComponent().lastPathComponent {
            return "Saved to \(folder)"
        }
        return download.sourceURL.host ?? "Download location unavailable"
    }

    private func revealInFinder() {
        guard let destination = download.destinationURL, isDownloaded else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
}
