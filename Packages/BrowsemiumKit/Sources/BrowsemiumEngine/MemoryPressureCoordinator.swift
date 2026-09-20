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
        // The handler fires on the source's utility queue, not the main actor.
        // Reading `self.source`/`self.handler` here would trap the runtime
        // isolation check (EXC_BREAKPOINT), so only the captured source is
        // touched and the callback hops to the main actor explicitly.
        source.setEventHandler { [weak self, weak source] in
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
            Task { @MainActor [weak self] in
                self?.handler?(level)
            }
        }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        handler = nil
    }
}
