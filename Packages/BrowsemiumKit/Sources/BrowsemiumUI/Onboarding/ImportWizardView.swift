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
    var offersCookies = true
    let keyConsentSources: [BrowserImportSource]
    let onKeyConsent: (_ allow: Bool) -> Void
    let onCancel: () -> Void
    let onImport: () -> Void

    private var bookmarkCount: Int { entries.reduce(0) { $0 + $1.preview.bookmarkCount } }
    private var historyCount: Int { entries.reduce(0) { $0 + $1.preview.historyCount } }
    private var passwordCount: Int { entries.reduce(0) { $0 + $1.preview.credentialCount } }
    private var cookieCount: Int { offersCookies ? entries.reduce(0) { $0 + $1.preview.cookieCount } : 0 }
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
                .font(BrowserType.font(.title, weight: .semibold))
            if isImporting {
                ProgressView(value: Double(completedCount), total: Double(max(entries.count, 1))) {
                    Text(currentProfile.map { "Importing \($0)…" } ?? "Preparing import…")
                }
                .controlSize(.small)
            }
            if report.isEmpty {
                Text("Each source profile gets its own Browsemium profile and separate site data. Importing again later adds to those profiles instead of making new ones. Review the totals before importing.")
                    .font(BrowserType.font(.small))
                    .foregroundStyle(Color.browsemiumSecondary)
                ForEach(entries, id: \.candidate.id) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.candidate.label).font(BrowserType.font(.small, weight: .medium))
                            if let email = entry.candidate.email {
                                Text(email).font(BrowserType.font(.caption)).foregroundStyle(Color.browsemiumTertiary)
                            }
                        }
                        Spacer()
                        Text("\(entry.preview.bookmarkCount) bookmarks · \(entry.preview.historyCount) visits")
                            .font(BrowserType.font(.caption))
                            .foregroundStyle(Color.browsemiumSecondary)
                    }
                    ImportReportDetails(report: entry.preview.report)
                }
                Toggle("Bookmarks (\(bookmarkCount))", isOn: $options.includesBookmarks)
                Toggle("History (\(historyCount))", isOn: $options.includesHistory)
                if passwordCount > 0 {
                    Toggle("Passwords (\(passwordCount))", isOn: $options.includesPasswords)
                    Text("You will be asked once per browser before its encryption key is read; macOS shows its own prompt. If you decline, everything else still imports and the password CSV option in the import guide can add the passwords.")
                        .font(BrowserType.font(.caption))
                        .foregroundStyle(Color.browsemiumSecondary)
                }
                if cookieCount > 0 {
                    Toggle("Cookies and sign-ins (\(cookieCount))", isOn: $options.includesCookies)
                    Text("Cookies can grant account access and are off by default. Encrypted cookies use the same browser key, asked once per browser; if you decline, sign in again.")
                        .font(BrowserType.font(.caption))
                        .foregroundStyle(Color.browsemiumWarning)
                }
                if searchCount > 0 {
                    Toggle("Default search engines (\(searchCount))", isOn: $options.includesSearchEngine)
                }
                Text("Unsupported items are reported per profile after import. Extension reinstall is offered for one profile at a time.")
                    .font(BrowserType.font(.caption))
                    .foregroundStyle(Color.browsemiumTertiary)
            } else {
                ForEach(report, id: \.self) { line in
                    Text(line).font(BrowserType.font(.small)).textSelection(.enabled)
                }
                ForEach(detailedReports.indices, id: \.self) { index in
                    ImportReportDetails(report: detailedReports[index])
                }
            }
            if !keyConsentSources.isEmpty {
                ImportKeyConsentCard(sources: keyConsentSources, onChoice: onKeyConsent)
            }
            HStack {
                BrowsemiumTextButton(report.isEmpty ? "Cancel" : "Done", action: onCancel)
                    .disabled(isImporting)
                Spacer()
                if report.isEmpty {
                    BrowsemiumPrimaryButton(isImporting ? "Importing…" : "Import \(entries.count) profiles",
                                            isDisabled: isImporting || entries.isEmpty || !hasSelectedData || !keyConsentSources.isEmpty,
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
