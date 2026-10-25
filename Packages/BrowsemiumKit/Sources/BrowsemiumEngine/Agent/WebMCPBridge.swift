import BrowsemiumCore
import Foundation
import WebKit

/// The experimental WebMCP bridge: a document-start script that gives a task
/// page the registration half of `navigator.modelContext`, and the native
/// calls that list and run what the page registered.
///
/// What this is not: it is not installed in the person's own tabs, it never
/// replaces an implementation the engine already provides, and it is not a
/// security boundary. The shim runs in the page's own world because the page
/// must be able to call it, so a page can read, replace or forge anything the
/// shim does. Everything it reports is therefore page-authored data. What
/// contains it is outside this file: the `webmcp` grant, origin pinning, the
/// native confirmation before every call, and the untrusted envelope on every
/// result.
///
/// Only the registration surface is implemented (`registerTool`,
/// `unregisterTool`). `getTools`, `executeTool` and the tool events are not,
/// so a page that probes for them sees an honest absence.
enum WebMCPBridge {
    /// The property a tab's shim installs on `window` so native code can reach
    /// the registry. Derived from a per-tab random nonce, so a page cannot
    /// pre-define it before the shim runs.
    static func accessorName(nonce: String) -> String { "__bmWebMCP_" + nonce }

    static func makeNonce() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    @MainActor
    static func makeUserScript(nonce: String) -> WKUserScript {
        WKUserScript(
            source: shimSource.replacingOccurrences(of: "__BM_ACCESSOR__", with: accessorName(nonce: nonce)),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    // MARK: - Shim

    /// Defines `navigator.modelContext` only when it is absent and the context
    /// is secure. When the property already exists the script does nothing, so
    /// the bridge can never read tools a native implementation holds.
    static let shimSource = #"""
    (function () {
      'use strict';
      try {
        if (typeof navigator === 'undefined' || typeof window === 'undefined') { return; }
        if (window.isSecureContext !== true) { return; }
        if ('modelContext' in navigator) { return; }

        var registry = new Map();
        var generation = 0;
        var NAME = /^[A-Za-z0-9_.\-]{1,128}$/;

        function fail(name, message) { return new DOMException(message, name); }

        function schemaText(schema) {
          if (schema === undefined || schema === null) { return '{}'; }
          if (typeof schema !== 'object') { return null; }
          try { var text = JSON.stringify(schema); return typeof text === 'string' ? text : null; }
          catch (e) { return null; }
        }

        function register(tool, options) {
          if (tool === null || typeof tool !== 'object') { throw new TypeError('A tool is required.'); }
          var name = tool.name;
          if (typeof name !== 'string' || !NAME.test(name)) { throw new TypeError('Invalid tool name.'); }
          if (typeof tool.description !== 'string' || tool.description.length === 0) {
            throw new TypeError('A description is required.');
          }
          if (typeof tool.execute !== 'function') { throw new TypeError('An execute function is required.'); }
          var schema = schemaText(tool.inputSchema);
          if (schema === null) { throw new TypeError('The input schema must be a JSON object.'); }
          if (registry.has(name)) { throw fail('InvalidStateError', 'A tool with this name exists.'); }
          var annotations = (tool.annotations && typeof tool.annotations === 'object') ? tool.annotations : {};
          generation += 1;
          var entry = {
            name: name,
            description: tool.description,
            schema: schema,
            execute: tool.execute,
            thisArg: tool,
            readOnly: annotations.readOnlyHint === true,
            consequential: annotations.consequentialHint === true,
            generation: generation
          };
          registry.set(name, entry);
          var signal = options && options.signal;
          if (signal && typeof signal.addEventListener === 'function') {
            if (signal.aborted) { registry.delete(name); }
            else { signal.addEventListener('abort', function () { if (registry.get(name) === entry) { registry.delete(name); } }); }
          }
        }

        var context = {
          registerTool: function (tool, options) {
            try { register(tool, options); return Promise.resolve(); }
            catch (error) { return Promise.reject(error); }
          },
          unregisterTool: function (name) {
            if (!registry.delete(String(name))) { return Promise.reject(fail('NotFoundError', 'No such tool.')); }
            return Promise.resolve();
          }
        };
        Object.freeze(context);

        function fingerprint(entry) {
          return JSON.stringify([entry.name, entry.description, entry.schema, entry.generation]);
        }

        var accessor = Object.freeze({
          list: function () {
            var tools = [];
            registry.forEach(function (entry) {
              tools.push({
                name: entry.name,
                description: entry.description,
                schema: entry.schema,
                fingerprint: fingerprint(entry),
                readOnly: entry.readOnly,
                consequential: entry.consequential
              });
            });
            return JSON.stringify(tools);
          },
          call: async function (name, expected, argumentsText) {
            var entry = registry.get(String(name));
            if (!entry || fingerprint(entry) !== expected) { return JSON.stringify({ status: 'stale' }); }
            var input;
            try { input = JSON.parse(argumentsText); } catch (e) { return JSON.stringify({ status: 'invalid' }); }
            var client = Object.freeze({
              requestUserInteraction: function () {
                return Promise.reject(fail('NotSupportedError', 'Not supported by this browser.'));
              }
            });
            try {
              var value = await entry.execute.call(entry.thisArg, input, client);
              var text = (typeof value === 'string') ? value : JSON.stringify(value === undefined ? null : value);
              if (typeof text !== 'string') { return JSON.stringify({ status: 'error' }); }
              return JSON.stringify({ status: 'ok', result: text });
            } catch (e) {
              return JSON.stringify({ status: 'error' });
            }
          }
        });

        Object.defineProperty(navigator, 'modelContext', { value: context, enumerable: true, configurable: false, writable: false });
        Object.defineProperty(window, '__BM_ACCESSOR__', { value: accessor, enumerable: false, configurable: false, writable: false });
      } catch (e) { /* the page keeps working without the bridge */ }
    })();
    """#

    // MARK: - Native decoding

    struct ToolPayload: Decodable {
        let name: String
        let description: String
        let schema: String
        let fingerprint: String
        let readOnly: Bool
        let consequential: Bool
    }

    /// Turns the page's list into tools the gate may show. Anything outside
    /// the limits is dropped rather than truncated, because a truncated
    /// description or schema would no longer be what the fingerprint binds.
    static func decodeTools(_ raw: String) throws -> [AgentPageTool] {
        guard let payload = try? JSONDecoder().decode([ToolPayload].self, from: Data(raw.utf8)) else {
            throw AgentError.unavailable
        }
        var seen = Set<String>()
        var tools: [AgentPageTool] = []
        for item in payload {
            guard AgentPageTool.isValidName(item.name), seen.insert(item.name).inserted,
                  item.description.count <= AgentLimits.maxPageToolDescription,
                  item.schema.utf8.count <= AgentLimits.maxPageToolSchemaBytes else { continue }
            tools.append(AgentPageTool(
                name: item.name,
                description: item.description,
                inputSchema: item.schema,
                fingerprint: item.fingerprint,
                readOnlyHint: item.readOnly,
                consequentialHint: item.consequential
            ))
            if tools.count == AgentLimits.maxPageTools { break }
        }
        return tools
    }

    struct CallPayload: Decodable {
        let status: String
        let result: String?
    }

    /// Maps the shim's reply onto the gate's fixed error vocabulary. Page
    /// exception text never leaves the page.
    static func decodeCall(_ raw: String) throws -> String {
        guard let payload = try? JSONDecoder().decode(CallPayload.self, from: Data(raw.utf8)) else {
            throw AgentError.unavailable
        }
        switch payload.status {
        case "ok":
            guard let result = payload.result else { throw AgentError.unavailable }
            return String(result.prefix(AgentLimits.maxPageToolResultCharacters))
        case "stale": throw AgentError.staleElement
        case "invalid": throw AgentError.invalidArguments
        default: throw AgentError.unavailable
        }
    }
}
