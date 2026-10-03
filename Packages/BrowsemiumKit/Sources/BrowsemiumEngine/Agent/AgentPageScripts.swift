import Foundation

/// Browser-owned scripts for task pages. Each is a function body run through
/// `callAsyncJavaScript` in a dedicated `WKContentWorld`, so its globals and
/// the page's cannot see each other.
///
/// Honest limit: an isolated world isolates JavaScript, not the DOM. The page
/// can still reshape the elements these scripts read, which is why every
/// action re-derives a fingerprint immediately before acting, and why the
/// gate still asks the person before any click or typing.
///
/// Untrusted values (references, fingerprints, text) are passed as typed
/// arguments, never spliced into the source, so they cannot break out of it.
enum AgentPageScripts {
    /// Shared helpers, prepended to every body.
    private static let library = #"""
    const S = (window.__bmAgentState = window.__bmAgentState || { next: 0, refs: new Map(), ids: new WeakMap() });
    const TEXT_TYPES = ["text", "search", "email", "url", "tel", "number", ""];
    const SENSITIVE = /(pass(word|code|phrase)?\b|pwd|otp|one[- ]?time|2fa|mfa|totp|cvv|cvc|csc|card|ccnum|cc-|security code|verification code|\bpin\b|\bssn\b|social security|iban|routing number|account number|secret|token)/i;

    function clean(value, limit) {
      return String(value == null ? "" : value).replace(/\s+/g, " ").trim().slice(0, limit || 100);
    }
    function visible(el) {
      if (!el.isConnected) { return false; }
      if (!el.getClientRects().length) { return false; }
      const box = el.getBoundingClientRect();
      if (box.width <= 0 || box.height <= 0) { return false; }
      const style = getComputedStyle(el);
      return style.visibility !== "hidden" && style.display !== "none";
    }
    function roleOf(el) {
      const explicit = el.getAttribute("role");
      if (explicit) { return clean(explicit.split(" ")[0], 30).toLowerCase(); }
      const tag = el.tagName.toLowerCase();
      if (tag === "a") { return "link"; }
      if (tag === "button" || tag === "summary") { return "button"; }
      if (tag === "select") { return "combobox"; }
      if (tag === "textarea") { return "textbox"; }
      if (tag === "input") {
        const type = (el.getAttribute("type") || "text").toLowerCase();
        if (["button", "submit", "reset", "image"].includes(type)) { return "button"; }
        if (type === "checkbox" || type === "radio") { return type; }
        return "textbox";
      }
      return tag;
    }
    function labelText(el) {
      const parts = [];
      const aria = el.getAttribute("aria-label");
      if (aria) { parts.push(aria); }
      const by = el.getAttribute("aria-labelledby");
      if (by) {
        for (const id of by.split(/\s+/)) {
          const node = document.getElementById(id);
          if (node) { parts.push(node.textContent); }
        }
      }
      if (el.labels) { for (const label of el.labels) { parts.push(label.textContent); } }
      return clean(parts.join(" "));
    }
    // A name is what the page calls the control. Field values are never used,
    // so typed text cannot leak through a snapshot.
    function nameOf(el) {
      const label = labelText(el);
      if (label) { return label; }
      const tag = el.tagName.toLowerCase();
      if (tag === "input") {
        const type = (el.getAttribute("type") || "text").toLowerCase();
        if (["button", "submit", "reset"].includes(type)) { return clean(el.getAttribute("value") || type); }
        if (type === "image") { return clean(el.getAttribute("alt") || "image"); }
        return clean(el.getAttribute("placeholder") || el.getAttribute("title") || el.getAttribute("name") || "");
      }
      if (tag === "textarea" || tag === "select") {
        return clean(el.getAttribute("placeholder") || el.getAttribute("title") || el.getAttribute("name") || "");
      }
      return clean(el.innerText || el.textContent || el.getAttribute("title") || el.getAttribute("alt") || "");
    }
    function isField(el) {
      return el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT" || el.isContentEditable;
    }
    // Password, file, hidden, payment-card and one-time-code style fields are
    // refused for both clicking and typing. This is a conservative heuristic
    // over what the page declares, not a guarantee.
    function isSensitive(el) {
      if (!isField(el)) { return false; }
      const type = (el.getAttribute("type") || "").toLowerCase();
      if (["password", "file", "hidden"].includes(type)) { return true; }
      const haystack = [
        el.getAttribute("name"), el.id, el.getAttribute("placeholder"),
        el.getAttribute("autocomplete"), el.getAttribute("aria-label"), labelText(el)
      ].filter(Boolean).join(" ");
      return SENSITIVE.test(haystack);
    }
    function isEditable(el) {
      if (el.disabled || el.readOnly) { return false; }
      if (el.tagName === "TEXTAREA") { return true; }
      if (el.tagName !== "INPUT") { return false; }
      return TEXT_TYPES.includes((el.getAttribute("type") || "text").toLowerCase());
    }
    function hash(text) {
      let h1 = 0xdeadbeef, h2 = 0x41c6ce57;
      for (let i = 0; i < text.length; i++) {
        const ch = text.charCodeAt(i);
        h1 = Math.imul(h1 ^ ch, 2654435761);
        h2 = Math.imul(h2 ^ ch, 1597334677);
      }
      h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
      h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
      return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(16);
    }
    function pathOf(el) {
      const parts = [];
      let node = el;
      while (node && node.nodeType === 1 && node !== document.documentElement && parts.length < 30) {
        const parent = node.parentElement;
        if (!parent) { break; }
        parts.push(node.tagName + Array.prototype.indexOf.call(parent.children, node));
        node = parent;
      }
      return parts.join("/");
    }
    // Destinations are part of the fingerprint, so a link or form whose target
    // is swapped after the person looked at it no longer matches.
    function fingerprint(el) {
      const target = typeof el.href === "string" && el.getAttribute("href") ? el.href : "";
      const action = el.getAttribute("formaction") ? String(el.formAction) : "";
      const formAction = el.form ? String(el.form.action) : "";
      return hash([
        el.tagName, el.getAttribute("type") || "", roleOf(el), nameOf(el), pathOf(el),
        target, action, formAction, el.getAttribute("target") || "", isEditable(el), isSensitive(el)
      ].join("\u241f"));
    }
    function refFor(el) {
      let id = S.ids.get(el);
      if (!id) {
        id = "e" + (++S.next);
        S.ids.set(el, id);
        S.refs.set(id, new WeakRef(el));
      }
      return id;
    }
    function lookup(id) {
      const weak = S.refs.get(id);
      const el = weak && weak.deref();
      return el && el.isConnected ? el : null;
    }
    function describe(el) {
      return {
        id: refFor(el), role: roleOf(el), name: nameOf(el), fingerprint: fingerprint(el),
        editable: isEditable(el), sensitive: isSensitive(el)
      };
    }
    """#

    static let snapshot = library + #"""
    const selector = 'a[href], button, input:not([type="hidden"]), textarea, select, summary, ' +
      '[role="button"], [role="link"], [role="checkbox"], [role="menuitem"], [role="tab"], ' +
      '[role="textbox"], [role="switch"], [role="option"]';
    const elements = [];
    let truncated = false;
    for (const el of document.querySelectorAll(selector)) {
      if (el.disabled || !visible(el)) { continue; }
      if (elements.length >= limit) { truncated = true; break; }
      elements.push(describe(el));
    }
    return JSON.stringify({
      title: clean(document.title, 300), origin: location.origin, elements: elements, truncated: truncated
    });
    """#

    static let resolve = library + #"""
    const el = lookup(id);
    if (!el || !visible(el)) { return JSON.stringify({ error: "stale" }); }
    return JSON.stringify({ origin: location.origin, element: describe(el) });
    """#

    static let readText = #"""
    return (document.body ? document.body.innerText : "").slice(0, limit);
    """#

    /// Re-derives everything immediately before acting, in one script run, so
    /// there is no gap between the check and the action.
    static let perform = library + #"""
    if (location.origin !== origin) { return "origin"; }
    const el = lookup(id);
    if (!el || !visible(el)) { return "stale"; }
    if (isSensitive(el)) { return "sensitive"; }
    if (fingerprint(el) !== expected) { return "stale"; }
    if (kind === "type") {
      if (!isEditable(el)) { return "notEditable"; }
      el.focus();
      const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text);
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
      return "ok";
    }
    if (kind === "click") {
      el.scrollIntoView({ block: "center", inline: "center" });
      el.click();
      return "ok";
    }
    return "invalid";
    """#
}
