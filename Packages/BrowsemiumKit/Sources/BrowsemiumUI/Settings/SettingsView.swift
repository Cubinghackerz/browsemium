import AppKit
import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumData
import SwiftUI

@MainActor
struct SettingsView: View {
    @Bindable var model: BrowserWindowModel
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
    @State private var importingID: String?
    @State private var isImporting = false
    @State private var importPreview: BrowserImportPreview?
    @State private var importOptions = BrowserImportOptions()
    @State private var importFolder: URL?
    @State private var importLastResult: BrowserImportResult?
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
                    generalSection
                    profilesSection
                    browsingSection
                    performanceSection
                    importSection
                    privacySection
                    passwordsSection
                    assistantSection
                    aboutSection
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
        .confirmationDialog(
            "Clear browsing data?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear history, downloads, permissions, and closed tabs", role: .destructive) {
                model.clearBrowsingData()
                statusMessage = "Browsing data cleared."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bookmarks, settings, and saved API keys are kept.")
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
                    model.deleteProfile(target)
                }
                profileDeleteTarget = nil
                refreshProfiles()
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

            SettingsRow("Default browser") {
                HStack(spacing: 8) {
                    if isDefaultBrowser {
                        Text("Browsemium opens links from other apps")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.browsemiumTertiary)
                    } else {
                        BrowsemiumTextButton("Make Default") {
                            if DefaultBrowser.requestDefault() {
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

            Text("Each profile keeps its own tabs, bookmarks, history, passwords, logins, and site data. Nothing is shared between them.")
                .font(.system(size: 11))
                .foregroundStyle(Color.browsemiumTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    Picker("Search engine", selection: searchEngineBinding) {
                        ForEach(SearchEnginePreset.all) { preset in
                            Text(preset.name).tag(preset.template)
                        }
                        Text("Custom").tag(Self.customEngineTag)
                    }
                    .labelsHidden()
                    .frame(width: 150)
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
                Picker("Keep history for", selection: retentionBinding) {
                    ForEach(retentionOptions, id: \.label) { option in
                        Text(option.label).tag(option.days ?? -1)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                .accessibilityLabel("History retention")
            }

            SettingsToggleRow(
                "Clear history when Browsemium quits",
                isOn: settingBinding(\.clearOnQuit)
            )
            SettingsToggleRow(
                "Send search suggestions while typing",
                isOn: settingBinding(\.remoteSearchSuggestions)
            )
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

            SettingsNote("Browsemium unloads background tabs instead of keeping every page in memory. That is the real reason it can use less memory than Chrome — pages reload when you return to them. Web pages run in separate WebKit processes, so the figure above is Browsemium's own footprint.")
        }
    }

    private var importSection: some View {
        SettingsCard("Import Browser Data", systemImage: "square.and.arrow.down") {
            if let chrome = importCandidates.first(where: { $0.source == .chrome }) {
                SettingsRow("Move from Chrome") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Review profiles, bookmarks, history, search settings, and saved passwords before importing.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.browsemiumSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        BrowsemiumPrimaryButton("Review Chrome import", isDisabled: isImporting) {
                            beginImport(chrome)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if importCandidates.isEmpty {
                SettingsRow("Looking for browsers…") {
                    ProgressView().controlSize(.small)
                }
            } else {
                ForEach(importCandidates) { candidate in
                    SettingsRow(candidate.label) {
                        HStack(spacing: 10) {
                            if candidate.isReadable {
                                Text("Ready")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.browsemiumSuccess)
                            } else {
                                Text("Asks permission once")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.browsemiumTertiary)
                            }
                            BrowsemiumTextButton(importingID == candidate.id ? "Importing…" : "Import") {
                                beginImport(candidate)
                            }
                            .disabled(isImporting)
                        }
                    }
                }
            }
            SettingsRow("Another folder") {
                BrowsemiumTextButton("Choose…") { chooseImportFolder() }
                    .disabled(isImporting)
            }

            if let result = importLastResult {
                SettingsRow("Last import") {
                    Text("\(result.bookmarks) bookmarks · \(result.historyVisits) history entries")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.browsemiumSuccess)
                }
            }

            if isPreparingPreview {
                SettingsRow("Reading profile") {
                    ProgressView().controlSize(.small)
                }
            }
            SettingsNote("Browsemium detects installed browsers and previews up to 50,000 recent Chrome history entries plus all valid bookmarks. macOS asks you to allow access once, then it is remembered. Cookies, extensions, and site storage stay behind. Nothing is uploaded or removed from the source browser.")
        }
    }

    private var privacySection: some View {
        SettingsCard("Privacy & Blocking", systemImage: "hand.raised") {
            SettingsToggleRow("Block ads and trackers", isOn: settingBinding(\.contentBlockingEnabled))

            SettingsRow("Content rules") {
                Text(contentRuleStatusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(contentRuleStatusColor)
            }

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
                    label: { $0.rawValue.capitalized }
                )
                .accessibilityLabel("Content protection level")
            }

            SettingsRow("Browsing data") {
                HStack(spacing: 14) {
                    BrowsemiumTextButton("Clear browsing data…") { isConfirmingClear = true }
                    BrowsemiumTextButton("Remove site permissions", role: .destructive) {
                        try? model.environment.permissionRepository.removeAll()
                        statusMessage = "Site permissions removed."
                    }
                }
            }

            SettingsNote("Browsemium relies on WebKit tracking prevention and never reports a blocked-item count it cannot verify. Browsing data stays on this Mac.")
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
        }
    }

    private var assistantSection: some View {
        SettingsCard("Assistant", systemImage: "sparkles") {
            SettingsToggleRow("Show the assistant", isOn: settingBinding(\.isAIDockEnabled))
            SettingsToggleRow("Save conversations on this Mac", isOn: settingBinding(\.persistAIConversations))
            SettingsToggleRow("Include automatic page context in web AI", isOn: settingBinding(\.includePageMetadataInWebAI))

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
            SettingsNote("No account, no telemetry. Browsing data leaves this Mac only when you send it to a site or an AI provider you chose.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Settings")
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
        let candidates = BrowserProfileLocator.candidates()
        importCandidates = candidates.filter { $0.isReadable } + candidates.filter { !$0.isReadable }
    }

    /// One click when access was granted before; otherwise macOS asks once and
    /// the grant is remembered for next time.
    private func beginImport(_ candidate: BrowserProfileCandidate) {
        if let granted = ImportAccessStore.resolveURL(candidateID: candidate.id) {
            loadPreview(folder: granted, candidate: candidate)
            return
        }
        // A granted browser root covers its child profiles, so a profile
        // discovered inside one imports without another prompt.
        if let root = ImportAccessStore.resolveAncestor(of: candidate.folder) {
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
        // Trust the folder's contents over the button that was pressed, so a
        // manually chosen profile is never parsed with the wrong reader.
        let source = BrowserImportSourceDetector.detect(in: folder) ?? candidate.source
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
                    return try importer.preview(at: folder, source: source)
                }.value
                importOptions = BrowserImportOptions()
                importDestination = candidate.source == .chrome && candidate.label.lowercased() != "default"
                    ? .newProfile
                    : .currentProfile
                importNewProfileName = candidate.source == .chrome && candidate.label.lowercased() != "default"
                    ? candidate.label
                    : ""
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
    private func handleGrantedFolder(_ granted: URL, source: BrowserImportSource, candidate: BrowserProfileCandidate?) {
        let looksLikeProfile = BrowserDataImporter.profileLooksValid(granted, source: source)
        if !looksLikeProfile {
            let discovered = BrowserProfileLocator.profiles(insideBrowserRoot: granted, source: source)
            if discovered.count > 1 || (discovered.count == 1 && discovered[0].folder.standardizedFileURL != granted.standardizedFileURL) {
                var merged = importCandidates.filter { existing in
                    !discovered.contains { $0.id == existing.id }
                }
                merged.append(contentsOf: discovered)
                importCandidates = merged.filter { $0.isReadable } + merged.filter { !$0.isReadable }
                statusMessage = "Found \(discovered.count) profiles in \(source.displayName) — choose one to import"
                return
            }
        }
        let target = candidate ?? BrowserProfileCandidate(
            source: source,
            label: granted.lastPathComponent,
            folder: granted,
            isReadable: true
        )
        loadPreview(folder: granted, candidate: target, accessRoot: candidate == nil ? nil : granted)
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
        let source = BrowserImportSourceDetector.detect(in: folder)
            ?? importCandidates.first { $0.folder.standardizedFileURL == folder.standardizedFileURL }?.source
            ?? .chrome
        ImportAccessStore.save(folder: folder, for: "\(source.rawValue)|\(folder.path)")
        handleGrantedFolder(folder, source: source, candidate: nil)
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
        ImportAccessStore.save(folder: granted, for: candidate.id)
        handleGrantedFolder(granted, source: candidate.source, candidate: candidate)
    }

    private func commitImport() {
        guard let preview = importPreview, let folder = importFolder else { return }
        // Create and switch to the new profile first, so the import writes to
        // that profile's database rather than the current one.
        if importDestination == .newProfile {
            let trimmed = importNewProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "\(preview.source.displayName) import" : trimmed
            guard model.createProfile(named: name) != nil else {
                statusMessage = "Could not create the new profile."
                importPreview = nil
                importFolder = nil
                return
            }
        }
        let importer = BrowserDataImporter(
            bookmarks: model.environment.bookmarkRepository,
            history: model.environment.historyRepository
        )
        let options = importOptions
        let accessRoot = importAccessRoot
        let keyProvider = ChromeSafeStorageKeyProvider(keychain: model.environment.keychain)
        isImporting = true
        Task {
            do {
                let result = try await Task.detached {
                    let scope = accessRoot ?? folder
                    let scoped = scope.startAccessingSecurityScopedResource()
                    defer { if scoped { scope.stopAccessingSecurityScopedResource() } }
                    return try importer.apply(
                        preview,
                        options: options,
                        keyProvider: keyProvider,
                        profile: folder
                    )
                }.value
                storeCredentials(result.credentials)
                applyImportedSearchEngine(result.searchEngine)
                model.refreshBookmarks()
                importLastResult = result
                statusMessage = importSummary(result)
            } catch {
                statusMessage = error.localizedDescription
            }
            isImporting = false
            importPreview = nil
            importFolder = nil
        }
    }

    /// Saved logins go straight into the keychain, never to disk in the clear.
    private func storeCredentials(_ credentials: [ChromeLogin]) {
        for credential in credentials {
            model.saveCredential(
                host: credential.url.host ?? credential.url.absoluteString,
                username: credential.username,
                password: credential.password
            )
        }
    }

    private func applyImportedSearchEngine(_ engine: BrowserImportPreview.SearchEngine?) {
        guard let engine else { return }
        model.updateSettings { $0.searchEngineTemplate = engine.template }
    }

    private func importSummary(_ result: BrowserImportResult) -> String {
        var parts: [String] = []
        if result.bookmarks > 0 { parts.append("\(result.bookmarks) bookmarks") }
        if result.historyVisits > 0 { parts.append("\(result.historyVisits) history entries") }
        if !result.credentials.isEmpty { parts.append("\(result.credentials.count) passwords") }
        if result.searchEngine != nil { parts.append("default search engine") }
        return parts.isEmpty ? "Nothing new to import" : "Imported " + parts.joined(separator: ", ")
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
            states[provider] = (try? model.environment.keychain.hasSecret(account: model.environment.providerCredentialAccount(provider))) ?? false
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
