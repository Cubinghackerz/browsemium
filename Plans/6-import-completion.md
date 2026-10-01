# Phase 6 — Remaining switching work

Status: reporting unit implemented with generated fixtures; native report QA
remains before release. Session and Firefox crypto units are not shipped.
Extend the existing importer,
preview, Keychain, and profile mapping; never replace them or read real user
source profiles for development tests.

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
