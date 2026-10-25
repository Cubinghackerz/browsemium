import BrowsemiumCore
import BrowsemiumData
import SwiftUI
import BrowsemiumEngineKit

/// The start surface: a search field first, then the sites and pages that
/// matter. The private variant shows none of the history-derived parts.
struct NewTabView: View {
    @Bindable var model: BrowserWindowModel
    @State private var topSites: [TopSite] = []
    @State private var pickUpRows: [PickUpRow] = []
    @State private var resumeTopics: [ResumeTopic] = []
    @State private var topicsTask: Task<Void, Never>?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("browsemium.importOfferDismissed") private var importOfferDismissed = false

    private let tileColumns = [GridItem(.adaptive(minimum: 96, maximum: 104), spacing: 10)]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if model.session.isPrivate {
                        privateHeader
                    } else {
                        spaceHeader
                        BrowsemiumWordmark(size: 17)
                            .padding(.top, 14)
                        searchField.padding(.top, 18)
                        shortcutHints.padding(.top, 14)
                        importOffer
                        pickUpSection
                        topicsSection
                        tileSection(
                            title: "Top Sites",
                            tiles: topSites.map { Tile(url: $0.url, title: $0.title, hint: "\($0.visitCount) visits") }
                        )
                        tileSection(
                            title: "Bookmarks",
                            tiles: model.bookmarks.prefix(6).map {
                                Tile(url: $0.url, title: $0.title.isEmpty ? ($0.url.host ?? "Bookmark") : $0.title, hint: nil)
                            }
                        )
                    }
                }
                .frame(maxWidth: 680)
                .padding(.vertical, 32)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Color.browsemiumRaised)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.session.isPrivate { model.focusAddress() } else { searchFocused = true }
        }
        .onAppear {
            reload()
            if !model.session.isPrivate { searchFocused = true }
        }
        // Counts change while the app runs; refresh on navigation instead of
        // snapshotting once at mount.
        .onChange(of: model.activeTab?.lastCommittedURL) { reload() }
        .onChange(of: model.session.activeSpaceID) { reload() }
    }

    private struct Tile: Identifiable {
        let url: URL
        let title: String
        let hint: String?
        var id: String { url.absoluteString }
    }

    private func reload() {
        // Private windows never surface history, closed tabs or the archive.
        guard !model.session.isPrivate else {
            topSites = []
            pickUpRows = []
            resumeTopics = []
            return
        }
        topSites = (try? model.environment.historyRepository.topSites(limit: 8)) ?? []
        let spaces = model.session.spaces
        let active = model.session.activeSpaceID
        pickUpRows = NewTabContent.pickUp(
            closed: model.recentlyClosedTabs(limit: 12),
            archived: model.archivedTabs(limit: 12),
            isEligible: { NewTabContent.isEligible($0, spaces: spaces, active: active) }
        )
        // Topics cluster on-device and can take a moment; they fill in when
        // ready and stay empty when the index is off or has too few pages.
        // One refresh at a time: reload fires on every navigation.
        if topicsTask == nil {
            topicsTask = Task {
                defer { topicsTask = nil }
                resumeTopics = await model.resumeTopics()
            }
        }
    }

    // MARK: Header and search

    private var spaceHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(spaceColor)
                .frame(width: 8, height: 8)
            Text(model.activeGroup?.name ?? "Tabs")
                .font(BrowserType.font(.small, weight: .medium))
                .foregroundStyle(Color.browsemiumSecondary)
                .lineLimit(1)
            if model.activeGroup?.hasSeparateData == true {
                Image(systemName: "person.crop.square")
                    .font(BrowserType.font(.caption, weight: .medium))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(Color.browsemiumField))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spaceAccessibilityLabel)
        .accessibilityAddTraits(.isHeader)
    }

    private var spaceColor: Color {
        guard let hex = model.activeGroup?.color else { return Color.browsemiumTertiary }
        return Color(browsemiumHex: hex) ?? Color.browsemiumTertiary
    }

    private var spaceAccessibilityLabel: String {
        let name = model.activeGroup?.name ?? "Tabs"
        return model.activeGroup?.hasSeparateData == true
            ? "Space \(name), keeps its own cookies and logins"
            : "Space \(name)"
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(BrowserType.font(.body, weight: .medium))
                .foregroundStyle(Color.browsemiumTertiary)
                .accessibilityHidden(true)
            TextField("Search or enter address", text: $query)
                .textFieldStyle(.plain)
                .font(BrowserType.font(.title))
                .foregroundStyle(Color.browsemiumPrimary)
                .focused($searchFocused)
                .onSubmit { submit() }
                .accessibilityLabel("Search or enter address")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .frame(maxWidth: 480)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(searchFocused ? Color.browsemiumSelection : Color.browsemiumField)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    searchFocused ? Color.browsemiumFocus : Color.browsemiumBorderStrong,
                    lineWidth: searchFocused ? 1.5 : 1
                )
        }
    }

    private func submit() {
        let text = query
        NewTabTarget.search(text).perform(in: model)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { query = "" }
    }

    private var shortcutHints: some View {
        HStack(spacing: 14) {
            hint("⌘T", "New tab")
            hint("⌘K", "Commands")
            hint("⇧⌘A", "Assistant")
        }
    }

    @ViewBuilder
    private var importOffer: some View {
        if !importOfferDismissed {
            HStack(spacing: 10) {
                Button("Move from another browser") {
                    importOfferDismissed = true
                    model.openPanel(.importWizard)
                }
                Button("Dismiss") { importOfferDismissed = true }
                    .foregroundStyle(Color.browsemiumTertiary)
            }
            .buttonStyle(.plain)
            .font(BrowserType.font(.small))
            .padding(.top, 18)
        }
    }

    // MARK: Pick up where you left off

    @ViewBuilder
    private var pickUpSection: some View {
        if !pickUpRows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Pick up where you left off")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(pickUpRows) { row in pickUpCard(row) }
                }
            }
            .padding(.top, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var topicsSection: some View {
        if !resumeTopics.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Resume topics")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(resumeTopics) { topic in topicCard(topic) }
                }
            }
            .padding(.top, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Up to two distinct hosts behind a topic, in page order.
    private static func topicHosts(_ topic: ResumeTopic) -> [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        for page in topic.pages {
            guard let host = page.url.host, seen.insert(host).inserted else { continue }
            hosts.append(host)
            if hosts.count == 2 { break }
        }
        return hosts
    }

    private func topicCard(_ topic: ResumeTopic) -> some View {        Button {
            model.openResumeTopic(topic)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(BrowserType.font(.small))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(topic.label)
                        .font(BrowserType.font(.small, weight: .medium))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .lineLimit(1)
                    Text("\(topic.pages.count) pages · \(Self.topicHosts(topic).joined(separator: ", "))")
                        .font(BrowserType.font(.caption))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(Color.browsemiumField)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .stroke(Color.browsemiumBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume topic \(topic.label), \(topic.pages.count) pages")
        .accessibilityHint("Reopens its pages in new tabs")
    }

    private func pickUpCard(_ row: PickUpRow) -> some View {        Button {
            NewTabTarget.pickUp(row).perform(in: model)
        } label: {
            HStack(spacing: 8) {
                icon(for: row.url, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(BrowserType.font(.small, weight: .medium))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .lineLimit(1)
                    Text(row.source == .archived ? "Put away · \(row.host)" : "Closed · \(row.host)")
                        .font(BrowserType.font(.caption))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(Color.browsemiumField)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .stroke(Color.browsemiumBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.url.absoluteString)
        .accessibilityLabel("\(row.title), \(row.source == .archived ? "put away" : "recently closed"), \(row.host)")
        .accessibilityHint("Opens it in this tab")
    }

    // MARK: Tiles

    @ViewBuilder
    private func tileSection(title: String, tiles: [Tile]) -> some View {
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle(title)
                LazyVGrid(columns: tileColumns, alignment: .leading, spacing: 10) {
                    ForEach(tiles) { tile in siteTile(tile) }
                }
            }
            .padding(.top, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(BrowserType.font(.caption, weight: .semibold))
            .foregroundStyle(Color.browsemiumTertiary)
            .accessibilityAddTraits(.isHeader)
    }

    private func siteTile(_ tile: Tile) -> some View {
        Button {
            NewTabTarget.site(tile.url).perform(in: model)
        } label: {
            VStack(spacing: 8) {
                icon(for: tile.url, size: 28)
                Text(tile.title)
                    .font(BrowserType.font(.caption))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(width: 96, height: 84)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(Color.browsemiumField)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .stroke(Color.browsemiumBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tile.url.absoluteString)
        .accessibilityLabel(tile.title)
        .accessibilityHint(tile.hint ?? tile.url.absoluteString)
    }

    /// The cached favicon, or the host's first letter in a quiet circle.
    @ViewBuilder
    private func icon(for url: URL, size: CGFloat) -> some View {
        if let favicon = model.favicons.image(for: url) {
            Image(nsImage: favicon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Text(NewTabContent.fallbackLetter(forHost: url.host))
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(Color.browsemiumSecondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.browsemiumSelection))
                .accessibilityHidden(true)
        }
    }

    // MARK: Private

    /// The private window's start surface: what this mode protects, stated
    /// plainly — including what it cannot protect. No overclaiming.
    private var privateHeader: some View {
        VStack(spacing: 0) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(BrowserToolbar.privateTint)
                .padding(.bottom, 16)
                .accessibilityHidden(true)

            Text("Private Window")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.browsemiumPrimary)

            VStack(alignment: .leading, spacing: 7) {
                Label("History, cookies, and site data stay out of this profile's storage", systemImage: "checkmark")
                Label("Extensions do not run here", systemImage: "checkmark")
                Label("Closing the window wipes everything it touched", systemImage: "checkmark")
                Label("Downloads save to disk and bookmarks you make are kept", systemImage: "minus")
                Label("Sites, your network, and your ISP can still see your activity", systemImage: "exclamationmark.triangle")
            }
            .font(BrowserType.font(.small))
            .foregroundStyle(Color.browsemiumSecondary)
            .padding(.top, 18)
            .accessibilityElement(children: .combine)

            Text("Search or type an address — ⌘L jumps straight to it.")
                .font(BrowserType.font(.body))
                .foregroundStyle(Color.browsemiumTertiary)
                .padding(.top, 20)
        }
        .frame(maxWidth: 460)
    }

    private func hint(_ keys: String, _ description: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(BrowserType.font(.caption, design: .monospaced))
                .foregroundStyle(Color.browsemiumSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.browsemiumField)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.browsemiumBorder, lineWidth: 1)
                }
            Text(description)
                .font(BrowserType.font(.small))
                .foregroundStyle(Color.browsemiumTertiary)
        }
        .accessibilityHidden(true)
    }
}
