import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumData
import Foundation
import Observation

/// A person's own per-site CSS: the list for the current site, the editor,
/// and a live preview. Tweaks ride the same document-start injection as
/// hidden elements, so a change reaches the open page without a reload.
///
/// Tweaks written in a private window live only in memory and are gone when
/// it closes. Saved tweaks apply everywhere, as hidden elements do.
@MainActor
@Observable
public final class SiteTweakController {
    public var isEditorPresented = false
    public var name = ""
    public var css = ""
    public private(set) var host = ""
    public private(set) var problem: String?
    public private(set) var isEditing = false
    /// What the person wants, in words, for the on-device assistant.
    public var requestText = ""
    public private(set) var isWriting = false
    /// Whether Apple's on-device model can write CSS right now.
    public private(set) var canWriteWithAssistant = false
    @ObservationIgnored public var generate: (String) async throws -> String = { prompt in
        let adapter = AppleIntelligence.makeAdapter()
        let model = try await adapter.listModels().first
        guard let model else { throw AppleIntelligenceUnavailable.modelNotReady }
        var reply = ""
        let request = AIRequest(model: model, messages: [AIMessage(role: .user, content: prompt)])
        for try await event in adapter.stream(request) {
            if case .completed(let message) = event { reply = message.content }
        }
        return reply
    }
    /// Bumped on every change so views re-read the list.
    public private(set) var revision = 0

    @ObservationIgnored private weak var model: BrowserWindowModel?
    @ObservationIgnored private var editingID: String?
    @ObservationIgnored private var privateTweaks: [String: [SiteTweak]] = [:]
    @ObservationIgnored private var preview: (host: String, css: String)?

    func attach(model: BrowserWindowModel) { self.model = model }

    // MARK: - Reading

    public func tweaks(for host: String) -> [SiteTweak] {
        _ = revision
        let key = host.lowercased()
        let saved = (try? model?.environment.siteTweakRepository.tweaks(host: key)) ?? []
        return saved + (privateTweaks[key] ?? [])
    }

    /// The CSS the engine should inject, per host: saved and private tweaks,
    /// with the tweak under edit replaced by its live preview.
    func cssByHost() -> [String: String] {
        guard let model else { return [:] }
        var byHost: [String: [SiteTweak]] = [:]
        for host in (try? model.environment.siteTweakRepository.hosts()) ?? [] {
            byHost[host] = (try? model.environment.siteTweakRepository.tweaks(host: host)) ?? []
        }
        for (host, tweaks) in privateTweaks { byHost[host, default: []].append(contentsOf: tweaks) }

        var result: [String: String] = [:]
        for (host, tweaks) in byHost {
            let active = tweaks.filter { $0.id != editingID || preview == nil }
            let css = SiteTweakRepository.css(for: active)
            if !css.isEmpty { result[host] = css }
        }
        if let preview {
            result[preview.host] = [result[preview.host], preview.css].compactMap { $0 }.joined(separator: "\n")
        }
        return result
    }

    // MARK: - Editing

    public func beginAdd(host: String) {
        self.host = host.lowercased()
        name = ""
        css = ""
        problem = nil
        editingID = nil
        isEditing = false
        requestText = ""
        isEditorPresented = true
        refreshAssistantAvailability()
    }

    public func beginEdit(_ tweak: SiteTweak) {
        host = tweak.host
        name = tweak.name
        css = tweak.css
        problem = nil
        editingID = tweak.id
        isEditing = true
        requestText = ""
        isEditorPresented = true
        refreshAssistantAvailability()
    }

    private func refreshAssistantAvailability() {
        Task { [weak self] in
            let available = (try? await AppleIntelligence.makeAdapter().listModels()) != nil
            self?.canWriteWithAssistant = available
        }
    }

    /// Asks Apple's on-device model for CSS and puts it in the editor. Nothing
    /// leaves this Mac, so there is nothing to review before sending; the
    /// person previews the result and saving still runs the validator.
    public func writeWithAssistant() {
        guard let model, !isWriting else { return }
        let description = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            problem = "Say what you want changed first."
            return
        }
        guard let tabID = model.session.activeTabID,
              model.isSpaceUnlocked(model.session.activeSpaceID) else { return }
        isWriting = true
        problem = nil
        let host = self.host
        Task { [weak self] in
            guard let self else { return }
            defer { self.isWriting = false }
            let outline = ((try? await model.environment.engine.evaluateJavaScript(
                tabID: tabID, script: TweakAssistant.outlineScript
            )) as? String) ?? ""
            guard !outline.isEmpty else {
                self.problem = "The page has not loaded, so there is nothing to describe yet."
                return
            }
            do {
                let reply = try await self.generate(TweakAssistant.prompt(host: host, description: description, outline: outline))
                guard let css = TweakAssistant.extractCSS(from: reply) else {
                    self.problem = "The assistant did not return CSS. Try describing the change differently."
                    return
                }
                switch SiteTweakValidator.validate(css: css) {
                case .success(let valid):
                    self.css = valid
                    self.previewEditor()
                case .failure(let failure):
                    self.css = css
                    self.problem = failure.message
                }
            } catch {
                self.problem = error.localizedDescription
            }
        }
    }

    /// Shows the CSS in the editor on the open page, without saving it.
    public func previewEditor() {
        switch SiteTweakValidator.validate(css: css) {
        case .failure(let failure):
            problem = failure.message
            clearPreview()
        case .success(let valid):
            problem = nil
            preview = (host, valid)
            refresh()
        }
    }

    public func saveEditor() {
        guard let model else { return }
        let checkedCSS: String
        let checkedName: String
        do {
            checkedCSS = try SiteTweakValidator.validate(css: css).get()
            checkedName = try SiteTweakValidator.validate(name: name).get()
        } catch let failure as SiteTweakProblem {
            problem = failure.message
            return
        } catch {
            problem = error.localizedDescription
            return
        }
        if model.session.isPrivate {
            savePrivate(css: checkedCSS, name: checkedName)
        } else {
            do {
                if let editingID {
                    try model.environment.siteTweakRepository.update(id: editingID, name: checkedName, css: checkedCSS)
                } else {
                    try model.environment.siteTweakRepository.add(host: host, name: checkedName, css: checkedCSS)
                }
            } catch {
                problem = (error as? SiteTweakProblem)?.message ?? error.localizedDescription
                return
            }
        }
        model.statusMessage = "Tweak saved for \(host)"
        closeEditor()
    }

    private func savePrivate(css: String, name: String) {
        var list = privateTweaks[host] ?? []
        if let editingID, let index = list.firstIndex(where: { $0.id == editingID }) {
            list[index].name = name
            list[index].css = css
            list[index].updatedAt = Date()
        } else {
            list.append(SiteTweak(host: host, name: name, css: css))
        }
        privateTweaks[host] = list
    }

    public func cancelEditor() {
        closeEditor()
    }

    private func closeEditor() {
        isEditorPresented = false
        editingID = nil
        preview = nil
        problem = nil
        refresh()
    }

    private func clearPreview() {
        guard preview != nil else { return }
        preview = nil
        refresh()
    }

    // MARK: - Changing saved tweaks

    public func setEnabled(_ tweak: SiteTweak, enabled: Bool) {
        guard let model else { return }
        if var list = privateTweaks[tweak.host], let index = list.firstIndex(where: { $0.id == tweak.id }) {
            list[index].isEnabled = enabled
            privateTweaks[tweak.host] = list
        } else {
            do {
                try model.environment.siteTweakRepository.setEnabled(enabled, id: tweak.id)
            } catch {
                model.statusMessage = error.localizedDescription
                return
            }
        }
        refresh()
    }

    public func remove(_ tweak: SiteTweak) {
        guard let model else { return }
        if privateTweaks[tweak.host]?.contains(where: { $0.id == tweak.id }) == true {
            privateTweaks[tweak.host]?.removeAll { $0.id == tweak.id }
        } else {
            do {
                try model.environment.siteTweakRepository.remove(id: tweak.id)
            } catch {
                model.statusMessage = error.localizedDescription
                return
            }
        }
        refresh()
    }

    // MARK: - Lifecycle

    func profileDidChange() {
        closeEditor()
        privateTweaks.removeAll()
    }

    private func refresh() {
        revision += 1
        model?.pageStylesDidChange()
    }
}
