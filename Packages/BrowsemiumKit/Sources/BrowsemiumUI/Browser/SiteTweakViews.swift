import BrowsemiumCore
import SwiftUI

/// The "Page tweaks" block inside the site shield panel.
@MainActor
struct SiteTweaksSection: View {
    @Bindable var model: BrowserWindowModel

    var body: some View {
        let host = model.activePageHost
        let tweaks = host.map { model.siteTweaks.tweaks(for: $0) } ?? []
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Page tweaks")
                    .font(BrowserType.font(.small))
                    .foregroundStyle(Color.browsemiumPrimary)
                Spacer(minLength: 0)
                BrowsemiumTextButton("Add…") {
                    if let host { model.siteTweaks.beginAdd(host: host) }
                }
                .disabled(host == nil)
            }
            if tweaks.isEmpty {
                Text(model.session.isPrivate
                    ? "Tweaks written in this private window are forgotten when it closes."
                    : "Your own CSS for this site. Nothing yet.")
                    .font(BrowserType.font(.caption))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(tweaks) { tweak in
                    HStack(spacing: 6) {
                        Text(tweak.name)
                            .font(BrowserType.font(.small))
                            .foregroundStyle(Color.browsemiumSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Toggle("", isOn: Binding(
                            get: { tweak.isEnabled },
                            set: { model.siteTweaks.setEnabled(tweak, enabled: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help(tweak.isEnabled ? "Turn this tweak off" : "Turn this tweak back on")
                        BrowsemiumIconButton(systemName: "pencil", label: "Edit tweak") {
                            model.siteTweaks.beginEdit(tweak)
                        }
                        BrowsemiumIconButton(systemName: "trash", label: "Remove tweak") {
                            model.siteTweaks.remove(tweak)
                        }
                    }
                }
            }
        }
    }
}

/// Edit CSS for one site, with a live preview on the open page.
@MainActor
struct SiteTweakEditorSheet: View {
    @Bindable var tweaks: SiteTweakController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tweaks.isEditing ? "Edit tweak" : "New tweak")
                .font(BrowserType.font(.title, weight: .semibold))
            Text("CSS for \(tweaks.host). It restyles what the page already shows; it cannot load anything from the network.")
                .font(BrowserType.font(.small))
                .foregroundStyle(Color.browsemiumSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $tweaks.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Tweak name")

            if tweaks.canWriteWithAssistant {
                HStack(spacing: 8) {
                    TextField("Describe the change, such as “hide the sidebar and widen the text”", text: $tweaks.requestText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { tweaks.writeWithAssistant() }
                        .accessibilityLabel("Describe the change")
                    BrowsemiumTextButton(tweaks.isWriting ? "Writing…" : "Write CSS") { tweaks.writeWithAssistant() }
                        .disabled(tweaks.isWriting || tweaks.requestText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Written on this Mac by Apple Intelligence from the page's structure only, never its text. Check the preview before saving.")
                    .font(BrowserType.font(.caption))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $tweaks.css)
                .font(BrowserType.font(.small, design: .monospaced))
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.browsemiumField)
                .clipShape(RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius))
                .accessibilityLabel("CSS")

            if let problem = tweaks.problem {
                Text(problem)
                    .font(BrowserType.font(.small))
                    .foregroundStyle(Color.browsemiumWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                BrowsemiumTextButton("Cancel") { tweaks.cancelEditor() }
                    .keyboardShortcut(.cancelAction)
                BrowsemiumTextButton("Preview on page") { tweaks.previewEditor() }
                Spacer()
                BrowsemiumPrimaryButton("Save") { tweaks.saveEditor() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(Color.browsemiumSurface)
        .foregroundStyle(Color.browsemiumPrimary)
    }
}
