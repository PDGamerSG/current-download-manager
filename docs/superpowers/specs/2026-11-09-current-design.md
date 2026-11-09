# Current: macOS download manager

An original, open source macOS application implementing the main publicly documented download workflows of Internet Download Manager. No Tonec code, branding, installer or artwork is redistributed.

## Architecture and alternatives

A native SwiftUI app with an aria2 subprocess is the chosen approach: mature segmented HTTP/HTTPS/FTP/SFTP transfers, recovery and speed limits, with standard macOS controls and no Node runtime in the shipped app. A custom networking engine would duplicate years of range/resume edge cases. A webview app would add a second runtime without improving the download engine. Minimum macOS version: 13.0. Build architecture follows the build machine; release artifacts must name it.

`CurrentCore` owns validated requests, categories, settings, persisted jobs and queues, aria2 lifecycle, scheduling, media subprocesses, and a loopback command server. The app and CLI use that same core. State lives in a private Application Support directory with atomic writes. Tests set `CURRENT_STATE_DIR` to isolated temporary directories. aria2 listens only on loopback with a random RPC secret. The bridge uses a separate random bearer token, restricts methods, rejects unauthenticated commands, and exposes no CORS access to websites.

The browser extension uses the standard native messaging protocol, never embeds a credential and never speaks directly to aria2. Chrome/Edge/Brave use a stable extension key; Firefox has a fixed extension ID. Download handoff acknowledges successful native acceptance before cancelling the browser download. Capture is opt-in. Context menus, selected links, page media discovery, captured response URLs, and session cookies/referer are supported. Only cookies belonging to the requested origin are sent. Safari requires a separately signed Safari Web Extension container and full Xcode, which is absent here; it will be documented without claiming verification.

## Download behavior

Add single URLs or newline-separated batches; validate http, https, ftp and sftp URLs. Support mirrors, safe filenames, category folders and custom category rules. Store browser headers with private file permissions and redact them in exports. Offer pause, resume, cancel, retry, URL refresh, queue assignment, priority, deletion from history, and explicit file deletion. aria2 supplies multiple connections, resumable partials, retry, redirects, authentication, checksums, proxies, per-download and global rate limits. Never overwrite an unrelated existing file.

Queues have independent concurrency and enabled state. Scheduled windows can be one-time or recurring daily, with an optional end time; app/CLI service must be running. Scheduling computes eligibility independently from per-job pause intent so a manually paused job stays paused. Persist jobs and queue policy across restarts. Keep failed jobs visible with actionable error text. Completed files can be opened or revealed in Finder. Batch export strips credentials; import does not execute commands.

Site grabber previews matching resource links from a bounded same-origin crawl before enqueueing selected URLs. Media capture supports direct downloadable audio/video; optional yt-dlp plus ffmpeg handles clear HLS/DASH and supported media websites. Never promise DRM access or universal website support. Optional media tools must be reported as unavailable when absent.

## Native UI

System typography and appearance, blue accent, standard sidebar and toolbar. Sidebar: all downloads, active, paused, completed, failed, categories and queues. Main list: file, progress, size, status, speed. Inspector: source, destination, connections, error and actions. Add sheet: URLs, destination, queue, filename, credentials, checksum, connection count and rate limit. Settings: bandwidth, concurrency, category rules, proxy, browser installation, and opt-in clipboard detection. Queue editor provides scheduling. Grabber previews selectable results. Keyboard shortcuts, drag/drop and accessible button labels are part of the interface.

## Verification and release

Tests must use real aria2 and a local HTTP fixture that implements Range, redirects, authentication, transient failures, and slowly streamed payloads. Assert downloaded bytes against independent fixture hashes. Exercise pause/resume, restart recovery, concurrency, schedules, cookies, proxy, checksum rejection, URL refresh, collision handling, native framing and unauthorized requests. Test extension logic with Node, then exercise the browser-to-native-to-file route in an actual browser where automation supports extension loading. Distinguish tests run from source-reviewed browser variants.

Package an app, CLI and extension archives. Bundle aria2 and its dependent libraries with license notices and source links. Ad hoc signing makes a local build runnable; it is not Apple notarization. Publish the original source in a public GitHub repo under GPL-3.0-or-later, with honest feature/test coverage and build instructions. Keep reference installer and all personal state outside version control.
