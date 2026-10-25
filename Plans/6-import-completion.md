# Phase 6 — Remaining switching work

Status: reporting unit implemented with generated fixtures; native report QA
remains before release. Session/pinned-tabs and Firefox password units are
implemented with generated fixtures and verified by automated tests only;
native QA, real-Firefox byte-compatibility confirmation, and release remain
open. Extend the existing importer,
preview, Keychain, and profile mapping; never replace them or read real user
source profiles for development tests.

Installed-browser discovery uses account-home source hints rather than the
sandbox process home. Generated paths cover all 11 source roots and a missing
account-directory fallback. Looking up this path does not grant access;
profile reads still require the explicit security-scoped folder permission.
Native folder selection and login continuity remain user QA before release.

## Ordered units

1. Per-item reporting first: structured category/result/reason records for
   accepted, duplicate, unsupported, and failed items. Counts come from actual
   parsing/writes. Reports contain no cookie values, password values, raw SQL
   errors, or unnecessary usernames/URLs. Preserve the no-key/no-write gate.
2. Session/pinned tabs: bounded generated Firefox recovery and Safari plist
   fixtures, explicit preview selection, mapped destination profiles, and
   idempotent re-import. Never restore private sessions. Malformed/compressed
   data fails before writes. Chromium SNSS remains separately scoped and
   explicitly unsupported until its parser is verified.
3. Firefox passwords: research the applicable NSS/key4/logins versions against
   primary documentation and fixtures before implementing crypto. Use the
   existing platform crypto boundary; no home-grown cipher primitives.
   Distinguish unsupported/corrupt/protected sources honestly. Never guess a
   primary password or infer protection solely from generic decryption failure.
   Keychain storage follows explicit preview confirmation; presence checks
   remain attributes-only and Settings never decrypts secrets.

## Unit 3 research notes — Firefox password formats (2026-10-04)

Primary sources consulted before implementing (Mozilla first):

- Mozilla Support KB "Use a Primary Password to protect stored logins and
  passwords" (primary, user-facing): Firefox stores saved logins in two files
  in the profile folder — `logins.json` (encrypted usernames and passwords)
  and `key4.db` (the encryption key). The crypto provider is NSS. Setting a
  Primary Password encrypts the key in `key4.db`; without one, the two files
  together suffice to read the logins.
- Firefox Source Docs, NSS index (primary): NSS is the library behind
  PKCS #5 / PKCS #11 / PKCS #12 support used for the wrapping above.
- De-facto layout reference for the ASN.1/DER shapes (third-party,
  cross-checked against the NSS PBE OIDs, not a Mozilla publication):
  `key4.db` is SQLite with a `metadata` table (`id='password'` row holds
  `item1` password-check and `item2` wrapped secret) and an `nssPrivate`
  table holding the bulk key; `logins.json` holds base64 DER blobs per field
  shaped `SEQUENCE { keyID, SEQUENCE { cipherOID, iv }, ciphertext }` with
  the `f800…0001` key ID. Two mechanisms are documented: PBE with SHA-1 and
  Triple-DES-CBC (OID 1.2.840.113549.1.12.5.1.3), unwrapped by hashing
  `SHA1(globalSalt || password || entrySalt)` through an HMAC-SHA1 chain
  for the 3DES key/IV; and PBES2 (OID 1.2.840.113549.1.5.13) with
  PBKDF2-HMAC-SHA256 (OID 1.2.840.113549.1.5.12, 32-byte key) and
  AES-256-CBC (OID 2.16.840.1.101.3.4.1.42), where the password input is
  itself `SHA1(globalSalt || password)` and the 16-byte IV is `04 0E`
  followed by the stored 14 bytes. The bulk key is 32 bytes for the 3DES
  era (first 24 used) and 48 for the AES era (first 32 used); the field
  cipher follows the key length.

Decisions, enforced by tests on generated fixtures only (no real user profile
was ever read):

- Both documented mechanisms above decrypt, with CommonCrypto and no
  home-grown primitives. Any other OID or blob shape is classified
  `unsupported`, never guessed at.
- `key3.db` (Berkeley DB, pre-58 profiles) is classified `unsupported`.
- Primary-password detection uses NSS's own password-check item with the
  empty password (the defined unprotected path — trying it is not guessing a
  password). A check mismatch is reported as primary-password-protected.
  Generic decryption failures are reported as corrupt/failed, never as
  "protected": protection is only claimed on the check signal.
- Real-Firefox byte compatibility of the decrypt path is UNVERIFIED (it was
  verified only against fixtures generated to the documented layout, for both
  mechanisms), while the protected/unsupported/corrupt/missing
  classifications are fully tested. Reports contain ordinals only — no hosts,
  usernames, or secrets.

## Unit 2 research notes — session formats (2026-10-04)

- Firefox `sessionstore-backups/recovery.jsonlz4`: 8-byte magic `mozLz40\0`,
  then the uncompressed size as little-endian UInt32, then one raw LZ4 block
  (the layout `SessionStoreUtils` writes). Decoded with the system
  Compression framework (`COMPRESSION_LZ4`), size-capped before allocating.
  JSON: `windows[].tabs[]` with `entries[{url,title}]`, 1-based `index` into
  the selected entry, and `pinned`. Private windows are never written to
  recovery files by Firefox; parsing additionally keeps http(s) URLs only.
- Safari `LastSession.plist`: property list with `SessionWindows[]`, each with
  `Tabs[]` holding `URLString`/`Title` (the subset Browsemium reads; unknown
  keys are ignored). Window/tab/entry counts are bounded; anything beyond the
  bounds fails closed before any write.

## Reliability and tests

All units reuse source containment/link checks at preview and apply. Extend
WAL handling toward a consistent read snapshot; path validation alone is not
a concurrent filesystem-swap defense. Use synthetic fixtures for versions,
corruption, oversized input, profile mapping, no-key/no-write, partial failures,
duplicate re-import, and secret-free reports. Verify red → green → reverted-red
for each defect; run a full workstream suite before any coverage claim.

## Gates kept separate

Developer ID/notarization still needs credentials. The 20% memory gate still
needs a quiet machine and the unchanged measurement method. No sync, account,
telemetry, OpenUI scaffold, Chromium edition work, or comparative claim is
authorized by this plan. Any real-profile sign-in continuity check belongs to
the user, not the executor.
