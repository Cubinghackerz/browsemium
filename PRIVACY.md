# Browsemium Privacy

Browsemium has no product account, telemetry, advertising identifier, or cloud
sync. Browsing history, bookmarks, sessions, permissions, profiles, extension
settings are stored locally. AI conversations are saved locally only when
conversation persistence is enabled, and never from private windows. Passwords and optional AI
provider keys are stored in macOS Keychain.

Websites still receive ordinary browser network traffic. Search queries go to
the search provider the user selects. Enabled extensions can access only the
permissions the user approves and are never loaded into private windows.

AI is user-directed. Automatic page context is limited to sanitized page
metadata and bounded readable text when enabled. Screenshots, selections, and
files are attached only when the user explicitly chooses them and are shown for
review in the native API flow before sending. In provider-website mode, page
context is prepared when the user sends through the provider's composer;
there is no separate native review sheet for that path. Page text and selected
files can contain sensitive information; URL sanitization is not a general
secret-redaction service. Private-window and locked-space pages are excluded
from Browsemium page-context capture. Cloud-provider requests go directly to the selected
provider under that provider's privacy terms; Ollama can run locally.

Browsemium does not collect or remotely transmit diagnostics. macOS and WebKit
may maintain system data required to render sites, enforce security, and store
WebCrypto keys. Profile deletion requests removal of the profile's database,
Keychain secrets, and persistent WebKit website-data store. Storage or permission
failures can leave data behind, and deletion is not secure erasure or deletion
of backups. Locked spaces are an interface/access gate, not encryption of local
history or session metadata.
