import BrowsemiumCore
import Foundation

/// The only way the agent gate touches a page. There is deliberately no script
/// entry point: every operation is a fixed, browser-owned action on a page the
/// task created.
///
/// Access semantics (these matter for takeover):
/// - `setAgentAccess(false)` ends the agent's ability to act, cancels loads the
///   agent started, and fails any in-flight agent call. It does **not** close
///   pages or discard their state, so a person who takes over keeps the
///   workspace. While access is off, page navigation is the person's.
/// - `closeTab` is the only call that discards a page.
@MainActor
public protocol PageActuating: AnyObject {
    /// Creates a task-owned tab on the profile's data store. `dataStoreID` is
    /// supplied by the gate from the native grant, never from a tool argument.
    /// `authorizeNavigation` is asked before every main-frame navigation the
    /// page makes while agent access is on, including redirects.
    func createTab(
        _ id: TabID,
        dataStoreID: UUID,
        authorizeNavigation: @escaping @MainActor (URL) -> Bool
    ) throws

    func setAgentAccess(_ enabled: Bool)
    func closeTab(_ id: TabID)

    func currentOrigin(_ id: TabID) -> AgentOrigin?
    func navigate(_ id: TabID, to url: URL) async throws
    func snapshot(_ id: TabID) async throws -> AgentPageSnapshot
    func readText(_ id: TabID) async throws -> String
    func screenshot(_ id: TabID) async throws -> Data
    func resolve(_ reference: String, in id: TabID) async throws -> AgentElement
    /// Performs the action only if the live element still matches the
    /// action's element fingerprint and the page is still on its origin.
    func perform(_ action: AgentPageAction, in id: TabID) async throws
}
