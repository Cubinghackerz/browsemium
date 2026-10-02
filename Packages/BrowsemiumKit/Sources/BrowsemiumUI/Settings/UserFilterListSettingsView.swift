import BrowsemiumData
import BrowsemiumCore
import SwiftUI

/// A local extension of the existing Settings cards: native controls, restrained
/// theme tokens, explicit edits, and compile state rather than request counters.
@MainActor struct UserFilterListSettingsView: View {
    @Bindable var model: BrowserWindowModel
    let controller: UserFilterListController
    let settings: BrowserSettings
    @State private var editing: EditRequest?
    @State private var removing: UserFilterList?
    @State private var operation = UserFilterListSettingsOperation()

    struct EditRequest: Identifiable {
        let id = UUID()
        let list: UserFilterList?
        let profileID: UUID
        let profileName: String
    }

    var body: some View {
        SettingsCard("User filter lists", systemImage: "line.3.horizontal.decrease.circle") {
            if controller.lists.isEmpty {
                SettingsRow("No user lists") {
                    BrowsemiumTextButton("Import list…") { edit(nil) }
                        .disabled(cannotEdit)
                }
            } else {
                ForEach(controller.lists) { list in listRow(list) }
                SettingsRow("Add a list") {
                    BrowsemiumTextButton("Import list…") { edit(nil) }
                        .disabled(cannotEdit)
                }
            }
            SettingsRow("Compile state") {
                VStack(alignment: .leading, spacing: 4) {
                    if controller.isBusy { ProgressView().controlSize(.small) }
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.browsemiumSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .failed = controller.state {
                        BrowsemiumTextButton("Reload saved lists") { operation.run { await controller.restore() } }
                            .disabled(operation.isRunning)
                    }
                }
            }
            SettingsNote(model.session.isPrivate
                ? "Private windows use this profile's saved rules but cannot edit lists."
                : "Import a UTF-8 ABP/AdGuard file or HTTPS source. This is a limited hostname subset; unsupported rules are skipped, not expanded. Sources are not saved or updated automatically. Changes apply on the next navigation.")
            if !settings.contentBlockingEnabled || !settings.protectionLevel.blocksContentRules {
                SettingsNote("Content blocking is off. Compiled lists are saved, but not applied until blocking is enabled.")
            }
        }
        .sheet(item: $editing, onDismiss: { operation.cancel() }) { request in
            UserFilterListImportSheet(name: request.list?.name ?? "", source: request.list?.source ?? .localFile,
                                      destinationName: request.profileName, state: controller.state,
                                      isSubmitting: operation.isRunning,
                                      onCancel: { operation.cancel(); editing = nil }) { name, source, url in
                guard controller.profileID == request.profileID else { editing = nil; return }
                operation.run {
                    if source == .localFile { await controller.importFile(url, name: name, replacing: request.list?.id) }
                    else { await controller.importURL(url, name: name, replacing: request.list?.id) }
                    guard !Task.isCancelled, editing?.id == request.id,
                          controller.profileID == request.profileID else { return }
                    if controller.state == .active { editing = nil }
                }
            }
        }
        .alert("Remove filter list?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { list in
            Button("Remove", role: .destructive) { controller.remove(id: list.id); removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { list in
            Text("Remove \(list.name) from this profile? The original source file is not changed.")
        }
        .onChange(of: controller.profileID) { _, _ in operation.cancel(); editing = nil; removing = nil }
        .onDisappear { operation.cancel() }
    }

    private var cannotEdit: Bool { model.session.isPrivate || controller.isBusy || operation.isRunning }

    private var statusText: String {
        switch controller.state {
        case .idle: "No import in progress"
        case .fetching: "Reading the selected source…"
        case .parsing: "Converting supported rules…"
        case .compiling: "Compiling with WebKit…"
        case .active: controller.lists.isEmpty ? "No user lists saved" :
            (controller.lists.contains(where: \.isEnabled) ? "Saved enabled lists have compiled" : "All user lists are disabled")
        case .failed(let message, let lastGood): message + (lastGood ? " The last working rules remain in use when blocking is enabled." : "")
        }
    }

    private func edit(_ list: UserFilterList?) {
        editing = EditRequest(list: list, profileID: controller.profileID, profileName: model.activeProfile.name)
    }

    private func listRow(_ list: UserFilterList) -> some View {
        SettingsRow(list.name) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(list.acceptedCount) supported \(list.acceptedCount == 1 ? "rule" : "rules") · \(list.skippedCount) skipped · \(list.isEnabled ? "Enabled" : "Disabled")")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.browsemiumSecondary)
                HStack(spacing: 12) {
                    Toggle("Enable \(list.name)", isOn: Binding(get: { list.isEnabled }, set: { enabled in
                        operation.run { await controller.setEnabled(enabled, id: list.id) }
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .tint(Color.browsemiumAccentFill)
                    .accessibilityLabel("Enable \(list.name)")
                    BrowsemiumTextButton("Re-import…") { edit(list) }
                        .accessibilityLabel("Re-import \(list.name)")
                    BrowsemiumTextButton("Remove", role: .destructive) { removing = list }
                        .accessibilityLabel("Remove \(list.name)")
                }
                .disabled(cannotEdit)
            }
        }
    }
}
