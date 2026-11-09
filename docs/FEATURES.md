# Feature coverage

Current implements the main download workflows from IDM's public feature descriptions as original macOS software. This is a feature comparison, not a claim to reproduce IDM's proprietary implementation. The official Windows installer was downloaded and identified; it could not be executed on this macOS host because Windows/Wine was unavailable. The [reference audit](reference/idm-audit.md) records that boundary.

| Workflow | Current behavior | Verification / limit |
| --- | --- | --- |
| Segmented HTTP/HTTPS | aria2, 1–16 requested connections, mirrors and retries | Real Range fixture, redirects, dropped connections, non-Range fallback, independent SHA-256 |
| Pause/resume and recovery | Persisted jobs and aria2/native-media partials | File restart and immediate media pause/resume; source must support resuming |
| FTP/SFTP | Authenticated aria2 transfers | Local protocol acceptance suite; no FTPS or interactive SSH key-management UI claim |
| Queues, priority, concurrency | Global and per-queue limits; priority ordering | File queue limit and advancement, mixed media/file service tests; schedule/priority policy checks |
| Schedules | One-time/daily windows, optional end, manual pause retained | Boundary and overnight policy checks, timed service fixture; service must run, no automatic wake |
| Rate limits and quota | Per-job and aggregate file/media budget; hourly transferred-byte quota | Real partial transfers, observed media worker rate settings, mixed-worker replacements; network buffering can cause short bursts |
| Credentials and browser sessions | Basic username/password, cookies/referer, file proxy | Authenticated fixtures and real HttpOnly browser handoff; raw Authorization is rejected; Basic absolute redirects may require refreshed credentials |
| Categories and batch/mirrors | Extension/domain rules, custom folders, import/export | Category routing, collisions, failed-batch atomicity, redacted export checks |
| Destination safety | Reserved file ownership; private media staging and exclusive final publication | Replaced-file and partial-symlink regression tests; externally replaced files fail visibly |
| Checksums, quarantine and scanner | MD5/SHA-1/SHA-256/SHA-512; quarantine attribute; executable scanner hook | Mismatch fixture, scanner exactly once and stale-result regression; scanner is user supplied |
| Media | Direct audio/video plus yt-dlp supported sites, clear HLS/DASH, FFmpeg merge | Generated HLS/DASH, full decoded HLS frames, stream probe, cancel/rate/restart and process-tree checks |
| Website grabber | Static same-origin crawl, preview and selected enqueue | Base/entity/HTML5 links, redirect isolation; depth 3, 50 pages, 500 results, 2 MiB/page |
| Chrome/Chromium extension | MV3 popup, link/page/selection menus, media discovery and opt-in GET takeover | Live Chromium native-host-to-file tests; Edge/Brave register the same host but were not separately launched |
| Firefox extension | MV2 persistent background; same download workflows | Generated Firefox worker behavior tests; live-browser status recorded in TESTING.md; temporary unsigned installation only |
| Native app | Library, inspector, add/settings/queue/category/grabber/browser sheets, import/export, Finder actions | Compiled app and real-download UI smoke; every individual control was not UI-automated |
| Clipboard and notifications | Opt-in link offers while app active; permission-based completion notifications | Compiled/source-reviewed; actual permission/notification delivery is not automated |

## Not included

- IDM's source, exact segmentation algorithm, UI artwork, branding, licensing system or updater.
- Safari Web Extension container or an App Store/Chrome Web Store/Mozilla Add-ons publication.
- DRM access, encrypted-service playback, universal website support, browser password scraping or POST request-body replay.
- NTLM/Kerberos/Negotiate, legacy MMS, a JavaScript-rendering crawler, complete offline page mirroring/link rewriting, or periodic synchronization.
- OS shutdown-after-queue automation, skin packs, translated UI, signed automatic updates or Apple notarization.

Media sites can change, URLs can expire, and servers can refuse range requests. Some yt-dlp extractors additionally require a JavaScript runtime such as Deno; install it separately when the extractor requests it. Capture a new URL from the source page when needed. Firefox containers and partitioned-cookie sessions have not been verified. Simultaneous unfinished file downloads using conflicting sessions for the same host/cookie name are rejected to avoid mixing sessions.

## Architecture and state

SwiftUI and `currentctl` share `CurrentCore`. aria2 is an owned loopback JSON-RPC subprocess with an independent secret. Native messaging forwards a restricted action set to Current's bearer-authenticated loopback bridge; websites get no CORS access. Host/Origin/Fetch Metadata checks and extension sender checks isolate the bridge from website scripts.

State, headers and engine configuration live under a 0700 per-user directory with 0600 files. Exports remove credentials and signed URL queries. Scheduling and quota policy stay in Current, including when an updated cookie jar requires a managed aria2 restart. Cancelled media processes are awaited through final cleanup before a replacement starts.

The downloadable app is macOS 27 arm64 because of its bundled libraries. A source deployment target of macOS 13 does not establish older-OS or Intel compatibility.
