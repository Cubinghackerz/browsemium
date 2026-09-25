# Browsemium Privacy

Browsemium has no product account, telemetry, advertising identifier, or cloud
sync. Browsing history, bookmarks, sessions, permissions, profiles, extension
settings, and AI conversations are stored locally. Passwords and optional AI
provider keys are stored in macOS Keychain.

Websites still receive ordinary browser network traffic. Search queries go to
the search provider the user selects. Enabled extensions can access only the
permissions the user approves and are never loaded into private windows.

AI is user-directed. Automatic page context is limited to sanitized page
metadata and bounded readable text when enabled. Screenshots, selections, and
files are attached only when the user explicitly chooses them and are shown for
review before sending. Cloud-provider requests go directly to the selected
provider under that provider's privacy terms; Ollama can run locally.

Browsemium does not collect or remotely transmit diagnostics. macOS and WebKit
may maintain system data required to render sites, enforce security, and store
WebCrypto keys. Deleting a profile removes its Browsemium database, Keychain
secrets, and persistent WebKit website-data store after the browser has released
the store.
