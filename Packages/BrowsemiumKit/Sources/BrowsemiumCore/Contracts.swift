import Foundation

@MainActor
public protocol BrowserRuntime: AnyObject {
    func activate(tabID: TabID, in pane: PaneID) async
    func navigate(tabID: TabID, to request: NavigationRequest) async throws
    func suspend(tabID: TabID) async
    func hibernate(tabID: TabID) async
    func capture(tabID: TabID, request: CaptureRequest) async throws -> CapturedContext
}

public protocol AIProviderAdapter: Sendable {
    var id: AIProviderID { get }

    func validateCredential() async throws
    func listModels() async throws -> [AIModel]
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error>
}
