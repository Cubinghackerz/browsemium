import SwiftUI

@MainActor
struct FindBar: View {
    @Bindable var model: BrowserWindowModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Find on page", text: $model.findText)
                .textFieldStyle(.plain)
                .font(BrowserType.font(.small))
                .focused($isFocused)
                .onSubmit { model.findOnPage() }
                .onChange(of: model.findText) { model.findOnPage() }
                .accessibilityLabel("Find on page")

            if let status = model.findStatus {
                Text(status)
                    .font(BrowserType.font(.caption))
                    .foregroundStyle(Color.browsemiumTertiary)
            }

            BrowsemiumIconButton(systemName: "chevron.up", label: "Previous match") {
                model.findOnPage(backwards: true)
            }
            BrowsemiumIconButton(systemName: "chevron.down", label: "Next match") {
                model.findOnPage()
            }
            BrowsemiumIconButton(systemName: "xmark", label: "Close find") {
                model.dismissFindBar()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(width: 330, height: 30)
        .browsemiumOverlaySurface(radius: BrowserMetrics.controlRadius, strongBorder: true, shadowOpacity: 0.14, shadowRadius: 10, shadowY: 3)
        .onAppear { isFocused = true }
    }
}
