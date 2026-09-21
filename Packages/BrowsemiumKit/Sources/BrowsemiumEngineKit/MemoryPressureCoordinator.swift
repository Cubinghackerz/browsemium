import Foundation

public enum MemoryPressureLevel: Sendable {
    case warning
    case critical
}

@MainActor
public final class MemoryPressureCoordinator {
    private var source: DispatchSourceMemoryPressure?
    private var handler: (@MainActor (MemoryPressureLevel) -> Void)?

    public init() {}

    public func start(handler: @escaping @MainActor (MemoryPressureLevel) -> Void) {
        stop()
        self.handler = handler
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        Self.installEventHandler(on: source, coordinator: self)
        source.resume()
        self.source = source
    }

    /// The handler is installed from a `nonisolated` static function on
    /// purpose. A closure literal formed inside a `@MainActor` method keeps
    /// that isolation, and the compiler guards it with a runtime check —
    /// `swift_task_isCurrentExecutor` → `dispatch_assert_queue` →
    /// EXC_BREAKPOINT — the first time the dispatch source fires it on the
    /// utility queue. Moving the closure here guarantees it is formed with no
    /// inherited isolation, so only the captured source is touched off-main
    /// and the callback hops to the main actor explicitly.
    private nonisolated static func installEventHandler(
        on source: DispatchSourceMemoryPressure,
        coordinator: MemoryPressureCoordinator
    ) {
        source.setEventHandler { [weak source, weak coordinator] in
            guard let source else { return }
            let event = source.data
            let level: MemoryPressureLevel
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                return
            }
            Task { @MainActor [weak coordinator] in
                coordinator?.handler?(level)
            }
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
        handler = nil
    }
}
