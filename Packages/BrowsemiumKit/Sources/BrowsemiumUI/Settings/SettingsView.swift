import AppKit
import Darwin
import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumData
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import BrowsemiumEngineKit

private struct UnlockedImportKeyProvider: BrowserCredentialKeyProviding {
    let key: Data

    func safeStorageKey(for source: BrowserImportSource) throws -> Data? { key }
}

@MainActor
struct SettingsView: View {
    @Bindable var model: BrowserWindowModel
    var importOnly = false
    @State private var settings: BrowserSettings = BrowserSettings()
    @State private var isConfirmingClear = false
    @State private var statusMessage: String?
    @State private var credentialStates: [AIProviderID: Bool] = [:]
    @State private var keyPromptProvider: AIProviderID?
    @State private var keyInput = ""
    @State private var isAddingPassword = false
    @State private var credentialHost = ""
    @State private var credentialUsername = ""
    @State private var credentialPassword = ""
    @State private var importCandidates: [BrowserProfileCandidate] = []
    @State private var installedImportSources: [BrowserImportSource] = []
    @State private var importingID: String?
    @State private var isImporting = false
    @State private var importPreview: BrowserImportPreview?
    @State private var importOptions = BrowserImportOptions()
    @State private var importFolder: URL?
    @State private var importLastSummary: String?
    @State private var importLastReport: BrowserImportReport?
    @State private var isPreparingPreview = false
    @State private var importDestination: BrowserImportDestination = .currentProfile
    @State private var importNewProfileName = ""
    /// When a candidate lives inside a granted browser root, the scope has to
    /// be opened on the root while its child profile is read.
    @State private var importAccessRoot: URL?
    @State private var isAddingProfile = false
    @State private var newProfileNameText = ""
    @State private var profileRenameTarget: BrowserProfile?
    @State private var profileRenameText = ""
    @State private var profileDeleteTarget: BrowserProfile?
    @State private var profiles: [BrowserProfile] = []
    @State private var isDefaultBrowser = DefaultBrowser.isDefault
    @State private var chromeWebStoreInput = ""
    @State private var isSearchEngineMenuPresented = false
    @State private var isHistoryMenuPresented = false
    @AppStorage("browsemium.screenshotWatermark") private var screenshotWatermark = false
    @State private var csvImport: BrowserPasswordCSV?
    @State private var isShowingCSVImport = false
    @State private var isConfirmingCSVExport = false
    @State private var batchEntries: [BatchImportEntry] = []
    @State private var batchOptions = BrowserImportOptions()
    @State private var batchAccessRoot: URL?
    @State private var batchReport: [String] = []
    @State private var batchDetailedReports: [BrowserImportReport] = []
    @State private var isShowingBatch = false
    @State private var isBatchImporting = false
    @State private var batchCompletedCount = 0
    @State private var batchCurrentProfile: String?
    @State private var pendingExtensionIDs: [String] = []
    @State private var isConfirmingExtensionReinstall = false

    private let retentionOptions: [(label: String, days: Int?)] = [
        ("7 days", 7),
        ("30 days", 30),
        ("90 days", 90),
        ("Until I clear it", nil)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.browsemiumBorder).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if importOnly {
                        importSection
                    } else {
                        generalSection
                        profilesSection
                        browsingSection
                        performanceSection
                        SettingsCard("Move to Browsemium", systemImage: "square.and.arrow.down") {
                            SettingsRow("From another browser") {
                                BrowsemiumPrimaryButton("Open import guide") {
                                    model.openPanel(.importWizard)
                                }
                            }
                        }
                        privacySection
                        extensionsSection
                        sitePermissionsSection
                        passwordsSection
                        assistantSection
                        aboutSection
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.browsemiumRaised)
        .onAppear {
            settings = model.environment.loadSettings()
            refreshCredentials()
            refreshProfiles()
            model.refreshSavedCredentials()
            refreshImportCandidates()
        }
        .onChange(of: model.profileSwitchToken) {
            refreshProfiles()
        }
        .onChange(of: model.searchEngineTemplate) { _, template in
            settings.searchEngineTemplate = template
        }
        .sheet(item: $importPreview) { preview in
            ImportPreviewSheet(
                preview: preview,
                options: $importOptions,
                destination: $importDestination,
                newProfileName: $importNewProfileName,
                currentProfileName: model.activeProfile.name,
                isImporting: isImporting,
                onCancel: {
                    importPreview = nil
                    importFolder = nil
                },
                onImport: commitImport
            )
        }
        .sheet(isPresented: $isAddingPassword) {
            PasswordEditorSheet(
                host: $credentialHost,
                username: $credentialUsername,
                password: $credentialPassword,
                onCancel: { isAddingPassword = false },
                onSave: savePassword
            )
        }
        .sheet(isPresented: $isShowingCSVImport, onDismiss: { csvImport = nil }) {
            if let csvImport {
                PasswordCSVImportSheet(csv: csvImport,
                                       onCancel: { isShowingCSVImport = false },
                                       onImport: importPasswordsFromCSV)
            }
        }
        .sheet(isPresented: $isShowingBatch) {
            ImportBatchSheet(entries: batchEntries,
                             options: $batchOptions,
                             isImporting: isBatchImporting,
                             completedCount: batchCompletedCount,
                             currentProfile: batchCurrentProfile,
                             report: batchReport,
                             detailedReports: batchDetailedReports,
                             onCancel: { isShowingBatch = false },
                             onImport: commitBatchImport)
        }
        .confirmationDialog("Export passwords as an unencrypted CSV?",
                            isPresented: $isConfirmingCSVExport,
                            titleVisibility: .visible) {
            Button("Export CSV") { exportPasswordsToCSV() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone with the exported file can read every password in it. Delete the file after moving it to a trusted password manager.")
        }
        .confirmationDialog("Reinstall \(pendingExtensionIDs.count) extensions?",
                            isPresented: $isConfirmingExtensionReinstall,
                            titleVisibility: .visible) {
            Button("Reinstall from Chrome Web Store") {
                let ids = pendingExtensionIDs
                pendingExtensionIDs = []
                Task {
                    let outcome = await model.reinstallImportedExtensions(ids)
                    statusMessage = "\(outcome.installed) extensions installed disabled; \(outcome.skipped) skipped."
                }
            }
            Button("Not now", role: .cancel) { pendingExtensionIDs = [] }
        } message: {
            Text("Browsemium downloads each selected extension from the Chrome Web Store. Every new extension starts disabled and needs your approval to run.")
        }
        .confirmationDialog(
            "Clear browsing data?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear history, downloads, permissions, and closed tabs", role: .destructive) {
                model.clearBrowsingData()
                statusMessage = "Browsing data cleared."
            }
            Button("Clear cookies, site data, and cache", role: .destructive) {
                model.clearCookiesAndSiteData()
                statusMessage = "Cookies, site data, and cache cleared for this profile."
            }
            Button("Clear cache only", role: .destructive) {
                model.clearCache()
                statusMessage = "Cache cleared for this profile."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bookmarks, settings, and saved API keys are kept. Site data belongs to the active profile only.")
        }
        .alert(
            "\(keyPromptProvider.map { ProviderPanelDescriptor.descriptor(for: $0).displayName } ?? "") API key",
            isPresented: Binding(
                get: { keyPromptProvider != nil },
                set: { if !$0 { keyPromptProvider = nil } }
            )
        ) {
            SecureField("sk-…", text: $keyInput)
            Button("Save") { saveKey() }
            Button("Cancel", role: .cancel) { keyInput = "" }
        } message: {
            Text("Stored in your macOS keychain. Sent only to this provider.")
        }
        .alert("New Profile", isPresented: $isAddingProfile) {
            TextField("Name", text: $newProfileNameText)
            Button("Create") {
                let name = newProfileNameText
                newProfileNameText = ""
                model.createProfile(named: name.isEmpty ? "Profile \(profiles.count + 1)" : name)
                refreshProfiles()
            }
            Button("Cancel", role: .cancel) { newProfileNameText = "" }
        } message: {
            Text("Starts empty, with its own logins and browsing data.")
        }
        .alert(
            "Rename Profile",
            isPresented: Binding(
                get: { profileRenameTarget != nil },
                set: { if !$0 { profileRenameTarget = nil } }
            )
        ) {
            TextField("Name", text: $profileRenameText)
            Button("Rename") {
                if let target = profileRenameTarget {
                    model.renameProfile(target, to: profileRenameText)
                }
                profileRenameTarget = nil
                refreshProfiles()
            }
            Button("Cancel", role: .cancel) { profileRenameTarget = nil }
        }
        .confirmationDialog(
            "Delete “\(profileDeleteTarget?.name ?? "")”?",
            isPresented: Binding(
                get: { profileDeleteTarget != nil },
                set: { if !$0 { profileDeleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete profile and all of its data", role: .destructive) {
                if let target = profileDeleteTarget {
                    Task { @MainActor in
                        await model.deleteProfile(target)
                        refreshProfiles()
                    }
                }
                profileDeleteTarget = nil
            }
            Button("Cancel", role: .cancel) { profileDeleteTarget = nil }
        } message: {
            Text("Its bookmarks, history, passwords, logins, and site data are removed from this Mac.")
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
        SettingsCard("General", systemImage: "gearshape") {
            SettingsRow("Appearance") {
                BrowsemiumTabPicker(
                    values: AppearancePreference.allCases,
                    selection: Binding(
                        get: { settings.appearance },
                        set: { newValue in
                            settings.appearance = newValue
                            save()
                        }
                    ),
                    label: \.title
                )
                .accessibilityLabel("Appearance")
            }

            SettingsRow("Tab layout") {
                BrowsemiumTabPicker(
                    values: TabLayout.allCases,
                    selection: settingBinding(\.tabLayout),
                    label: \.title
                )
                .accessibilityLabel("Tab layout")
            }

            SettingsRow("Default browser") {
                HStack(spacing: 8) {
                    if isDefaultBrowser {
                        Text("Browsemium opens links from other apps")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.browsemiumTertiary)
                    } else {
                        BrowsemiumTextButton("Make Default") {
                            Task { @MainActor in
                                if await DefaultBrowser.requestDefault() {
                                    isDefaultBrowser = true
                                    statusMessage = "Browsemium is now the default browser"
                                } else {
                                    DefaultBrowser.openSystemSettings()
                                    statusMessage = "Set Browsemium as the default in System Settings"
                                }
                            }
                        }
                    }
                }
            }

            SettingsToggleRow("Watermark saved screenshots", isOn: $screenshotWatermark)
            SettingsNote("Adds a small Browsemium signature only to PNGs you save. AI attachments stay unmarked.")
        }
    }

    private var profilesSection: some View {
        SettingsCard("Profiles", systemImage: "person.2") {
            ForEach(profiles) { profile in
                SettingsRow(profile.name) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.browsemiumSelection)
                            Text(profile.initials)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Color.browsemiumSecondary)
                        }
                        .frame(width: 20, height: 20)

                        if profile.id == model.activeProfile.id {
                            Text("Active")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.browsemiumTertiary)
                        } else {
                            BrowsemiumTextButton("Switch") {
                                model.switchProfile(to: profile)
                                refreshProfiles()
                            }
                        }
                        BrowsemiumTextButton("Rename") {
                            profileRenameTarget = profile
                            profileRenameText = profile.name
                        }
                        if profiles.count > 1 {
                            BrowsemiumTextButton("Delete", role: .destructive) {
                                profileDeleteTarget = profile
                            }
                        }
                    }
                }
            }

            SettingsRow("Add a profile") {
                BrowsemiumTextButton("New Profile…") {
                    newProfileNameText = ""
                    isAddingProfile = true
                }
            }

            SettingsNote("Each profile keeps its own tabs, bookmarks, history, passwords, logins, and site data. Nothing is shared between them.")
        }
    }

    /// The profile list lives outside the observable model, so it is mirrored
    /// into state and refreshed after every mutation — otherwise adding or
    /// renaming a profile leaves the list stale.
    private func refreshProfiles() {
        profiles = model.profiles
    }

    private var browsingSection: some View {
        SettingsCard("Browsing", systemImage: "globe") {
            SettingsRow("Search engine") {
                HStack(spacing: 10) {
                    Button {
                        isSearchEngineMenuPresented = true
                    } label: {
                        HStack(spacing: 6) {
                            SearchEngineMark(
                                engineName: SearchEnginePreset.name(for: settings.searchEngineTemplate),
                                size: 16
                            )
                            Text(SearchEnginePreset.name(for: settings.searchEngineTemplate))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.browsemiumPrimary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color.browsemiumTertiary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.browsemiumField)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isSearchEngineMenuPresented, arrowEdge: .bottom) {
                        SearchEngineMenuPanel(model: model) {
                            isSearchEngineMenuPresented = false
                        }
                        .presentationBackground(.clear)
                    }
                    .accessibilityLabel("Search engine")

                    if searchEngineBinding.wrappedValue == Self.customEngineTag {
                        TextField("https://…", text: $settings.searchEngineTemplate)
                            .font(.system(size: 12))
                            .browsemiumField()
                            .frame(width: 190, height: 24)
                            .padding(.horizontal, 8)
                            .onSubmit { save() }
                            .accessibilityLabel("Custom search engine URL template")
                    }
                }
            }

            SettingsRow("Keep history for") {
                Button {
                    isHistoryMenuPresented = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.browsemiumSecondary)
                        Text(retentionOptions.first { $0.days == settings.historyRetentionDays }?.label ?? "90 days")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.browsemiumPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.browsemiumTertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.browsemiumField)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isHistoryMenuPresented, arrowEdge: .bottom) {
                    MenuPanelContainer {
                        ForEach(retentionOptions, id: \.label) { option in
                            MenuPanelRow(
                                title: option.label,
                                isSelected: settings.historyRetentionDays == option.days
                            ) {
                                settings.historyRetentionDays = option.days
                                save()
                                isHistoryMenuPresented = false
                            } icon: {
                                Image(systemName: "clock")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.browsemiumSecondary)
                            }
                        }
                    }
                    .presentationBackground(.clear)
                }
                .accessibilityLabel("History retention")
            }

            SettingsToggleRow(
                "Clear history when Browsemium quits",
                isOn: settingBinding(\.clearOnQuit)
            )
            SettingsToggleRow(
                "Preview links on hover",
                isOn: settingBinding(\.linkPreviewOnHover)
            )
            SettingsNote("Off by default. Rest the pointer on a link to open a preview. The preview loads that page.")
        }
    }

    private var performanceSection: some View {
        SettingsCard("Performance & Memory", systemImage: "gauge.with.needle") {
            SettingsToggleRow("Memory saver", isOn: settingBinding(\.memorySaverEnabled))

            if settings.memorySaverEnabled {
                SettingsRow("Unload background tabs after") {
                    Picker("Unload background tabs after", selection: settingBinding(\.tabSleepMinutes)) {
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityLabel("Unload background tabs after")
                }

                SettingsRow("Keep at most loaded") {
                    Picker("Keep at most loaded", selection: settingBinding(\.maximumLiveTabs)) {
                        Text("2 tabs").tag(2)
                        Text("4 tabs").tag(4)
                        Text("6 tabs").tag(6)
                        Text("10 tabs").tag(10)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityLabel("Maximum loaded tabs")
                }
            }

            SettingsToggleRow("Preload a tab for instant opening", isOn: settingBinding(\.warmTabPreloading))

            SettingsRow("Memory in use") {
                HStack(spacing: 12) {
                    Text(model.currentMemoryFootprint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.browsemiumSecondary)
                    BrowsemiumTextButton("Free memory now") { model.freeMemoryNow() }
                }
            }

            SettingsRow("Tabs loaded") {
                Text("\(model.liveWebViewCount) loaded · \(model.sleepingTabCount) sleeping")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.browsemiumSecondary)
            }

            SettingsNote("Browsemium unloads background tabs instead of keeping every page in memory, so a tab may reload when you return to it. The figure above covers the \(model.memoryScopeDescription); WebKit does not expose per-tab memory.")
        }
    }

    private var importSection: some View {
        SettingsCard("Import from another browser", systemImage: "square.and.arrow.down") {
            SettingsNote("Installed browsers are detected automatically. Choose one to grant access; Browsemium finds its profiles and previews what can move. Nothing changes in the source browser.")

            let readableSources = Set(importCandidates.filter(\.isReadable).map(\.source))
            let readableCandidates = importCandidates.filter(\.isReadable)
            let sourcesNeedingAccess = installedImportSources.filter { !readableSources.contains($0) }
            let manualCandidates = importCandidates.filter {
                !$0.isReadable && !installedImportSources.contains($0.source)
            }

            ForEach(BrowserImportSource.allCases) { source in
                if readableSources.contains(source) {
                    SettingsRow("Every \(source.displayName) profile") {
                        BrowsemiumTextButton("Review all profiles…") { beginBatchReview(source: source) }
                            .disabled(isImporting || isBatchImporting)
                    }
                }
            }

            ForEach(sourcesNeedingAccess) { source in
                SettingsRow(source.displayName) {
                    HStack(spacing: 10) {
                        Text("Installed")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.browsemiumTertiary)
                        BrowsemiumTextButton("Find profiles…") {
                            beginImport(source: source)
                        }
                        .disabled(isImporting || isBatchImporting)
                    }
                }
            }

            ForEach(readableCandidates) { candidate in
                SettingsRow(candidate.label) {
                    HStack(spacing: 10) {
                        if let email = candidate.email {
                            Text(email)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.browsemiumTertiary)
                                .lineLimit(1)
                        }
                        Text("Ready")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.browsemiumSuccess)
                        BrowsemiumTextButton(importingID == candidate.id ? "Reading…" : "Review") {
                            beginImport(candidate)
                        }
                        .disabled(isImporting)
                    }
                }
            }

            ForEach(manualCandidates) { candidate in
                SettingsRow(candidate.label) {
                    HStack(spacing: 10) {
                        Text("Access needed")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.browsemiumTertiary)
                        BrowsemiumTextButton("Find profiles…") {
                            beginImport(candidate)
                        }
                        .disabled(isImporting || isBatchImporting)
                    }
                }
            }

            if installedImportSources.isEmpty && importCandidates.isEmpty {
                SettingsRow("No supported browser app found") {
                    Text("You can still choose a saved profile folder or import a password CSV below.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.browsemiumSecondary)
                }
            }
            SettingsRow("Another folder") {
                BrowsemiumTextButton("Choose…") { chooseImportFolder() }
                    .disabled(isImporting)
            }
            SettingsRow("Password manager CSV") {
                BrowsemiumTextButton("Choose CSV…") { choosePasswordCSV() }
            }
            SettingsNote("Apple Passwords, 1Password, Bitwarden, LastPass, and Dashlane can export CSV. The next step maps columns and previews counts; the file is never uploaded.")

            if let importLastSummary {
                SettingsRow("Last import") {
                    Text(importLastSummary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.browsemiumPrimary)
                }
            }

            if let importLastReport {
                ImportReportDetails(report: importLastReport)
            }

            if isPreparingPreview {
                SettingsRow("Reading profile") {
                    ProgressView().controlSize(.small)
                }
            }
            SettingsNote("macOS asks before Browsemium reads browser files, then remembers that folder choice. Review counts before importing; cookies are optional and extensions need separate confirmation. Site storage does not move. Nothing is uploaded or removed from the source browser.")
        }
    }

    private var privacySection: some View {
        SettingsCard("Privacy & Blocking", systemImage: "hand.raised") {
            SettingsRow("Content protection") {
                BrowsemiumTabPicker(
                    values: ProtectionLevel.allCases,
                    selection: Binding(
                        get: { settings.protectionLevel },
                        set: { newValue in
                            settings.protectionLevel = newValue
                            save()
                        }
                    ),
                    label: { $0.title }
                )
                .accessibilityLabel("Content protection level")
            }

            SettingsRow("Content rules") {
                Text(contentRuleStatusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(contentRuleStatusColor)
            }

            SettingsRow("Browsing data") {
                HStack(spacing: 14) {
                    BrowsemiumTextButton("Clear browsing data…") { isConfirmingClear = true }
                    BrowsemiumTextButton("Clear cookies and site data", role: .destructive) {
                        model.clearCookiesAndSiteData()
                        statusMessage = "Cookies and site data cleared for this profile."
                    }
                }
            }

            SettingsNote(settings.protectionLevel.summary)
        }
    }

    private var extensionsSection: some View {
        SettingsCard("Extensions", systemImage: "puzzlepiece.extension") {
            if let reason = model.extensionsUnavailableReason {
                SettingsRow("Not available") {
                    Text(reason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.browsemiumSecondary)
                }
            } else if model.installedExtensions.isEmpty {
                SettingsRow("No extensions installed") {
                    BrowsemiumTextButton("Install extension…") { presentExtensionInstaller() }
                }
            } else {
                ForEach(model.installedExtensions) { record in
                    SettingsRow(record.name) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.version.isEmpty ? "WebExtension" : "Version \(record.version)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.browsemiumTertiary)
                                if let error = record.lastError {
                                    Text(error)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.browsemiumWarning)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                            BrowsemiumIconButton(
                                systemName: model.isExtensionActionVisible(record.id) ? "pin" : "pin.slash",
                                label: model.isExtensionActionVisible(record.id)
                                    ? "Hide \(record.name) from the toolbar"
                                    : "Show \(record.name) in the toolbar",
                                isActive: model.isExtensionActionVisible(record.id)
                            ) {
                                model.setExtensionActionVisible(
                                    record.id,
                                    isVisible: !model.isExtensionActionVisible(record.id)
                                )
                            }
                            Toggle("", isOn: Binding(
                                get: { record.isEnabled },
                                set: { model.setExtensionEnabled(record.id, isEnabled: $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel("Enable \(record.name)")
                            BrowsemiumTextButton("Remove", role: .destructive) {
                                model.removeExtension(record.id)
                            }
                        }
                    }
                }
                SettingsRow("Install another") {
                    BrowsemiumTextButton("Install extension…") { presentExtensionInstaller() }
                }
            }

            if model.extensionsUnavailableReason == nil {
                SettingsToggleRow(
                    "Offer to install when a Chrome Web Store listing is open",
                    isOn: settingBinding(\.offerWebStoreInstalls)
                )
                SettingsRow("Chrome Web Store") {
                    HStack(spacing: 8) {
                        Text("Beta")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.browsemiumAccentFillText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.browsemiumAccentFill))
                        TextField("Store link or extension ID", text: $chromeWebStoreInput)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(minWidth: 170)
                            .onSubmit { installFromChromeWebStore() }
                        BrowsemiumTextButton(model.isInstallingFromWebStore ? "Installing…" : "Install") {
                            installFromChromeWebStore()
                        }
                        .disabled(model.isInstallingFromWebStore)
                    }
                }
                SettingsNote("Beta — the package is fetched from Google's public update service with only the extension ID; no browsing data is sent. Chrome-format extensions run on WebKit's extension API, so anything WebKit does not support simply does not run. Chrome Web Store is a trademark of Google; each extension's own terms apply.")
            }

            SettingsNote("Browsemium runs extensions through WebKit's public extension API, gated on macOS 15.4 or newer. Extensions are per profile, start disabled, and ask before they get host access. WebKit extensions cannot intercept network requests — first-party blocking stays with Browsemium's own content rules. Installed files live under Application Support/Browsemium/Extensions.")
        }
    }

    private func presentExtensionInstaller() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Extension"
        panel.message = "Pick an unpacked extension folder, a .zip, a .crx, or an .appex bundle."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.installExtension(from: url)
    }

    private func installFromChromeWebStore() {
        let input = chromeWebStoreInput
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.installExtensionFromChromeWebStore(input)
        chromeWebStoreInput = ""
    }

    private var sitePermissionsSection: some View {
        SettingsCard("Site permissions", systemImage: "checkmark.shield") {
            if model.sitePermissions.isEmpty {
                SettingsRow("Nothing allowed yet") {
                    Text("Sites that ask for your camera or microphone appear here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.browsemiumSecondary)
                }
            } else {
                ForEach(model.sitePermissions) { record in
                    SettingsRow(record.origin) {
                        HStack(spacing: 12) {
                            Text("\(record.kind.displayName) · \(record.decision == .allow ? "Allowed" : "Blocked")")
                                .font(.system(size: 11.5))
                                .foregroundStyle(record.decision == .allow ? Color.browsemiumSecondary : Color.browsemiumWarning)
                            BrowsemiumTextButton("Remove", role: .destructive) {
                                model.removeSitePermission(record)
                                statusMessage = "Permission removed."
                            }
                        }
                    }
                }
                SettingsRow("All sites") {
                    BrowsemiumTextButton("Remove every permission", role: .destructive) {
                        try? model.environment.permissionRepository.removeAll()
                        model.refreshSitePermissions()
                        statusMessage = "Site permissions removed."
                    }
                }
            }

            SettingsNote("A site is asked once per profile. Allow answers apply to that page load only; Always allow and Block are remembered until you remove them.")
        }
    }

    private var passwordsSection: some View {
        SettingsCard("Passwords", systemImage: "key") {
            if model.savedCredentials.isEmpty {
                SettingsRow("No saved passwords") {
                    BrowsemiumTextButton("Add password…") { presentPasswordEditor() }
                }
            } else {
                ForEach(model.savedCredentials) { credential in
                    SettingsRow(credential.host) {
                        HStack(spacing: 12) {
                            Text(credential.username)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.browsemiumSecondary)
                            BrowsemiumTextButton("Remove", role: .destructive) {
                                model.removeCredential(credential)
                            }
                        }
                    }
                }
                SettingsRow("Add another login") {
                    BrowsemiumTextButton("Add password…") { presentPasswordEditor() }
                }
            }
            SettingsNote("Passwords are encrypted by macOS Keychain. Browsemium only fills them after you choose a login, and never submits the form for you.")
            SettingsRow("Portable backup") {
                BrowsemiumTextButton("Export CSV…") { isConfirmingCSVExport = true }
                    .disabled(model.savedCredentials.isEmpty)
            }
        }
    }

    private var assistantSection: some View {
        SettingsCard("Assistant", systemImage: "sparkles") {
            SettingsToggleRow("Show the assistant", isOn: settingBinding(\.isAIDockEnabled))
            SettingsToggleRow("Save conversations on this Mac", isOn: settingBinding(\.persistAIConversations))
            SettingsToggleRow("Include automatic page text + metadata in web AI", isOn: settingBinding(\.includePageMetadataInWebAI))
            SettingsToggleRow("Attach this page's text to API messages", isOn: settingBinding(\.includePageContextInAPIAI))

            ForEach(AIProviderID.allCases, id: \.self) { provider in
                SettingsRow(ProviderPanelDescriptor.descriptor(for: provider).displayName) {
                    if provider.isLocal {
                        Text("Runs on this Mac — no key, nothing leaves it")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.browsemiumSecondary)
                    } else {
                        HStack(spacing: 12) {
                            Text(credentialStates[provider] == true ? "API key saved" : "No API key")
                                .font(.system(size: 11.5))
                                .foregroundStyle(
                                    credentialStates[provider] == true
                                        ? Color.browsemiumSecondary
                                        : Color.browsemiumTertiary
                                )
                            if credentialStates[provider] == true {
                                BrowsemiumTextButton("Remove", role: .destructive) {
                                    try? model.environment.keychain.deleteSecret(
                                        account: model.environment.providerCredentialAccount(provider)
                                    )
                                    try? model.environment.keychain.deleteSecret(account: "provider.\(provider.rawValue)")
                                    refreshCredentials()
                                }
                            } else {
                                BrowsemiumTextButton("Add key…") {
                                    keyInput = ""
                                    keyPromptProvider = provider
                                }
                            }
                        }
                    }
                }
            }

            SettingsNote("When enabled, Web AI adds the current page title, a sanitized URL, readable page text when available, and a bounded full-page screenshot uploaded through the provider's verified file input. API keys stay in your macOS keychain; website panels use your own subscriptions.")
        }
    }

    private var aboutSection: some View {
        SettingsCard("About", systemImage: "info.circle") {
            SettingsRow("Browsemium") {
                Text("WebKit · macOS 14+")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
            SettingsNote("No Browsemium account or product telemetry. Websites, enabled extensions, searches, and your chosen AI provider still make network requests.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(importOnly ? "Move to Browsemium" : "Settings")
                .font(.system(size: 13, weight: .semibold))
            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .transition(.opacity)
            }
            Spacer()
            BrowsemiumTextButton("Done") { model.activePanel = .none }
        }
        .padding(.horizontal, 16)
        .frame(height: BrowserMetrics.toolbarHeight)
    }

    // MARK: - Bindings and actions

    private static let customEngineTag = "__custom__"

    private var searchEngineBinding: Binding<String> {
        Binding(
            get: {
                SearchEnginePreset.all.contains { $0.template == settings.searchEngineTemplate }
                    ? settings.searchEngineTemplate
                    : Self.customEngineTag
            },
            set: { newValue in
                if newValue != Self.customEngineTag {
                    settings.searchEngineTemplate = newValue
                    save()
                }
            }
        )
    }

    private var retentionBinding: Binding<Int> {
        Binding(
            get: { settings.historyRetentionDays ?? -1 },
            set: {
                settings.historyRetentionDays = $0 < 0 ? nil : $0
                save()
            }
        )
    }

    private func settingBinding<Value>(_ keyPath: WritableKeyPath<BrowserSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: {
                settings[keyPath: keyPath] = $0
                save()
            }
        )
    }

    private func save() {
        model.updateSettings { stored in
            stored = settings
        }
        statusMessage = "Saved"
    }

    private var contentRuleStatusText: String {
        switch model.contentRuleState {
        case .inactive:
            "Off"
        case .compiling:
            "Compiling…"
        case .active:
            "\(model.contentRuleCount) rules active"
        case .failed(let message):
            message
        }
    }

    private var contentRuleStatusColor: Color {
        switch model.contentRuleState {
        case .failed:
            .browsemiumWarning
        case .active:
            .browsemiumSuccess
        default:
            .browsemiumTertiary
        }
    }

    private func refreshImportCandidates() {
        let registeredBundleIdentifiers = Set(BrowserImportSource.allCases.compactMap { source -> String? in
            let identifier = source.applicationBundleIdentifier
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) == nil
                ? nil
                : identifier
        })
        installedImportSources = BrowserApplicationDiscovery.installedSources(in: registeredBundleIdentifiers)

        // Do not probe browser profile paths on Settings open. The sandbox only
        // grants access to folders the user selected; reuse those bookmarks,
        // and enumerate profile metadata while each grant is active.
        var candidatesByID: [String: BrowserProfileCandidate] = [:]
        for grant in ImportAccessStore.resolvedFolders(defaults: model.environment.userDefaults) {
            guard let source = BrowserImportSource.allCases.first(where: {
                grant.candidateID.hasPrefix("\($0.rawValue)|")
            }) else { continue }

            let opened = grant.folder.startAccessingSecurityScopedResource()
            guard opened else { continue }
            defer { grant.folder.stopAccessingSecurityScopedResource() }

            let discovered: [BrowserProfileCandidate]
            if BrowserDataImporter.profileLooksValid(grant.folder, source: source) {
                discovered = [grantedProfileCandidate(at: grant.folder, source: source)]
            } else {
                discovered = BrowserProfileLocator.profiles(insideBrowserRoot: grant.folder, source: source)
                    .filter(\.isReadable)
            }

            for candidate in discovered {
                guard let existing = candidatesByID[candidate.id] else {
                    candidatesByID[candidate.id] = candidate
                    continue
                }
                let existingHasMetadata = existing.email != nil
                    || existing.profileName != existing.folder.lastPathComponent
                let candidateHasMetadata = candidate.email != nil
                    || candidate.profileName != candidate.folder.lastPathComponent
                if !existingHasMetadata && candidateHasMetadata {
                    candidatesByID[candidate.id] = candidate
                }
            }
        }
        importCandidates = candidatesByID.values.sorted {
            $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    private func grantedProfileCandidate(at folder: URL, source: BrowserImportSource) -> BrowserProfileCandidate {
        switch source.family {
        case .chromium:
            let folderName = folder.lastPathComponent
            let label: String
            if folderName == "Default" {
                label = source.displayName
            } else {
                label = "\(source.displayName) — \(folderName)"
            }
            return BrowserProfileCandidate(
                source: source,
                label: label,
                folder: folder,
                isReadable: true,
                profileName: folderName
            )
        case .firefox:
            return BrowserProfileCandidate(
                source: source,
                label: "\(source.displayName) — \(folder.lastPathComponent)",
                folder: folder,
                isReadable: true,
                profileName: folder.lastPathComponent
            )
        case .safari:
            return BrowserProfileCandidate(
                source: source,
                label: source.displayName,
                folder: folder,
                isReadable: true,
                profileName: source.displayName
            )
        }
    }

    private func beginImport(source: BrowserImportSource) {
        if let granted = ImportAccessStore.resolveURL(
            candidateID: browserRootBookmarkID(for: source),
            defaults: model.environment.userDefaults
        ), handleGrantedFolder(granted, source: source, candidate: nil) {
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Allow access to \(source.displayName)"
        panel.message = "Choose \(source.displayName)’s browser data folder. Browsemium will find its profiles and show a preview before importing."
        panel.prompt = "Find profiles"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = browserDataRoot(for: source)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        handleGrantedFolder(folder, source: source, candidate: nil)
    }

    private func browserRootBookmarkID(for source: BrowserImportSource) -> String {
        "\(source.rawValue)|installed-browser-root"
    }

    private func browserDataRoot(for source: BrowserImportSource) -> URL? {
        // Firefox keeps its readable profile names in profiles.ini beside
        // Profiles, so grant that containing folder rather than Profiles only.
        source == .firefox ? source.profileRoot?.deletingLastPathComponent() : source.profileRoot
    }

    /// One click when access was granted before; otherwise macOS asks once and
    /// the grant is remembered for next time.
    private func beginImport(_ candidate: BrowserProfileCandidate) {
        if let granted = ImportAccessStore.resolveURL(candidateID: candidate.id, defaults: model.environment.userDefaults) {
            loadPreview(folder: granted, candidate: candidate)
            return
        }
        // A granted browser root covers its child profiles, so a profile
        // discovered inside one imports without another prompt.
        if let root = ImportAccessStore.resolveAncestor(of: candidate.folder, defaults: model.environment.userDefaults) {
            loadPreview(folder: candidate.folder, candidate: candidate, accessRoot: root)
            return
        }
        presentImportPanel(startingAt: candidate.folder, candidate: candidate)
    }

    private func loadPreview(folder: URL, candidate: BrowserProfileCandidate, accessRoot: URL? = nil) {
        let importer = BrowserDataImporter(
            bookmarks: model.environment.bookmarkRepository,
            history: model.environment.historyRepository
        )
        importingID = candidate.id
        isPreparingPreview = true
        statusMessage = "Reading \(candidate.label)…"
        importAccessRoot = accessRoot
        Task {
            defer {
                isPreparingPreview = false
                importingID = nil
            }
            do {
                let preview = try await Task.detached {
                    let scope = accessRoot ?? folder
                    let scoped = scope.startAccessingSecurityScopedResource()
                    defer { if scoped { scope.stopAccessingSecurityScopedResource() } }
                    guard scoped else {
                        throw BrowserDataImporter.ImportError.unreadableData(
                            "macOS could not open that browser folder. Choose it again to grant access."
                        )
                    }
                    // Chromium's shared filenames cannot identify a moved
                    // profile's encryption key; never guess from the button.
                    guard let source = BrowserImportSourceDetector.detect(in: folder) else {
                        throw BrowserDataImporter.ImportError.unreadableData(
                            "Could not identify this browser folder. Choose a profile inside its original browser folder."
                        )
                    }
                    return try importer.preview(at: folder, source: source)
                }.value
                importOptions = BrowserImportOptions()
                importDestination = .newProfile
                importNewProfileName = candidate.profileName
                importFolder = folder
                importPreview = preview
                statusMessage = nil
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    /// After the user grants a folder: if it is a browser root holding several
    /// profiles, list them all; if it is one profile, preview it.
    @discardableResult
    private func handleGrantedFolder(_ granted: URL, source: BrowserImportSource, candidate: BrowserProfileCandidate?) -> Bool {
        let opened = granted.startAccessingSecurityScopedResource()
        guard opened else {
            statusMessage = "macOS did not grant access to that browser folder. Choose it again to continue."
            return false
        }
        defer { if opened { granted.stopAccessingSecurityScopedResource() } }
        ImportAccessStore.save(
            folder: granted,
            for: browserRootBookmarkID(for: source),
            defaults: model.environment.userDefaults
        )

        let looksLikeProfile = BrowserDataImporter.profileLooksValid(granted, source: source)
        if !looksLikeProfile {
            let discovered = BrowserProfileLocator.profiles(insideBrowserRoot: granted, source: source)
                .filter(\.isReadable)
            if discovered.count > 1 {
                var merged = importCandidates.filter { existing in
                    !discovered.contains { $0.id == existing.id }
                }
                merged.append(contentsOf: discovered)
                importCandidates = merged.filter { $0.isReadable } + merged.filter { !$0.isReadable }
                statusMessage = "Found \(discovered.count) profiles in \(source.displayName) — choose one to import"
                return true
            }
            if let onlyProfile = discovered.first {
                loadPreview(folder: onlyProfile.folder, candidate: onlyProfile, accessRoot: granted)
                return true
            }
        }
        let target = candidate ?? BrowserProfileCandidate(
            source: source,
            label: granted.lastPathComponent,
            folder: granted,
            isReadable: true
        )
        loadPreview(folder: granted, candidate: target, accessRoot: granted)
        return true
    }

    private func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Browser Profile Folder"
        panel.message = "Browsemium reads bookmarks and recent history from the selected folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let chrome = importCandidates.first(where: { $0.source == .chrome })?.folder.deletingLastPathComponent() {
            panel.directoryURL = chrome
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let opened = folder.startAccessingSecurityScopedResource()
        defer { if opened { folder.stopAccessingSecurityScopedResource() } }
        guard opened else {
            statusMessage = "macOS did not grant access to that folder. Choose it again to continue."
            return
        }
        guard let source = BrowserImportSourceDetector.detect(in: folder)
            ?? importCandidates.first(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL })?.source else {
            statusMessage = "That folder could not be matched to a browser. Choose a profile from the list first."
            return
        }
        ImportAccessStore.save(folder: folder, for: "\(source.rawValue)|\(folder.path)", defaults: model.environment.userDefaults)
        handleGrantedFolder(folder, source: source, candidate: nil)
    }

    private func beginBatchReview(source: BrowserImportSource) {
        let rememberedRoot = ImportAccessStore.resolveURL(
            candidateID: browserRootBookmarkID(for: source),
            defaults: model.environment.userDefaults
        ) ?? importCandidates
            .filter { $0.source == source && $0.isReadable }
            .compactMap { ImportAccessStore.resolveAncestor(of: $0.folder, defaults: model.environment.userDefaults) }
            .first

        if let rememberedRoot {
            let opened = rememberedRoot.startAccessingSecurityScopedResource()
            let canEnumerateAllProfiles: Bool
            if opened {
                let isProfileFolder = BrowserDataImporter.profileLooksValid(rememberedRoot, source: source)
                rememberedRoot.stopAccessingSecurityScopedResource()
                // A grant for one profile cannot enumerate its siblings. Ask
                // for the source root instead; Safari has a single profile.
                canEnumerateAllProfiles = !isProfileFolder || source == .safari
            } else {
                canEnumerateAllProfiles = false
            }
            if canEnumerateAllProfiles {
                prepareBatchReview(source: source, root: rememberedRoot)
                return
            }
        }

        let panel = NSOpenPanel()
        panel.title = "Choose the \(source.displayName) browser folder"
        panel.message = source == .firefox
            ? "Choose the Firefox folder containing profiles.ini and Profiles. Each profile gets a separate Browsemium profile."
            : "Grant the folder that contains its profiles. Each one gets a separate Browsemium profile."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = browserDataRoot(for: source)
        guard panel.runModal() == .OK, let root = panel.url else { return }
        ImportAccessStore.save(folder: root,
                               for: browserRootBookmarkID(for: source),
                               defaults: model.environment.userDefaults)
        prepareBatchReview(source: source, root: root)
    }

    private func prepareBatchReview(source: BrowserImportSource, root: URL) {
        let scoped = root.startAccessingSecurityScopedResource()
        guard scoped else {
            statusMessage = "macOS did not grant access to that browser folder. Choose it again to continue."
            return
        }
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let candidates = BrowserProfileLocator.profiles(insideBrowserRoot: root, source: source)
            .filter(\.isReadable)
        guard !candidates.isEmpty else {
            statusMessage = "No readable \(source.displayName) profiles were found in that folder."
            return
        }
        ImportAccessStore.save(folder: root, for: "\(source.rawValue)|\(root.path)", defaults: model.environment.userDefaults)
        let importer = BrowserDataImporter(bookmarks: model.environment.bookmarkRepository,
                                           history: model.environment.historyRepository)
        isPreparingPreview = true
        Task {
            defer { isPreparingPreview = false }
            do {
                let entries = try await Task.detached {
                    let opened = root.startAccessingSecurityScopedResource()
                    defer { if opened { root.stopAccessingSecurityScopedResource() } }
                    guard opened else {
                        throw BrowserDataImporter.ImportError.unreadableData(
                            "macOS could not open that browser folder. Choose it again to grant access."
                        )
                    }
                    return try candidates.map { candidate in
                        BatchImportEntry(candidate: candidate,
                                         preview: try importer.preview(at: candidate.folder, source: source))
                    }
                }.value
                batchEntries = entries
                batchAccessRoot = root
                batchOptions = BrowserImportOptions()
                batchReport = []
                batchDetailedReports = []
                batchCompletedCount = 0
                batchCurrentProfile = nil
                isShowingBatch = true
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func commitBatchImport() {
        guard let root = batchAccessRoot else { return }
        let entries = batchEntries
        let options = batchOptions
        isBatchImporting = true
        Task {
            var report: [String] = []
            for entry in entries {
                batchCurrentProfile = entry.candidate.label
                defer { batchCompletedCount += 1 }
                let keyProvider: any BrowserCredentialKeyProviding
                do {
                    keyProvider = try importKeyProvider(for: entry.preview, options: options)
                } catch {
                    report.append("\(entry.candidate.label): \(error.localizedDescription)")
                    continue
                }
                guard let destinationProfile = model.createProfile(named: entry.candidate.profileName) else {
                    report.append("\(entry.candidate.label): profile could not be created.")
                    continue
                }
                do {
                    let database = try model.environment.profileStore.database(for: destinationProfile)
                    let importer = BrowserDataImporter(
                        bookmarks: BookmarkRepository(database: database),
                        history: HistoryRepository(database: database)
                    )
                    let result = try await Task.detached {
                        let opened = root.startAccessingSecurityScopedResource()
                        defer { if opened { root.stopAccessingSecurityScopedResource() } }
                        guard opened else {
                            throw BrowserDataImporter.ImportError.unreadableData(
                                "macOS access to this browser folder expired. Choose the folder again to continue."
                            )
                        }
                        return try importer.apply(entry.preview, options: options,
                                                  keyProvider: keyProvider, profile: entry.candidate.folder)
                    }.value
                    let passwordOutcomes = storeCredentials(result.credentials, profile: destinationProfile)
                    let cookieOutcomes = await storeCookies(result.cookies, profile: destinationProfile)
                    let searchSaved = applyImportedSearchEngine(result.searchEngine, profile: destinationProfile)
                    let finalReport = completedImportReport(result, passwords: passwordOutcomes, cookies: cookieOutcomes, searchSaved: searchSaved)
                    batchDetailedReports.append(finalReport)
                    if destinationProfile.id == model.activeProfile.id { model.refreshBookmarks() }
                    let summary = importSummary(entry.preview, options: options, result: result,
                        storedCredentials: passwordOutcomes.filter { $0 == .accepted }.count,
                        storedCookies: cookieOutcomes.filter { $0 == .accepted }.count,
                        report: finalReport, searchSaved: searchSaved)
                    report.append("\(entry.candidate.label): \(summary).")
                } catch {
                    report.append("\(entry.candidate.label): \(error.localizedDescription)")
                }
            }
            batchReport = report
            batchCurrentProfile = nil
            isBatchImporting = false
        }
    }

    private func presentImportPanel(startingAt folder: URL, candidate: BrowserProfileCandidate) {
        let panel = NSOpenPanel()
        panel.title = "Allow Access to \(candidate.label)"
        panel.message = "macOS needs your permission once. Pick the profile folder — or the folder that contains it, such as Chrome or Profiles."
        panel.prompt = "Allow"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // Navigate as close to the profile as the sandbox allows; the importer
        // descends into the profile if a parent folder is chosen instead.
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let granted = panel.url else { return }
        ImportAccessStore.save(folder: granted, for: candidate.id, defaults: model.environment.userDefaults)
        handleGrantedFolder(granted, source: candidate.source, candidate: candidate)
    }

    private func commitImport() {
        guard let preview = importPreview, let folder = importFolder else { return }
        let options = importOptions
        let keyProvider: any BrowserCredentialKeyProviding
        do {
            keyProvider = try importKeyProvider(for: preview, options: options)
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        // Create and switch to the new profile first, so the import writes to
        // that profile's database rather than the current one.
        let destinationProfile: BrowserProfile
        if importDestination == .newProfile {
            let trimmed = importNewProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "\(preview.source.displayName) import" : trimmed
            guard let createdProfile = model.createProfile(named: name) else {
                statusMessage = "Could not create the new profile."
                importPreview = nil
                importFolder = nil
                return
            }
            destinationProfile = createdProfile
        } else {
            destinationProfile = model.activeProfile
        }
        let importer: BrowserDataImporter
        do {
            let database = try model.environment.profileStore.database(for: destinationProfile)
            importer = BrowserDataImporter(
                bookmarks: BookmarkRepository(database: database),
                history: HistoryRepository(database: database)
            )
        } catch {
            statusMessage = "Could not open the destination profile: \(error.localizedDescription)"
            importPreview = nil
            importFolder = nil
            return
        }
        let accessRoot = importAccessRoot
        isImporting = true
        Task {
            do {
                let result = try await Task.detached {
                    let scope = accessRoot ?? folder
                    let scoped = scope.startAccessingSecurityScopedResource()
                    defer { if scoped { scope.stopAccessingSecurityScopedResource() } }
                    guard scoped else {
                        throw BrowserDataImporter.ImportError.unreadableData(
                            "macOS access to this browser folder expired. Choose the folder again to continue."
                        )
                    }
                    return try importer.apply(
                        preview,
                        options: options,
                        keyProvider: keyProvider,
                        profile: folder
                    )
                }.value
                let passwordOutcomes = storeCredentials(result.credentials, profile: destinationProfile)
                let cookieOutcomes = await storeCookies(result.cookies, profile: destinationProfile)
                let searchSaved = applyImportedSearchEngine(result.searchEngine, profile: destinationProfile)
                let finalReport = completedImportReport(result, passwords: passwordOutcomes, cookies: cookieOutcomes, searchSaved: searchSaved)
                importLastReport = finalReport
                if destinationProfile.id == model.activeProfile.id { model.refreshBookmarks() }
                importLastSummary = importSummary(preview, options: options, result: result,
                    storedCredentials: passwordOutcomes.filter { $0 == .accepted }.count,
                    storedCookies: cookieOutcomes.filter { $0 == .accepted }.count,
                    report: finalReport, searchSaved: searchSaved)
                statusMessage = importLastSummary
                if !result.extensionIDs.isEmpty {
                    pendingExtensionIDs = result.extensionIDs
                    isConfirmingExtensionReinstall = true
                }
            } catch {
                statusMessage = error.localizedDescription
            }
            isImporting = false
            importPreview = nil
            importFolder = nil
        }
    }

    /// Saved logins go straight into the keychain, never to disk in the clear.
    private func storeCredentials(_ credentials: [ChromeLogin], profile: BrowserProfile) -> [BrowserImportReport.Outcome] {
        credentials.map { credential in
            model.saveCredential(
                host: credential.url.host ?? credential.url.absoluteString,
                username: credential.username,
                password: credential.password,
                profile: profile
            ) ? .accepted : .failed
        }
    }

    private func importKeyProvider(for preview: BrowserImportPreview, options: BrowserImportOptions) throws -> any BrowserCredentialKeyProviding {
        let provider = ChromeSafeStorageKeyProvider(keychain: model.environment.keychain)
        let needsKey = preview.source.family == .chromium
            && ((options.includesPasswords && preview.credentialCount > 0)
                || (options.includesCookies && preview.cookieCount > 0))
        guard needsKey else { return provider }
        guard let key = try provider.safeStorageKey(for: preview.source) else {
            throw BrowserDataImporter.ImportError.credentialsLocked(preview.source.displayName)
        }
        return UnlockedImportKeyProvider(key: key)
    }

    private func storeCookies(_ cookies: [BrowserImportCookie], profile: BrowserProfile) async -> [BrowserImportReport.Outcome] {
        guard !cookies.isEmpty else { return [] }
        let store = WKWebsiteDataStore(forIdentifier: profile.dataStoreUUID).httpCookieStore
        var expected: [HTTPCookie?] = []
        for imported in cookies {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: imported.domain,
                .path: imported.path,
                .name: imported.name,
                .value: imported.value,
                .secure: imported.isSecure ? "TRUE" : "FALSE",
                HTTPCookiePropertyKey("HttpOnly"): imported.isHTTPOnly ? "TRUE" : "FALSE"
            ]
            if let expires = imported.expires { properties[.expires] = expires }
            let cookie = HTTPCookie(properties: properties)
            expected.append(cookie)
            guard let cookie else { continue }
            await store.setCookie(cookie)
        }
        let saved = await store.allCookies()
        // Compare native normalized properties, with one lookup per item.
        // Values remain transient and never enter the structured report.
        let installed = Set(saved.map { [$0.domain, $0.path, $0.name, $0.value] })
        return expected.map { cookie in
            guard let cookie else { return .failed }
            return installed.contains([cookie.domain, cookie.path, cookie.name, cookie.value]) ? .accepted : .failed
        }
    }

    private func applyImportedSearchEngine(_ engine: BrowserImportPreview.SearchEngine?, profile: BrowserProfile) -> Bool {
        guard let engine else { return false }
        do {
            let database = try model.environment.profileStore.database(for: profile)
            let repository = SettingsRepository(database: database)
            var settings = try repository.load()
            settings.searchEngineTemplate = engine.template
            try repository.save(settings)
            if profile.id == model.activeProfile.id {
                model.updateSettings { $0.searchEngineTemplate = engine.template }
            }
            return true
        } catch {
            statusMessage = "The search engine could not be saved. Retry the import."
            return false
        }
    }

    private func completedImportReport(_ result: BrowserImportResult,
                                      passwords: [BrowserImportReport.Outcome],
                                      cookies: [BrowserImportReport.Outcome], searchSaved: Bool) -> BrowserImportReport {
        var report = result.report
        report.completeTransfer(.password, outcomes: passwords)
        report.completeTransfer(.cookie, outcomes: cookies)
        if result.searchEngine != nil {
            report.completeTransfer(.searchEngine, outcomes: [searchSaved ? .accepted : .failed])
        }
        return report
    }

    private func importSummary(_ preview: BrowserImportPreview, options: BrowserImportOptions,
                               result: BrowserImportResult, storedCredentials: Int, storedCookies: Int,
                               report: BrowserImportReport, searchSaved: Bool) -> String {
        var moved: [String] = []
        var notes: [String] = []
        if result.bookmarks > 0 { moved.append("\(result.bookmarks) bookmarks") }
        if result.historyVisits > 0 { moved.append("\(result.historyVisits) history entries") }
        if storedCredentials > 0 { moved.append("\(storedCredentials) passwords") }
        if storedCookies > 0 { moved.append("\(storedCookies) cookies") }
        if searchSaved { moved.append("default search engine") }
        if options.includesPasswords && storedCredentials < preview.credentialCount {
            notes.append("\(preview.credentialCount - storedCredentials) passwords skipped or unreadable")
        }
        if options.includesCookies && storedCookies < preview.cookieCount {
            notes.append("\(preview.cookieCount - storedCookies) cookies skipped, expired, or unreadable")
        }
        let failures = report.items.filter { $0.outcome == .failed }
        if !failures.isEmpty { notes.append("\(failures.count) read or save failures; see the item report") }
        let headline = moved.isEmpty ? "Nothing imported" : "Imported " + moved.joined(separator: ", ")
        return notes.isEmpty ? headline : headline + "; " + notes.joined(separator: ", ")
    }

    private func choosePasswordCSV() {
        let panel = NSOpenPanel()
        panel.title = "Choose a password CSV"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard scoped else {
            statusMessage = "macOS did not grant access to that CSV file. Choose it again to continue."
            return
        }
        do {
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 16 * 1024 * 1024 { throw BrowserPasswordCSV.CSVError.tooLarge }
            csvImport = try BrowserPasswordCSV(data: Data(contentsOf: url))
            isShowingCSVImport = true
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func importPasswordsFromCSV(_ credentials: [ChromeLogin]) {
        let count = storeCredentials(credentials, profile: model.activeProfile).filter { $0 == .accepted }.count
        csvImport = nil
        isShowingCSVImport = false
        statusMessage = "Imported \(count) passwords to Keychain; \(credentials.count - count) skipped."
    }

    private func exportPasswordsToCSV() {
        let panel = NSSavePanel()
        panel.title = "Export passwords as CSV"
        panel.nameFieldStringValue = "Browsemium-passwords.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url, url.isFileURL else { return }
        do {
            let credentials = try model.savedCredentials.map { saved -> ChromeLogin in
                guard let password = try model.environment.keychain.secret(account: saved.keychainAccount),
                      let url = URL(string: "https://\(saved.host)") else {
                    throw BrowserPasswordCSV.CSVError.malformed
                }
                return ChromeLogin(url: url, username: saved.username, password: password)
            }
            let csv = BrowserPasswordCSV.export(credentials)
            guard writePrivateCSV(csv, to: url) else {
                statusMessage = "The CSV could not be saved."
                return
            }
            statusMessage = "Exported \(credentials.count) passwords to the selected CSV."
        } catch {
            statusMessage = "Export stopped. No CSV was written because a password could not be read."
        }
    }

    private func writePrivateCSV(_ data: Data, to url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard scoped else { return false }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { return false }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        return wroteAll && Darwin.fsync(descriptor) == 0
    }

    private func presentPasswordEditor() {
        credentialHost = model.activeTab?.lastCommittedURL?.host ?? ""
        credentialUsername = ""
        credentialPassword = ""
        isAddingPassword = true
    }

    private func savePassword() {
        model.saveCredential(
            host: credentialHost,
            username: credentialUsername,
            password: credentialPassword
        )
        credentialPassword = ""
        isAddingPassword = false
    }

    private func saveKey() {
        guard let provider = keyPromptProvider else { return }
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try? model.environment.keychain.setSecret(trimmed, account: model.environment.providerCredentialAccount(provider))
        }
        keyInput = ""
        keyPromptProvider = nil
        refreshCredentials()
        statusMessage = "API key saved"
    }

    private func refreshCredentials() {
        var states: [AIProviderID: Bool] = [:]
        for provider in AIProviderID.allCases {
            if provider.isLocal {
                states[provider] = true
                continue
            }
            states[provider] = model.environment.hasProviderCredential(provider)
        }
        credentialStates = states
    }
}

// MARK: - Building blocks

@MainActor
private struct PasswordEditorSheet: View {
    @Binding var host: String
    @Binding var username: String
    @Binding var password: String
    let onCancel: () -> Void
    let onSave: () -> Void

    private var canSave: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !password.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save password")
                .font(.system(size: 15, weight: .semibold))

            VStack(spacing: 10) {
                LabeledContent("Website") {
                    TextField("example.com", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                LabeledContent("Username") {
                    TextField("name@example.com", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                LabeledContent("Password") {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
            }

            Text("The password is stored in macOS Keychain. Browsemium stores only the website and username in its local database.")
                .font(.system(size: 11))
                .foregroundStyle(Color.browsemiumTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                BrowsemiumTextButton("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                BrowsemiumPrimaryButton("Save", isDisabled: !canSave, action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Color.browsemiumSurface)
        .foregroundStyle(Color.browsemiumPrimary)
    }
}

@MainActor
private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.browsemiumTertiary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.browsemiumSecondary)
            }
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.browsemiumSurface)
            .clipShape(RoundedRectangle(cornerRadius: BrowserMetrics.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BrowserMetrics.panelRadius, style: .continuous)
                    .stroke(Color.browsemiumBorder, lineWidth: 1)
            }
        }
    }
}

@MainActor
private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        // At narrow widths a single line clips the label off-screen, so the
        // control moves onto its own line instead.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                labelText
                Spacer(minLength: 12)
                content
            }

            VStack(alignment: .leading, spacing: 8) {
                labelText
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 40, alignment: .center)
    }

    private var labelText: some View {
        Text(label)
            .font(.system(size: 12.5))
            .foregroundStyle(Color.browsemiumPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }
}

@MainActor
private struct SettingsToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(label) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.browsemiumAccentFill)
                .accessibilityLabel(label)
        }
    }
}

@MainActor
private struct SettingsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.browsemiumBorder)
                .frame(height: 1)
                .padding(.horizontal, 14)

            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color.browsemiumTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
