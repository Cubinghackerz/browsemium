import BrowsemiumData
import SwiftUI

/// The guided entry point shared by onboarding, New Tab, Settings and ⌘K.
/// SettingsView owns the existing preview, security scope and import workflow.
@MainActor
struct ImportWizardView: View {
    @Bindable var model: BrowserWindowModel

    var body: some View {
        SettingsView(model: model, importOnly: true)
    }
}

struct BatchImportEntry: Sendable {
    let candidate: BrowserProfileCandidate
    let preview: BrowserImportPreview
}

/// Each source profile maps to a new isolated Browsemium profile.
@MainActor
struct ImportBatchSheet: View {
    let entries: [BatchImportEntry]
    @Binding var options: BrowserImportOptions
    let isImporting: Bool
    let completedCount: Int
    let currentProfile: String?
    let report: [String]
    let detailedReports: [BrowserImportReport]
    let onCancel: () -> Void
    let onImport: () -> Void

    private var bookmarkCount: Int { entries.reduce(0) { $0 + $1.preview.bookmarkCount } }
    private var historyCount: Int { entries.reduce(0) { $0 + $1.preview.historyCount } }
    private var passwordCount: Int { entries.reduce(0) { $0 + $1.preview.credentialCount } }
    private var cookieCount: Int { entries.reduce(0) { $0 + $1.preview.cookieCount } }
    private var searchCount: Int { entries.filter { $0.preview.searchEngine != nil }.count }
    private var hasSelectedData: Bool {
        (options.includesBookmarks && bookmarkCount > 0)
            || (options.includesHistory && historyCount > 0)
            || (options.includesPasswords && passwordCount > 0)
            || (options.includesCookies && cookieCount > 0)
            || (options.includesSearchEngine && searchCount > 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(report.isEmpty ? "Move every profile" : "Import summary")
                .font(.system(size: 16, weight: .semibold))
            if isImporting {
                ProgressView(value: Double(completedCount), total: Double(max(entries.count, 1))) {
                    Text(currentProfile.map { "Importing \($0)…" } ?? "Preparing import…")
                }
                .controlSize(.small)
            }
            if report.isEmpty {
                Text("Each source profile gets its own Browsemium profile and separate site data. Review the totals before importing.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.browsemiumSecondary)
                ForEach(entries, id: \.candidate.id) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.candidate.label).font(.system(size: 12, weight: .medium))
                            if let email = entry.candidate.email {
                                Text(email).font(.system(size: 10.5)).foregroundStyle(Color.browsemiumTertiary)
                            }
                        }
                        Spacer()
                        Text("\(entry.preview.bookmarkCount) bookmarks · \(entry.preview.historyCount) visits")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.browsemiumSecondary)
                    }
                    ImportReportDetails(report: entry.preview.report)
                }
                Toggle("Bookmarks (\(bookmarkCount))", isOn: $options.includesBookmarks)
                Toggle("History (\(historyCount))", isOn: $options.includesHistory)
                if passwordCount > 0 {
                    Toggle("Passwords (\(passwordCount))", isOn: $options.includesPasswords)
                }
                if cookieCount > 0 {
                    Toggle("Cookies and sign-ins (\(cookieCount))", isOn: $options.includesCookies)
                    Text("Cookies can grant account access. This is off by default. macOS may ask to unlock the source browser's key.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.browsemiumWarning)
                }
                if searchCount > 0 {
                    Toggle("Default search engines (\(searchCount))", isOn: $options.includesSearchEngine)
                }
                Text("Unsupported items are reported per profile after import. Extension reinstall is offered for one profile at a time.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.browsemiumTertiary)
            } else {
                ForEach(report, id: \.self) { line in
                    Text(line).font(.system(size: 11.5)).textSelection(.enabled)
                }
                ForEach(detailedReports.indices, id: \.self) { index in
                    ImportReportDetails(report: detailedReports[index])
                }
            }
            HStack {
                BrowsemiumTextButton(report.isEmpty ? "Cancel" : "Done", action: onCancel)
                    .disabled(isImporting)
                Spacer()
                if report.isEmpty {
                    BrowsemiumPrimaryButton(isImporting ? "Importing…" : "Import \(entries.count) profiles",
                                            isDisabled: isImporting || entries.isEmpty || !hasSelectedData,
                                            action: onImport)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(22)
        .frame(width: 500)
        .background(Color.browsemiumSurface)
    }
}
