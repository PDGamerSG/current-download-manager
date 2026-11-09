# Feature coverage

Current implements download workflows from IDM's public feature descriptions as original macOS software. This is a feature comparison, not a claim of complete parity or reproduction of IDM's proprietary implementation. The official Windows installer was downloaded and identified; it could not be executed on this macOS host because Windows/Wine was unavailable. The [reference audit](reference/idm-audit.md) records that boundary; the [manual-by-manual functionality audit](reference/idm-functionality.md) includes the broader coverage and gap inventory.

| Workflow | Current behavior | Verification / limit |
| --- | --- | --- |
| Segmented HTTP/HTTPS | aria2, 1–16 requested connections, mirrors and retries | Real Range fixture, redirects, dropped connections, non-Range fallback, independent SHA-256 |
| Pause/resume and recovery | Persisted jobs and aria2/native-media partials | File restart and immediate media pause/resume; source must support resuming |
| FTP/SFTP | Authenticated aria2 transfers | Local protocol acceptance suite; no FTPS or interactive SSH key-management UI claim |
| Queues, priority, concurrency | Global and per-queue limits; priority ordering | File queue limit and advancement, mixed media/file service tests; schedule/priority policy checks |
| Schedules | One-time and selected-weekday windows, optional end, manual pause retained | Weekday/overnight boundaries and timed service fixtures; service must run, no automatic wake |
| File synchronization | Periodic/manual HTTP(S) checks, validators, retained version files | Real changed/unchanged, failure, ownership, restart and automatic-interval tests. One source per file; first check downloads a baseline; missing validators or configured proxy can require a full transfer |
| Rate limits and quota | Per-job and aggregate file/media budget; configurable transferred-byte quota period | Real partial transfers, quota reset, observed media worker allocation; network buffering can cause short bursts. Website projects have separate bounds |
| Credentials and browser sessions | Basic username/password, cookies/referer, file proxy | Authenticated fixtures and real HttpOnly browser handoff; raw Authorization is rejected; Basic absolute redirects may require refreshed credentials |
| Categories and batch/mirrors | Extension/domain rules, arbitrary category folders, import/export | Real custom-destination routing, collisions, failed-batch atomicity, redacted export checks |
| Server policy and descriptions | Exact/wildcard connection caps, manual/browser UA, editable notes | Real aria2 options/UA, policy persistence, old-state decode and description restart checks; redirected hosts are not independently rematched for caps |
| Destination safety | Reserved file ownership; private media staging and exclusive final publication | Replaced-file and partial-symlink regression tests; externally replaced files fail visibly |
| Checksums, quarantine and scanner | MD5/SHA-1/SHA-256/SHA-512; quarantine attribute; executable scanner hook | Mismatch fixture, scanner exactly once and stale-result regression; scanner is user supplied |
| Media | Direct audio/video plus yt-dlp supported sites, clear HLS/DASH, FFmpeg merge | Generated HLS/DASH, full decoded HLS frames, stream probe, cancel/rate/restart and process-tree checks |
| Website grabber | Static same-origin crawl, preview and selected enqueue | Base/entity/HTML5 links, redirect isolation; depth 3, 50 pages, 500 results, 2 MiB/page |
| Offline website projects | Saved static HTML/CSS/resource snapshots, local-link rewriting, schedules/repeats, cancellation and statistics | Real resources and bytes, security policy, update/failure retention, cancellation/restart, actual repeat and replaced-directory checks. Same-origin only; max depth 5, 500 files, 16 MiB/resource, 128 MiB/capture, 300 seconds |
| Chrome/Chromium extension | MV3 popup, link/page/selection menus, media discovery and opt-in GET takeover | Live Chromium native-host-to-file tests; Edge/Brave register the same host but were not separately launched |
| Firefox extension | MV2 persistent background; same download workflows | Generated Firefox worker behavior tests; live-browser status recorded in TESTING.md; temporary unsigned installation only |
| Browser capture policy | File types, domain/URL exclusions, settings page, trusted Alt-click bypass, browser UA | Worker and both real-browser suites; manual add stays explicit, synthetic bypass events are rejected |
| Native app | Library, inspector, add/settings/queue/category/grabber/browser sheets, import/export, Finder actions | Compiled app and real-download UI smoke; every individual control was not UI-automated |
| Clipboard and notifications | Opt-in link offers while app active; permission-based completion notifications | Compiled/source-reviewed; actual permission/notification delivery is not automated |

## Not included

- IDM's source, exact segmentation algorithm, UI artwork, branding, licensing system or updater.
- Safari Web Extension container or an App Store/Chrome Web Store/Mozilla Add-ons publication.
- DRM access, encrypted-service playback, universal website support, browser password scraping or POST request-body replay.
- NTLM/Kerberos/Negotiate, legacy MMS, a JavaScript-rendering crawler, universal offline website compatibility, or cross-origin website mirroring.
- OS shutdown-after-queue automation, skin packs, translated UI, signed automatic updates or Apple notarization.
- Remote ZIP preview, an interactive media quality picker, SOCKS/PAC/system-proxy import, automatic login launch, or IDM's full properties/template/filter dialogs. See the detailed audit for remaining differences.

Media sites can change, URLs can expire, and servers can refuse range requests. Some yt-dlp extractors additionally require a JavaScript runtime such as Deno; install it separately when the extractor requests it. Capture a new URL from the source page when needed. Firefox containers and partitioned-cookie sessions have not been verified. Simultaneous unfinished file downloads using conflicting sessions for the same host/cookie name are rejected to avoid mixing sessions.

## Architecture and state

SwiftUI and `currentctl` share `CurrentCore`. aria2 is an owned loopback JSON-RPC subprocess with an independent secret. Native messaging forwards a restricted action set to Current's bearer-authenticated loopback bridge; websites get no CORS access. Host/Origin/Fetch Metadata checks and extension sender checks isolate the bridge from website scripts.

State, headers and engine configuration live under a 0700 per-user directory with 0600 files. Exports remove credentials and signed URL queries. Scheduling and quota policy stay in Current, including when an updated cookie jar requires a managed aria2 restart. Cancelled media processes are awaited through final cleanup before a replacement starts.

File updates use exclusively reserved filenames, preserve earlier versions, and recheck both the current and candidate file identities before adopting an update. Failed or cancelled attempts remain on disk for manual inspection; removing a library row does not remove earlier versions. The inspector lists the last 100 previous versions.

Website projects use their own bounded URLSession workers and do not inherit queue proxy, rate, quota or scanner settings. Project headers are scoped to the exact origin. Saved HTML strips executable scripts/event handlers and applies CSP; uncaptured hyperlinks can navigate to the original website after an explicit click. URL manifests may contain private signed queries. Snapshot folders and state generations are retained; deleting project metadata leaves all output intact.

The downloadable app is macOS 27 arm64 because of its bundled libraries. A source deployment target of macOS 13 does not establish older-OS or Intel compatibility.
