import BrowsemiumData
import SwiftUI

/// Closed-code report presentation: source values cannot enter these rows.
struct ImportReportDetails: View {
    let report: BrowserImportReport

    var body: some View {
        DisclosureGroup("Item report") {
            Text("Item numbers refer to source order. “Ready for transfer” does not mean saved. No passwords, cookie values, or site addresses appear here.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.browsemiumSecondary)
                .fixedSize(horizontal: false, vertical: true)
            List(report.items.indices, id: \.self) { index in
                let item = report.items[index]
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.ordinal == 0
                         ? "\(category(item.category)) source"
                         : "\(category(item.category)) item \(item.ordinal.formatted())")
                        .font(.system(size: 12, weight: .medium))
                    Text("\(stage(item.stage)): \(reason(item.reason))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(item.outcome == .failed ? Color.browsemiumDestructive : Color.browsemiumSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.plain)
            .frame(height: 180)
        }
        .foregroundStyle(Color.browsemiumPrimary)
    }

    private func category(_ value: BrowserImportReport.Category) -> String {
        switch value {
        case .bookmark: "Bookmark"
        case .history: "History"
        case .password: "Password"
        case .cookie: "Cookie"
        case .searchEngine: "Search engine"
        case .extension: "Extension"
        }
    }

    private func stage(_ value: BrowserImportReport.Stage) -> String {
        switch value {
        case .preview: "Preview"
        case .transfer: "Transfer"
        case .persistence: "Save"
        }
    }

    private func reason(_ value: BrowserImportReport.Reason) -> String {
        switch value {
        case .parsed: "Found in the source"
        case .imported: "Saved"
        case .alreadyPresent: "Already saved; no duplicate added"
        case .duplicateInSource: "Duplicate in the source"
        case .unsupportedURL: "Unsupported site address"
        case .invalidItem: "Invalid or expired item"
        case .sourceUnreadable: "Source could not be read; check access or try again after closing the source browser"
        case .destinationWriteFailed: "Could not save; retry the import"
        case .decryptionFailed: "Could not decrypt this item"
        case .notSelected: "Not selected"
        case .outsideSelection: "Outside the selected date range or item limit"
        case .preparedForTransfer: "Ready for transfer; not yet saved"
        case .limitExceeded: "Source exceeds the 50,000-item reader limit"
        }
    }
}
