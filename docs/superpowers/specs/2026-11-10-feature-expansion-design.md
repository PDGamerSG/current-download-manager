# Current feature expansion

The user's continuing objective is a macOS application covering IDM's main workflows, with working Chrome and Firefox integration. This extends the existing original implementation and public repository.

## Evidence and scope

Official feature descriptions and the usage, options, scheduler, queue, and complete Grabber manuals were read on 2026-11-10 local time. The detailed source inventory and remaining gaps belong in `docs/reference/idm-functionality.md`. Features must be marked implemented only after observable behavior is exercised.

Version 0.2.0 will add four complete paths:

1. Saved website projects, same-origin static offline HTML/CSS/resource capture, relative-link rewriting, project status/cancellation, and periodic runs. Retain previous snapshots; never overwrite unrelated destination files. Bound depth, file counts, per-resource bytes, and total bytes. Do not execute website JavaScript during discovery.
2. Periodic HTTP queue synchronization using server validators, exclusively reserved version filenames, preserved old content on failure, and persisted timing. The parent download points to each newly verified version; earlier files remain. This avoids a check-then-replace filesystem race and deliberately differs from IDM's in-place replacement. The first check downloads a version to establish validators. Extend schedules with selected weekdays. Preserve manual pauses and the existing media/file bandwidth and shutdown invariants.
3. Browser automatic-capture file-type filters, URL/domain exceptions, trusted Alt-click bypass, and browser User-Agent handoff. Manual requests remain explicit. Preserve GET evidence, cookie scope, native-ACK-before-cancellation, and browser-copy fallback.
4. Custom category destinations and server-specific connection caps, plus editable download descriptions and configurable quota-window length. Settings and queued jobs must remain readable from older state files.

## Ownership and integration

`DownloadService` remains the owner of ordinary transfers and queue policy. A separate `WebsiteProjectManager` actor owns website-project state and cancellable workers; its command dispatch is exposed through the existing authenticated bridge. Project commands are not exposed to website content scripts.

`NetworkPolicy.swift` owns site matching and validated per-server settings. `Models.swift` adds only backward-compatible optional fields. Browser policy stays in the extension's private local storage and uses privileged extension-page messages.

## Boundaries

Keep original branding, private state, exact native-host identities, destination ownership checks, scoped credentials, and loopback authentication. Do not add dependencies or automatic execution of downloaded code. Windows dial-up hooks, IE cache integration, legacy MMS, DRM, Safari signing, extension-store accounts, and Apple notarization are separate compatibility or account-dependent items, not silently claimed as supported.

## Acceptance

Use deterministic real HTTP fixtures for changed/unchanged resources, failed updates, offline asset/link resolution, cancellation, restart, and replaced-file preservation. Exercise both generated extension workers with policy regressions and both actual browsers. Build the native UI and packaged app. Run the complete existing gate plus new subsystem checks before publishing 0.2.0.
