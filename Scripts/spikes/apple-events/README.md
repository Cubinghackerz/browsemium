# Apple events spike (throwaway bundle, not Browsemium)

Question: does a sandboxed, ad-hoc-signed app accept incoming Apple events,
including a custom scripting command and a read-only property?

Run it yourself; nothing in the repository's gates builds or launches it.

```sh
cd Scripts/spikes/apple-events
bash run.sh
```

Recorded result (2026-10-05, first run, sdef without the standard suite):
`open location "https://example.com/a"` was delivered to the sandboxed app and
returned its result string. `get tab titles` timed out (-1712). The follow-up
run with the Cocoa standard suite included (the `Throwaway.sdef` here) was not
done, and `xmllint --dtdvalid` reported the first sdef as not validating.
Until the property read works and the dictionary validates, Browsemium ships
no AppleScript. See `Plans/8-landscape-2026.md`.
