import AppKit
import BrowsemiumData
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct UserFilterListImportSheet: View {
    @State var name: String
    @State var source: UserFilterList.Source
    let destinationName: String
    let state: UserFilterListController.State
    var isSubmitting = false
    let onCancel: () -> Void
    let onImport: (String, UserFilterList.Source, URL) -> Void
    @State private var address = ""
    @State private var file: URL?
    @FocusState private var nameFocused: Bool

    private var busy: Bool { isSubmitting || state == .fetching || state == .parsing || state == .compiling }
    private var input: URL? {
        if source == .localFile { return file }
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    private var canImport: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !busy && !trimmed.isEmpty && trimmed.count <= 80 && input != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import filter list").font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text("Save into \(destinationName)").font(.system(size: 12)).foregroundStyle(Color.browsemiumSecondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("List name").font(.system(size: 12, weight: .medium))
                TextField("Name (up to 80 characters)", text: $name)
                    .browsemiumField().padding(.horizontal, 8).frame(height: 30)
                    .focused($nameFocused).accessibilityLabel("Filter list name")
            }
            .disabled(busy)
            HStack(spacing: 12) {
                Text("Source").font(.system(size: 12, weight: .medium))
                BrowsemiumTabPicker(values: [UserFilterList.Source.localFile, .https], selection: $source) {
                    $0 == .localFile ? "File" : "HTTPS address"
                }
                .accessibilityLabel("Filter list source")
            }
            .disabled(busy)
            if source == .localFile {
                HStack(spacing: 12) {
                    Text(file?.lastPathComponent ?? "No file selected")
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    BrowsemiumTextButton("Choose file…", action: chooseFile)
                        .disabled(busy)
                }
            } else {
                TextField("https://…", text: $address)
                    .browsemiumField().padding(.horizontal, 8).frame(height: 30)
                    .accessibilityLabel("HTTPS filter list address")
                    .disabled(busy)
                Text("Import contacts this source server without browser cookies or saved credentials. The address is not stored and will not be refreshed automatically.")
                    .font(.system(size: 11)).foregroundStyle(Color.browsemiumSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("UTF-8 text, up to 4 MiB. Only the supported hostname subset is converted. Unsupported syntax is skipped or rejected; failed imports keep the working rules.")
                .font(.system(size: 11)).foregroundStyle(Color.browsemiumSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .failed(let message, _) = state {
                Text(message).font(.system(size: 11)).foregroundStyle(Color.browsemiumDestructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading, converting, or compiling…").font(.system(size: 11)) }
            }
            HStack {
                BrowsemiumTextButton(busy ? "Cancel import" : "Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                BrowsemiumPrimaryButton("Import list", isDisabled: !canImport) {
                    if let input { onImport(name, source, input) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 440)
        .background(Color.browsemiumSurface).foregroundStyle(Color.browsemiumPrimary)
        .onAppear { nameFocused = true }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a UTF-8 filter list"
        panel.allowedContentTypes = [.plainText, .text]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { file = panel.url }
    }
}
