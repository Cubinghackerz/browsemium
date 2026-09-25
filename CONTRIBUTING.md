# Contributing

Read `AGENTS.md` and `MEGAPLAN.md` before changing code. Preserve the no-account,
no-telemetry, local-first, and review-before-send guarantees.

Use `project.yml` as the source of truth and regenerate the Xcode project; never
hand-edit the generated project. Before submitting a change, run the headless
checks, the complete Swift package tests, and the Browsemium Xcode scheme tests
documented in `AGENTS.md`. Security-sensitive changes need an abuse-case test.

Do not commit credentials, signing material, production browsing data, or a
third-party filter list whose redistribution license has not been recorded.
Contributions are licensed under Apache-2.0.
