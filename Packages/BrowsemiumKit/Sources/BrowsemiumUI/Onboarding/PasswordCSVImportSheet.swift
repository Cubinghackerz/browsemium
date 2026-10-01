import BrowsemiumData
import SwiftUI

/// Preview and column mapper. Password values never appear in the sheet.
@MainActor
struct PasswordCSVImportSheet: View {
    let csv: BrowserPasswordCSV
    let destinationName: String
    let errorMessage: String?
    let onCancel: () -> Void
    let onImport: ([ChromeLogin]) -> Void

    @State private var siteColumn: Int
    @State private var usernameColumn: Int
    @State private var passwordColumn: Int

    init(csv: BrowserPasswordCSV, destinationName: String, errorMessage: String?, onCancel: @escaping () -> Void, onImport: @escaping ([ChromeLogin]) -> Void) {
        self.csv = csv
        self.destinationName = destinationName
        self.errorMessage = errorMessage
        self.onCancel = onCancel
        self.onImport = onImport
        _siteColumn = State(initialValue: csv.suggestedMap?.site ?? 0)
        _usernameColumn = State(initialValue: csv.suggestedMap?.username ?? min(1, csv.headers.count - 1))
        _passwordColumn = State(initialValue: csv.suggestedMap?.password ?? min(2, csv.headers.count - 1))
    }

    private var mapped: [ChromeLogin] {
        (try? csv.credentials(using: .init(site: siteColumn, username: usernameColumn, password: passwordColumn))) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import passwords from CSV")
                .font(.system(size: 16, weight: .semibold))
            Text("Choose the columns from a browser or password-manager export. The source browser's encryption key is not read. Nothing is written until you import.")
                .font(.system(size: 12))
                .foregroundStyle(Color.browsemiumSecondary)
            column("Website", selection: $siteColumn)
            column("Username", selection: $usernameColumn)
            column("Password", selection: $passwordColumn)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.browsemiumWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Import into \(destinationName)")
                .font(.system(size: 12, weight: .medium))
            Text("\(mapped.count) of \(csv.rowCount) rows have a website, username, and password. Passwords go to macOS Keychain. The exported CSV contains readable passwords; delete it after importing.")
                .font(.system(size: 11))
                .foregroundStyle(Color.browsemiumSecondary)
            HStack {
                BrowsemiumTextButton("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                BrowsemiumPrimaryButton(mapped.count == 1 ? "Import 1 password" : "Import \(mapped.count) passwords", isDisabled: mapped.isEmpty) {
                    onImport(mapped)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Color.browsemiumSurface)
    }

    private func column(_ title: String, selection: Binding<Int>) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Picker(title, selection: selection) {
                ForEach(csv.headers.indices, id: \.self) { index in
                    Text(csv.headers[index]).tag(index)
                }
            }
            .labelsHidden()
            .frame(width: 240)
            .accessibilityLabel("\(title) column")
        }
    }
}
