# Feature expansion implementation plan

**Goal:** Close documented IDM workflow gaps with working, tested additions to Current 0.2.0.

**Architecture:** Retain CurrentCore/SwiftUI/aria2 and native browser messaging. Add an actor for saved website projects and focused policy helpers. Preserve all current ownership and process lifecycle guarantees.

**Spec:** `docs/superpowers/specs/2026-11-10-feature-expansion-design.md`

## Tasks

- [x] Record official feature/manual sources, concrete requirements, current coverage, and remaining platform-specific gaps in `docs/reference/idm-functionality.md`.
- [x] Record failing settings/category/schedule round-trip checks before adding optional model fields. Existing state must decode with defaults.
- [x] Implement website projects in `Sources/CurrentCore/WebsiteProjects*.swift`, with `WebsiteProjectManager.init(stateDirectory:)`, `start() async throws`, `stop() async`, and `command(_:) async throws -> JSONValue`. Extend `SiteGrabberView.swift`; exercise real resources, rewritten links, cancellation and persistence in dedicated tests.
- [x] Implement browser policy in `extensions/shared`, generated packages, and `tests/extension.test.mjs`. Add privileged policy settings and trusted bypass handling; exercise both real browsers sequentially.
- [x] Implement category directories and site connection policy in `NetworkPolicy.swift`, `Models.swift`, `RPC.swift`, and the native settings/category UI. Test exact/subdomain matching, invalid policy rejection, persisted state, and observed engine options.
- [x] Implement weekday schedules and periodic conditional synchronization through `DownloadService.swift` and focused helpers. Use real validators, independently checked bytes, staging, preserved old destinations on error, ownership checks and cancellation/restart tests.
- [x] Integrate web-project lifecycle/commands into `DownloadService`, add description editing and quota periods, and build all native products.
- [x] Add new checks to `scripts/test.sh`; run focused gates and packaged HTTP/media/protocol/browser/cross-volume suites. Browser harness fixes were verified with individual passing packaged browser runs.
- [x] Pass the [full hosted CI gate](https://github.com/PDGamerSG/current-download-manager/actions/runs/42694525766) for source commit `93b06e8899b620430c673bc64b78d127ca52e983`.
- [x] Update version, documentation and installed app without opening a foreground window; record material remaining gaps explicitly.
- [x] Publish public source and [0.2.0 release](https://github.com/PDGamerSG/current-download-manager/releases/tag/v0.2.0); independently download all five public assets without authentication and verify SHA-256, sizes and the exact public tag.
