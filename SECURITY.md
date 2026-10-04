# Security Policy

## Supported versions

Security fixes are provided for the latest published Browsemium release. Update
before reporting a problem that is already fixed in a newer release.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's
**Security → Report a vulnerability** flow so extension, browsing-data, and
credential issues can be investigated privately. Include the Browsemium and
macOS versions, exact reproduction steps, and the least-sensitive diagnostic
information needed to reproduce the issue. Never include passwords, API keys,
cookies, browsing history, or private page content.

Maintainers should acknowledge a complete report within seven days, coordinate
disclosure with the reporter, and publish a security advisory when a fix is
available.

## External agent endpoint (opt-in)

Browsemium can listen on `127.0.0.1:47831` for an MCP client, only after you
enable it in Settings. Requests need a bearer token kept in Keychain, a
loopback Host header, and no browser `Origin`. Any local process that has the
token can ask for a task, but it still needs your approval of each grant and
each click or typed value. Other local software that can read your Keychain
item or the clipboard after you copy the token is outside this protection, and
page content a client reads is untrusted and may be forwarded to that client's
model. Reports about bypassing the token, Host/Origin checks, grant limits or
confirmations are in scope.
