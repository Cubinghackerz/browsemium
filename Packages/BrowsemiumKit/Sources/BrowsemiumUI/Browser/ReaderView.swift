import BrowsemiumCore
import SwiftUI
import BrowsemiumEngineKit

/// Reading view: the page's article as text, styled for reading. Nothing from
/// the original page is rendered here, so no page CSS or script can affect it.
@MainActor
struct ReaderView: View {
    @Bindable var model: BrowserWindowModel
    let article: ReaderArticle

    @AppStorage("browsemium.readerFontSize") private var fontSize: Double = 16

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.browsemiumBorder)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(article.title)
                        .font(.system(size: fontSize + 9, weight: .semibold))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if let host = article.url?.host {
                            Text(host)
                        }
                        Text("·")
                        Text("\(article.estimatedReadingMinutes) min read")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.browsemiumTertiary)

                    ForEach(Array(article.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: fontSize))
                            .lineSpacing(fontSize * 0.42)
                            .foregroundStyle(Color.browsemiumPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.browsemiumCanvas)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 12))
                .foregroundStyle(Color.browsemiumSecondary)
            Text("Reader")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.browsemiumPrimary)

            Spacer(minLength: 10)

            BrowsemiumIconButton(systemName: "textformat.size.smaller", label: "Decrease text size") {
                fontSize = max(12, fontSize - 1)
            }
            BrowsemiumIconButton(systemName: "textformat.size.larger", label: "Increase text size") {
                fontSize = min(24, fontSize + 1)
            }

            Toggle("Always", isOn: alwaysBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.browsemiumSecondary)
                .help("Always open this site in Reader")

            BrowsemiumTextButton("Done") { model.closeReader() }
        }
        .padding(.horizontal, 12)
        .frame(height: BrowserMetrics.toolbarHeight)
    }

    private var alwaysBinding: Binding<Bool> {
        Binding(
            get: { model.prefersReader(for: article.url) },
            set: { model.setReaderPreference(always: $0) }
        )
    }
}
