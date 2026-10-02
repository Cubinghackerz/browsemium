import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
import Foundation
import Observation

/// Profile-local orchestration. Parsing and preparation run off the main actor;
/// no database write occurs until compilation and cancellation checks succeed.
@Observable @MainActor final class UserFilterListController {
    enum State: Equatable {
        case idle, parsing, compiling, active
        case failed(String, usesLastGood: Bool)
    }

    private(set) var state: State = .idle
    private(set) var lists: [UserFilterList] = []
    var isBusy: Bool { state == .parsing || state == .compiling }

    @ObservationIgnored private var repository: UserFilterListRepository
    @ObservationIgnored private let manager: ContentRuleListManager
    @ObservationIgnored private let allowsChanges: () -> Bool
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var receipts: [String: CompiledUserContentRules] = [:]
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var hasRestored = false

    init(repository: UserFilterListRepository, manager: ContentRuleListManager,
         allowsChanges: @escaping () -> Bool = { true }) {
        self.repository = repository
        self.manager = manager
        self.allowsChanges = allowsChanges
        manager.beginUserProfile(repository.profileID)
    }

    func bind(_ repository: UserFilterListRepository) {
        restoreTask?.cancel()
        generation = UUID()
        self.repository = repository
        lists = []
        receipts = [:]
        hasRestored = false
        manager.beginUserProfile(repository.profileID)
        startRestoring()
    }

    func startRestoring() {
        state = .compiling
        let token = generation
        let repository = repository
        restoreTask = Task { [weak self] in await self?.restore(repository: repository, token: token) }
    }

    func restore() async {
        guard !isBusy else { return }
        let token = generation
        let repository = repository
        state = .compiling
        await restore(repository: repository, token: token)
    }

    private func restore(repository: UserFilterListRepository, token: UUID) async {
        do {
            try validate(token)
            let stored = try await Self.background { try repository.all() }
            try validate(token)
            var staged: [String: CompiledUserContentRules] = [:]
            for list in stored where list.isEnabled {
                let id = Self.identifier(for: list, profileID: repository.profileID)
                if let cached = receipts[id] { staged[id] = cached }
                else { staged[id] = try await manager.compileUserRules(identifier: id, rulesJSON: list.rulesJSON) }
                try validate(token)
            }
            try manager.installUserRules(stored.filter(\.isEnabled).compactMap {
                staged[Self.identifier(for: $0, profileID: repository.profileID)]
            })
            receipts = staged
            lists = stored
            hasRestored = true
            state = .active
        } catch { report(error, token: token) }
    }

    func importData(_ data: Data, name: String, source: UserFilterList.Source, replacing id: UUID? = nil) async {
        guard !isBusy else { return }
        let token = generation
        let repository = repository
        do {
            try requireChangesAllowed()
            guard hasRestored else {
                state = .failed("Load this profile's filter lists before importing. Try loading them again.",
                                usesLastGood: !manager.installedUserRuleIdentifiers.isEmpty)
                return
            }
            state = .parsing
            let conversion = try await Self.background {
                try FilterListConverter.convert(data, isCancelled: { Task.isCancelled })
            }
            try validate(token)
            let candidate = try await Self.background {
                try repository.prepare(conversion, name: name, source: source, replacing: id)
            }
            try validate(token)
            state = .compiling
            let receipt = try await manager.compileUserRules(identifier: candidate.compiledIdentifier,
                                                            rulesJSON: candidate.conversion.rulesJSON)
            try validate(token)
            try requireChangesAllowed()
            // Do not suspend between the final authorization/staleness check,
            // the revision-checked commit, and the runtime swap.
            let saved = try repository.commit(candidate, compiledIdentifier: receipt.identifier)
            receipts[receipt.identifier] = receipt
            let updated = (lists.filter { $0.id != saved.id } + [saved]).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            try apply(updated)
            state = .active
        } catch { report(error, token: token) }
    }

    private func apply(_ stored: [UserFilterList]) throws {
        let enabled = try stored.filter(\.isEnabled).map { list in
            let id = Self.identifier(for: list, profileID: repository.profileID)
            guard let receipt = receipts[id] else { throw ContentRuleListManager.UserRuleError.compilationFailed }
            return receipt
        }
        try manager.installUserRules(enabled)
        let retained = Set(stored.map { Self.identifier(for: $0, profileID: repository.profileID) })
        receipts = receipts.filter { retained.contains($0.key) }
        lists = stored
    }

    private func validate(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func requireChangesAllowed() throws {
        guard allowsChanges() else { throw UserFilterListRepository.RepositoryError.readOnly }
    }

    private func report(_ error: Error, token: UUID) {
        guard token == generation else { return }
        if error is CancellationError || error as? FilterListConverter.ConversionError == .cancelled {
            state = lists.isEmpty ? .idle : .active
            return
        }
        let message: String
        switch error {
        case let error as FilterListConverter.ConversionError: message = error.localizedDescription
        case let error as UserFilterListRepository.RepositoryError: message = error.localizedDescription
        case let error as ContentRuleListManager.UserRuleError: message = error.localizedDescription
        default: message = "The filter list could not be loaded. Existing rules were not replaced."
        }
        state = .failed(message, usesLastGood: !manager.installedUserRuleIdentifiers.isEmpty)
    }

    private static func identifier(for list: UserFilterList, profileID: UUID) -> String {
        UserFilterListRepository.compiledIdentifier(profileID: profileID, listID: list.id, contentHash: list.contentHash)
    }

    nonisolated private static func background<Value: Sendable>(
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: .utility) { try Task.checkCancellation(); return try work() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
