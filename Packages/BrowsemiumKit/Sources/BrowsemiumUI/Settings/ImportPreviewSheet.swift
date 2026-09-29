import BrowsemiumData
import SwiftUI
import BrowsemiumEngineKit

/// Shows exactly what a browser profile contains before anything is written.
@MainActor
struct ImportPreviewSheet: View {
    let preview: BrowserImportPreview
    @Binding var options: BrowserImportOptions
    @Binding var destination: BrowserImportDestination
    @Binding var newProfileName: String
    let currentProfileName: String
    let isImporting: Bool
    let onCancel: () -> Void
    let onImport: () -> Void

    private var hasSelectedData: Bool {
        (options.includesBookmarks && preview.bookmarkCount > 0)
            || (options.includesHistory && preview.historyCount > 0)
            || (options.includesPasswords && preview.credentialCount > 0)
            || (options.includesCookies && preview.cookieCount > 0)
            || (options.includesExtensions && !preview.extensionIDs.isEmpty)
            || (options.includesSearchEngine && preview.searchEngine != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from \(preview.source.displayName)")
                    .font(.system(size: 15, weight: .semibold))
                Text("Review what was found. Nothing has been added yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.browsemiumSecondary)
            }

            summary

            destinationPicker

            if preview.bookmarkCount > 0 {
                scopeRow(
                    title: "Bookmarks",
                    detail: bookmarkDetail,
                    isOn: $options.includesBookmarks
                )
            }

            if preview.historyCount > 0 {
                scopeRow(
                    title: "History",
                    detail: historyDetail,
                    isOn: $options.includesHistory
                )

                if options.includesHistory {
                    Picker("History range", selection: rangeBinding) {
                        Text("Everything").tag(0)
                        Text("Last 90 days").tag(90)
                        Text("Last 30 days").tag(30)
                        Text("Last 7 days").tag(7)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("History range")
                }
            }

            if preview.credentialCount > 0 {
                scopeRow(
                    title: "Passwords",
                    detail: "\(preview.credentialCount) saved logins. macOS may ask to read \(preview.source.safeStorageService ?? "the source browser's key"); imported logins go to your keychain.",
                    isOn: $options.includesPasswords
                )
            }

            if preview.cookieCount > 0 {
                scopeRow(
                    title: "Cookies and sign-ins",
                    detail: "\(preview.cookieCount) cookies. They can grant account access. Import only into a profile you control; some sites may still ask you to sign in.",
                    isOn: $options.includesCookies
                )
                if options.includesCookies, let service = preview.source.safeStorageService {
                    Text("macOS may ask to unlock \(service) before importing.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.browsemiumWarning)
                }
            }

            if !preview.extensionIDs.isEmpty {
                scopeRow(
                    title: "Extensions",
                    detail: "\(preview.extensionIDs.count) installed. You will confirm reinstall separately; each starts disabled.",
                    isOn: $options.includesExtensions
                )
            }

            if preview.searchEngine != nil {
                scopeRow(
                    title: "Default search engine",
                    detail: preview.searchEngine.map { "Use \($0.name) for new searches" } ?? "",
                    isOn: $options.includesSearchEngine
                )
            }

            if preview.isEmpty {
                Text("No supported data was found in this profile.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.browsemiumWarning)
            }

            if !preview.notImportable.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(preview.notImportable, id: \.self) { note in
                        Text("• \(note)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.browsemiumTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if isImporting {
                ProgressView("Importing into Browsemium…")
                    .controlSize(.small)
            }

            HStack {
                BrowsemiumTextButton("Cancel", action: onCancel)
                    .disabled(isImporting)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                BrowsemiumPrimaryButton(
                    isImporting ? "Importing…" : importButtonTitle,
                    isDisabled: isImporting || !hasSelectedData,
                    action: onImport
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Color.browsemiumSurface)
        .foregroundStyle(Color.browsemiumPrimary)
    }

    /// Importing into a new profile creates it first, so the data lands in its
    /// own isolated database instead of the current profile's.
    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import into")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.browsemiumTertiary)

            Picker("Import into", selection: $destination) {
                Text(currentProfileName).tag(BrowserImportDestination.currentProfile)
                Text("New profile").tag(BrowserImportDestination.newProfile)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Import destination")

            if destination == .newProfile {
                TextField("Profile name", text: $newProfileName)
                    .font(.system(size: 12))
                    .browsemiumField()
                    .frame(height: 24)
                    .padding(.horizontal, 8)
                    .accessibilityLabel("New profile name")
                Text("Creates a profile with its own logins and browsing data, then imports into it.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
        }
    }

    private var importButtonTitle: String {
        destination == .newProfile ? "Create Profile & Import" : "Import"
    }

    private var summary: some View {
        HStack(spacing: 8) {
            summaryTile("\(preview.bookmarkCount)", "Bookmarks")
            summaryTile("\(preview.historyCount)", "History entries")
            summaryTile("\(preview.folders.count)", "Folders")
            summaryTile("\(preview.credentialCount)", "Passwords")
            summaryTile("\(preview.cookieCount)", "Cookies")
            if !preview.extensionIDs.isEmpty { summaryTile("\(preview.extensionIDs.count)", "Extensions") }
        }
    }

    private func summaryTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.browsemiumTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                .fill(Color.browsemiumField)
        )
    }

    private func scopeRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.browsemiumAccentFill)
                .accessibilityLabel(title)
        }
    }

    private var bookmarkDetail: String {
        preview.folders.isEmpty
            ? "Folder structure is not preserved in this profile."
            : "Folders preserved: \(preview.folders.prefix(4).joined(separator: ", "))\(preview.folders.count > 4 ? "…" : "")"
    }

    private var historyDetail: String {
        guard let earliest = preview.earliestVisit, let latest = preview.latestVisit else {
            return "No dated history found."
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(formatter.string(from: earliest)) – \(formatter.string(from: latest))"
    }

    /// 0 means "everything".
    private var rangeBinding: Binding<Int> {
        Binding(
            get: {
                guard let since = options.historySince else { return 0 }
                let days = Calendar.current.dateComponents([.day], from: since, to: Date()).day ?? 0
                return [90, 30, 7].first { abs($0 - days) <= 1 } ?? 0
            },
            set: { days in
                options.historySince = days == 0
                    ? nil
                    : Calendar.current.date(byAdding: .day, value: -days, to: Date())
            }
        )
    }
}
