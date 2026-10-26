# Unreleased

Changes on the `migration-seamless-import` branch, not yet released. They make
moving to Browsemium from another browser more complete and more honest about
what did and did not come across.

## Importing

- **Passwords and cookies from Chrome and other Chromium browsers can now
  import.** When you press Import, Browsemium asks first. Only after you press
  Continue does macOS show its own prompt for the browser's "Safe Storage" key,
  once per browser. The key is held in memory for that import and never stored.
  If you decline, passwords and cookies are left out and everything else still
  imports. Nothing reads the key while a preview is built or Settings is open.
- Recent Chrome cookie databases (version 24 and later) prefix each value with a
  host hash. That prefix is now removed instead of being imported as part of
  the cookie.
- SameSite is carried across for Chromium and Firefox cookies. Cookies that are
  already expired, and Firefox container or partitioned cookies, are left out
  and counted, so one container's sign-in cannot land in your default cookies.
- Importing every profile no longer switches your active profile. Importing the
  same source profile again adds to the Browsemium profile it created before,
  instead of making a second one.
- An import never overwrites a password you already saved for the same site and
  username. It is reported as already saved.
- Extension reinstall reports each extension: installed, or why not. A batch
  import asks once at the end. The Chrome Web Store is asked for packages that
  fit the version of the browser you came from.
- Logins saved without a username are counted as left out instead of vanishing.
- A running source browser is flagged before you import, because its files are
  still changing. The copy of its databases is checked for changes while it is
  made, retried, and the import stops with a clear message if it never settles.
- The report says why a default search engine did not come across, and
  Firefox and Safari list that they do not move it.
- The Chromium edition no longer offers cookie import, because it has no way to
  store them yet.

## Corrections

- The 2.2.0 notes said Safari pinned tabs stay pinned. They do not: Firefox pins
  stay pinned, and Safari tabs come across unpinned.

## Still not done

- Chromium open tabs (they need the undocumented session file format).
- Reading Firefox's default search engine, and search engines whose address has
  the query in the middle.
- Safari cookies: the cookie file's location on current macOS has not been
  confirmed on a real Mac.
- Undoing an import.
- Not yet tried against real Chrome, Firefox or Safari profiles: the key prompt,
  the version-24 cookie prefix, and Chrome's search setting. Tests use generated
  fixtures only.
