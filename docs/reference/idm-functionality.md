# IDM functionality audit

This audit follows the official feature page and manuals read on **10 November 2026**. It describes publicly documented behavior, maps it to Current, and records gaps. It is not a review of IDM source or an assertion of identical behavior. The Windows trial was downloaded, but no Windows/Wine runtime was available; its runtime was not tested. Installer provenance is in [the reference audit](idm-audit.md).

Current uses original Swift/JavaScript code, aria2, yt-dlp and FFmpeg. “Implemented” below identifies an available workflow; the verification column distinguishes real acceptance tests from compiled UI and source review. The current release's complete test results belong in [TESTING.md](../TESTING.md).

## Transfers and recovery

| Documented IDM functionality | Current coverage | Evidence or remaining difference |
| --- | --- | --- |
| Accelerated segmentation, reusing finished connections, tunable connection count [1, 2] | Implemented through aria2, 1–16 requested connections | Range fixture, independent SHA-256 and engine options. IDM's in-half splitting algorithm and advertised speedup are not reproduced or benchmarked. |
| HTTP, HTTPS, FTP and MMS [1] | HTTP/HTTPS/FTP; also SFTP | Real HTTP/FTP/SFTP fixtures. MMS and FTPS are absent. Public HTTPS was separately byte-verified. |
| Automatic retries, interrupted connections, power/network recovery and resume [1, 3] | Persisted file/media jobs, aria2 control files and private media partials | Dropped connections, non-Range fallback, pause/resume, process restart and media process-tree tests. Retry timing is an engine policy, not every IDM retry mode. |
| Resume a source whose address expired [3, 4] | Refresh URL for unfinished jobs | Preserves the owned destination; changing origin clears old headers and credentials. User must ensure it serves the same content. |
| Alternate sources/mirrors [3] | Multiple source URLs per file | Sources share the strictest configured connection cap. No interactive mirror-search service. |
| Batch download naming/ranges [3] | Newline batches and JSON import/export | Batch atomicity, 500 requests/operation, filename collision handling. IDM's numbered range-expression dialog is absent. |
| File properties: source, destination, description, authentication [4] | Inspector, editable descriptions, unfinished-source refresh; add-time destination/credentials | Descriptions persist across restart. Moving/renaming a partial on disk or editing saved credentials in a dedicated properties dialog is not implemented. |
| ZIP contents preview before downloading [1] | Not included | No remote archive directory browser. Downloaded archives can be opened through Finder. |
| Antivirus check and integrity [1, 5] | User-selected executable scanner; quarantine; MD5/SHA-1/SHA-256/SHA-512 | Real scanner, exactly-once and stale-completion tests. Scanner gets one filename argument; arbitrary argument templates are absent. |
| Completion dialog, open file/folder, remember choices [6] | Open file and Reveal in Finder, notifications | Native window smoke and source review. No separate per-download completion dialog or remember-choice matrix. |

## Browser capture and media

| Documented IDM functionality | Current coverage | Evidence or remaining difference |
| --- | --- | --- |
| Browser download takeover and broad browser integration [1, 3, 5] | Chrome/Chromium MV3 and Firefox MV2 extensions with native messaging | Real isolated browsers, actual host executable and byte-verified files. Edge/Brave host manifests exist but those browsers were not separately exercised. No Safari or Windows browser modules. |
| Configurable automatically captured file extensions [3, 5] | Persisted extension capture policy and settings page | Types use the browser filename, falling back to final URL. Empty list allows all types; compound suffixes such as `tar.gz` are supported. |
| Exclude websites or download address patterns [5] | Exact/wildcard domain exclusions and anchored HTTP(S) URL globs | Worker and real-browser cases. Both original and final download URLs are checked. `*.example.org` excludes the base domain and its subdomains. |
| Modifier keys to force or bypass capture [3, 5] | Trusted primary Alt-click bypass | Tab/URL-scoped, short-lived marker; synthetic events cannot set it. Ctrl-to-force and global keyboard hooks are absent. Explicit context-menu/popup download remains available. |
| Browser download dialog: download now/later, edit category/destination [3] | Popup/manual add, opt-in automatic capture, native add sheet | Browser-captured files use Current's queue/category policy; no takeover-time IDM-style dialog. |
| Link, all-page and selection context menus [1, 3] | Implemented | Distinct URL batches and sender restrictions are covered. Browser batch size is 100 links. |
| Media download panel and sharing-site video [1, 3] | Per-video actions, DOM/network discovery, native media worker | Clear HLS/DASH fixtures, FFmpeg merging, full decoded-frame comparison and real-browser discovery. Website support follows yt-dlp and direct resource availability. |
| Video quality/format selection [1] | Partial | The worker selects supported media automatically; an interactive quality/format picker is absent. Some extractors require a separately installed JavaScript runtime. |
| Browser session authentication [1, 5] | Destination-scoped Cookie, Referer and browser User-Agent handoff | Real HttpOnly cookie transfer plus scope checks. No password scraping, POST body replay, private browsing, verified Firefox containers or partitioned-cookie workflow. |
| Prevent browser/native duplicate downloads [3] | Native acceptance precedes browser cancellation; failures fall back to browser | Real handoff plus generated-worker failure tests. POST, unknown method, finished/paused and blob/data transfers remain in the browser. |
| Clipboard monitoring, drag links to main/drop window [1, 3] | Opt-in clipboard offers while app active and native URL drop | Compiled/native smoke. No always-on floating drop target. Dragging completed files to other apps is not separately verified. |

## Organization, queues and schedules

| Documented IDM functionality | Current coverage | Evidence or remaining difference |
| --- | --- | --- |
| Categories with extension/site rules and custom folders [4, 5] | Implemented | Actual downloads verify custom folder routing. Explicit per-download destination wins, then category folder, then default/category-name folder. |
| Multiple queues, simultaneous-file limit, priority/order and start/stop [7, 8] | Global/per-queue concurrency, priorities, enabled state and job movement | Real serial advancement and mixed file/media policy tests. Arbitrary drag reordering is absent. |
| One-time, daily/selected-day start and stop windows [7] | One-time and selected-weekday windows, including overnight | Timed service checks and deterministic weekday boundaries. Overnight belongs to its start day. Current must remain running; no wake or automatic login launch. |
| Periodic synchronization of changed completed files [7, 8] | HTTP(S) queue updates, manual checks, validators and persisted timing | Real changed/unchanged/failure/restart/periodic tests. One source per file; media/FTP/SFTP synchronization is absent. |
| Replace synchronized files [7, 8] | Deliberately uses retained version files | The library row points to the newest verified file. Earlier versions remain. No in-place overwrite. The first check downloads to establish validators; missing HEAD/validators or a configured proxy can require another full transfer. |
| Keep manual stops when the schedule opens [7] | Manual pauses are retained | Queue and update pause/restart coverage. Moving or editing a queue must preserve a manual update pause. |
| Retry failed queue items indefinitely or move failed items last [7] | Partial | aria2 retries transient errors; explicit Retry and priority are available. Infinite queue retry/reordering modes are absent. |
| Completion actions: disconnect, exit, shutdown, run program [7, 13] | Not included | No automatic shutdown, network disconnection or program execution when a queue/project finishes. |
| Limit bytes per configurable time window [5] | File/media transferred-byte quota with configurable seconds | Real quota stop/reset; the retained JSON field `hourlyQuota` names the allowance even with a non-hourly period. Buffered bytes may exceed a threshold slightly. |
| Speed limiter with per-transfer choices [1, 5] | Global and per-job bandwidth limits | Real file partials and mixed media/file allocation; changes serialize media-worker replacements. Website projects use separate fixed safety bounds. |

## Website Grabber

The manuals separate page-exploration filters from downloaded-file filters. Depth counts HTML navigation levels; files linked from the last page still qualify [10, 14]. Current preserves that distinction within a bounded static crawler.

| Documented IDM functionality | Current coverage | Evidence or remaining difference |
| --- | --- | --- |
| Start page, saved named projects and reusable templates [9, 10] | Saved editable website projects, page/site modes | Real persistence through actor and service bridge. Template presets and template export/import are absent. |
| Explore first, select files, then queue/download [10, 11] | “Download files” tab discovers, previews and enqueues checked links | Existing crawler fixture and native UI build. Preview is flat; there is no IDM-style folder/link tree. |
| Download a website for offline browsing; convert local/remote links [10] | Static same-origin offline HTML/CSS/resource snapshots | Rewritten links, CSS imports, CSS URLs, common resource attributes and `srcset` are tested against exact resource bytes. Uncaptured HTTP(S) hyperlinks stay absolute. |
| Preserve original relative folders or group by category [10] | Partial | Selected downloads use native categories. Offline snapshots use collision-resistant resource filenames and rewritten references, not the original directory layout. |
| Site/other-site depth, parent-directory restriction, sibling domains [10, 14] | Same-origin page depth 0–5 and path/full-URL glob filters | Exact scheme/host/port; no cross-origin/subdomain expansion. Directory-only scope can be expressed with filters but has no separate checkbox. |
| Include/exclude page paths, file types/paths and size ranges [10] | Partial | Include patterns select linked HTML navigation; excludes apply to all discovered pages/resources. File-preview extension filter and hard maximum file/byte/time limits exist. Separate minimum-size/type-filter matrix is absent. |
| Detect duplicate content under different locations [10] | Partial | URLs are deduplicated; resource names hash the URL. No IDM-style filename-and-size duplicate grouping or content-addressed deduplication. |
| Authentication/browser login and logout exclusions [10] | Exact-origin request headers through authenticated CLI; ordinary browser-to-file session handoff | Offline project headers remain private. No interactive website login wizard or cookie-jar reuse between separate project/queue engines. |
| Run JavaScript and parse computed links [10, 15] | Not included | Discovery never executes site JavaScript. Saved HTML removes scripts/event handlers, blocks forms/network access with CSP and permits explicitly followed remote hyperlinks. Dynamic applications cannot be mirrored completely. |
| Save/resume/schedule a Grabber project, periodic synchronization [9, 13] | Scheduled first run, periodic new snapshots, cancellation and persisted next run | Actual 60-second repeat across restart and pause coverage. Interrupted captures restart discovery; previous complete snapshots remain. No daily stop window or content-delta optimization for website snapshots. |
| Exploration/download statistics and adjustable concurrency [11, 12] | Per-project state, file count, bytes, run/error times | At most two active projects; assets are fetched serially within each. No per-project concurrency controls or always-on-top statistics window. |
| IE-cache reuse and downloaded-link descriptions [12] | Not included | Windows IE cache has no macOS equivalent. Download descriptions are editable, but link text is not automatically copied into them. |

Offline captures have configurable hard maxima of **500 files, 16 MiB/resource, 128 MiB/capture and 300 seconds**. They are separate from file/media queue proxy, bandwidth, scanner and quota settings. Snapshots have private permissions; their manifest records source/final URLs, potentially including signed queries. Removing a project removes its metadata only. Old snapshots and unsuccessful output attempts are retained for the user to manage. CSS escapes and arbitrary/malformed web syntax are outside the supported scanner subset.

## Networking, interface and platform integration

| Documented IDM functionality | Current coverage | Evidence or remaining difference |
| --- | --- | --- |
| Manual/browser User-Agent [5] | Browser UA handoff; manual file/media setting | aria2 UA/override/reset tests and real browser fixture observations. Offline projects have their own scoped request headers and default UA. |
| Per-server connection rules [5] | Exact/wildcard host caps, strictest cap across mirrors | Real aria2 option and transfer tests. Rules apply to supplied URLs; aria2 does not independently rematch redirect destinations. |
| Proxy/SOCKS, authentication, browser/system/PAC reuse and bypass list [5] | Partial | Explicit HTTP/HTTPS proxy for file transfers. No SOCKS UI, per-protocol proxy matrix, PAC/system/browser-proxy import or bypass list. Proxy is not applied to separate media/project workers. |
| Stored site/path login rules, Basic, NTLM, Negotiate and Kerberos [1, 5] | Per-download Basic/userinfo and cookies | HTTP/FTP/SFTP auth fixtures. No password vault, site-login rule editor, NTLM/Kerberos/Negotiate or interactive SFTP key UI. |
| FTP passive mode and connection timeout controls [2, 5] | Engine defaults | FTP is exercised; passive/active mode and retry/timeout tuning are not exposed in the UI. |
| Sort/search/history and configurable list/toolbar [1, 4] | Native searchable library, categories, inspector and standard toolbar | Native build/smoke. No full arbitrary column/toolbar customization or IDM UI reproduction. |
| Dark mode, skins and multiple languages [1] | Native macOS appearance | No custom skins or translated UI; English only. |
| Startup, notifications and sounds [5] | Permission-based completion notifications | No login-item UI, custom notification sounds, or automatic wake. Actual OS permission dialogs/delivery are not exhaustively automated. |
| Command-line control [3] | `currentctl` JSON commands and add/list/serve | CLI→authenticated bridge→engine→disk acceptance tests. Windows IDM flags are not emulated. |
| Update checker, weekly/manual checks [16] | Public GitHub releases | No automatic update checker, signed updater or migration from IDM settings. |
| Dial-up/VPN phonebook, IE hooks and Windows shutdown [5, 7] | Windows-specific or absent | No macOS equivalent is claimed. |
| Licensing/trial/registration and vendor assets [1] | Independent GPL project | IDM licensing, branding, code, assets and installer are not reproduced or redistributed. |

## Primary sources

1. [Official feature page, including expanded feature blocks](https://www.internetdownloadmanager.com/features2.html)
2. [Dynamic segmentation and performance](https://www.internetdownloadmanager.com/support/segmentation.html)
3. [Starting downloads](https://www.internetdownloadmanager.com/support/using_idm/starting.html)
4. [Main window](https://www.internetdownloadmanager.com/support/using_idm/using_idm.html) and [download properties](https://www.internetdownloadmanager.com/support/using_idm/properties.html)
5. [Options: general, file types, connection, save-to, downloads, proxy, logins and dial-up](https://www.internetdownloadmanager.com/support/using_idm/options.html)
6. [Download completion dialog](https://www.internetdownloadmanager.com/support/using_idm/completeD.html)
7. [Scheduler](https://www.internetdownloadmanager.com/support/idm-scheduler/idm_scheduler.html)
8. [Download and synchronization queues](https://www.internetdownloadmanager.com/support/idm-scheduler/idm_queues.html)
9. [Grabber overview](https://www.internetdownloadmanager.com/support/idm-grabber/idm_grabber.html)
10. [Grabber wizard](https://www.internetdownloadmanager.com/support/idm-grabber/grabber_wizard.html)
11. [Grabber main action dialog](https://www.internetdownloadmanager.com/support/idm-grabber/grabber_main_dialog.html)
12. [Grabber settings](https://www.internetdownloadmanager.com/support/idm-grabber/grabber_settings.html)
13. [Grabber scheduler](https://www.internetdownloadmanager.com/support/idm-grabber/grabber_scheduler.html)
14. [Grabber link levels](https://www.internetdownloadmanager.com/support/idm-grabber/grabber_nlevels.html)
15. [Grabber JavaScript processing](https://www.internetdownloadmanager.com/support/idm-grabber/grabber_prjava.html)
16. [Update checker](https://www.internetdownloadmanager.com/support/using_idm/update.html)
