# Testing Current

Acceptance tests use real engines and local HTTP/FTP/SFTP fixtures. Output is checked against independent file bytes or decoded media frames. Browser suites load the actual extension and execute the native messaging host; Node API fixtures additionally cover failure paths.

## Commands

```sh
scripts/test.sh
# Optional dependencies from requirements-test.txt and Playwright browsers:
scripts/test.sh --protocols --browsers
```

The script builds the native app, CLI and dependency-free Swift checks; regenerates both extension packages; runs Node, HTTP, regression, network-policy, feature configuration, synchronization, offline-project, media/grabber and media-service checks. `--protocols` adds real FTP/SFTP. Optional `--cross-volume` creates and detaches a temporary APFS disk image to exercise media copying across filesystems. `--browsers` adds sequential live Chromium/Firefox suites. Each Python harness owns its subprocesses and temporary directory. Browser tests restore any existing per-user native manifests in `finally`; their manifest edits must not overlap.

For a packaged CLI:

```sh
CURRENT_BROWSER_HEADLESS=1 CURRENT_TEST_CLI="$PWD/dist/Current.app/Contents/MacOS/currentctl" scripts/test.sh --protocols --browsers
```

Development tools still generate the test fixtures. To test the packaged tools themselves, put `Current.app/Contents/Resources/bin` first in PATH and inspect running executable paths and `otool -L` output; the app bundle contains the runtime dependencies. `CURRENT_ARIA2C`, `CURRENT_YT_DLP`, `CURRENT_FFMPEG` and `CURRENT_FFPROBE` can explicitly override tool selection for development.

## Coverage

| Suite | What it proves |
| --- | --- |
| `tests/fixture_test.py` | Real loopback HTTP startup and complete payload delivery with reverse DNS disabled |
| `CurrentCoreTests` | URL/header/filename/number validation, native framing, categories, schedules and export redaction |
| `tests/schedule_main.swift` | Selected weekdays, inclusive start/exclusive end, overnight start-day semantics, first-start boundary and all-day selected windows |
| `tests/integration.py` | Segmented HTTP, retries, disconnects, auth/cookies/referer, proxy, queue/schedule policy, limits/quota, checksums, refresh, persistence, batches, category, scanner, native framing and bridge isolation |
| `tests/regressions.py` | Atomic failed batches, changed-destination preservation, generation-safe completion, no hidden Metalink transfers, host-bound cookies, oversized numeric rejection, deletion ownership, scanner-time replacement and unrelated sidecar preservation |
| `tests/features_v02.py` | Actual custom category destination, settings validation/round trips, description restart, configured quota reset, website-project capture/persistence/delete through the service bridge |
| `tests/network_policy.py` | Old settings/category decode, hostname matching, most-specific and mirror caps, invalid rules, live aria2 changeOption, default/manual/browser UA, proxy option and persisted settings |
| `tests/synchronization.py` | Real ETag/Last-Modified/unsupported HEAD, Vary UA/encoding, unchanged/changed bytes, retained versions, failed/replaced destination, quota/scanner, active pause, move/interval edits, exact-origin credentials, restart and an actual 60-second automatic check |
| `tests/run_website_projects.py` | Real HTML/CSS/resources, exact bytes, rewrite/CSP, navigation depth, auth/redirect isolation, immutable snapshots, failed output retention, file/byte/time limits, directory replacement/symlinks, cancellation, persistence, scheduled first run and an actual periodic repeat |
| `tests/extension.test.mjs` | Both generated workers, cookie/referer/UA scope, sender restrictions, GET/POST correlation, ACK-before-cancel/fallback, discovery, capture rule validation, policy races, trusted bypass and cleanup |
| `tests/browser-e2e.mjs` | Actual Chromium identity/native host, popup/options controls, browser/native file bytes, takeover/cancellation, HttpOnly cookies/referer/UA, type/domain/URL exceptions, trusted/synthetic Alt-click, POST and media discovery |
| `tests/firefox-e2e.mjs` | Actual Firefox identity/native host, popup/options controls, byte-verified browser/native files, HttpOnly cookies/referer/UA, type/domain/URL exceptions, trusted/synthetic Alt-click, POST and media discovery |
| `tests/run_media.py` | Bounded/isolated crawler, actual HLS/DASH and FFmpeg merge, private config, progress, literal filenames, cancellation, stubborn descendants, completion races and bounded await timeout |
| `tests/media_service.py` | Immediate media resume, aggregate mixed-worker rate allocation, serialized replacements, shutdown/restart and complete decoded frame SHA-256 |
| `tests/cross_volume.py` | Exclusive media publication and safe deletion on a separate mounted APFS image, with decoded frame verification |
| `tests/protocols.py` | Actual authenticated FTP and SFTP file transfers with pause/resume and independent SHA-256 |

Swift tests use an executable target because this Command Line Tools installation lacks usable XCTest/Swift Testing modules. They do not require Xcode test discovery. `--build-system native` works around a build-system issue on the tested CLT version; newer SwiftPM may emit a deprecation notice for that option.

## Recorded environment and boundaries

The 0.2.0 release was verified with these passing checks:

| Suite | Result |
| --- | --- |
| Core and weekday schedules | 39 core + 10 weekday assertions |
| Extension behavior | 83 tests across both generated packages |
| HTTP fixture, acceptance and regressions | 1 fixture test + 16 acceptance groups + 9 regression groups |
| New feature configuration and network policy | 7 integration tests + 118 policy assertions |
| File synchronization | 12 integration tests, including a real 60-second automatic check |
| Offline website projects | 61 assertions, including a real 60-second repeat across restart |
| Media/grabber and worker lifecycle | 81 + 4 process-tree + 1 timeout assertions |
| Mixed file/media service | 6 integration groups |
| FTP/SFTP | 2 authenticated transfer groups |
| APFS cross-volume publication/deletion | Independent decoded-frame integrity and exclusive-copy checks |
| Live browser integration | 13 Chromium + 13 Firefox groups with the packaged CLI |

Release testing uses Apple silicon, macOS 27.0.1, Swift 6.4, aria2 1.37.0, FFmpeg 9.0.2 and yt-dlp 2026.10.26. Chromium is 158.0.8127.18 and the automated Firefox build is 159.0. The packaged `scripts/test.sh --protocols --cross-volume --browsers` run passed every suite before the browsers; the two browser suites then passed individually after test-harness fixes. `CURRENT_TEST_CLI` and explicit aria2/yt-dlp/FFmpeg/ffprobe overrides pointed into the app. The final browser runs were headless with isolated profiles. The app signature, archive checksums, and byte-for-byte equality of the generated, bundled and zipped extensions were also verified.

The earlier 0.1.1 baseline additionally verified a real public HTTPS download against an independent TLS client's 22,434-byte payload and SHA-256. It is historical evidence, not a fresh production-site test for every release.

The native window was launched against actual fixture downloads; completed, active and paused states were visually checked, and normal Quit exited without an owned aria2 process. Every sheet compiles and was source-reviewed, but individual UI actions, macOS folder/notification permission prompts and all accessibility interactions have not been exhaustively automated.

The shared preview browser rejected `chrome://extensions` as an unsupported URL. The actual extension acceptance suites therefore use isolated Playwright browser profiles. Firefox automation loads a temporary development add-on through Firefox's supported remote debugging mechanism; it does not prove a signed permanent installation.

The Firefox runner uses Playwright's internal browser-default download mode so Firefox's real download manager preserves server filenames. Intercepted Playwright downloads otherwise replace names with GUIDs, preventing meaningful suffix-filter checks. Retained downloads are verified through the real `browser.downloads` API and disk bytes. The test-only launch override is scoped and restored. Firefox's macOS Alt-click default can suppress navigation independently of the extension, so fixture-owned navigation handlers exercise both trusted bypass and a synthetic event's inability to forge it.

No test claims arbitrary production website compatibility, DRM support, Safari, Windows IDM runtime behavior, Intel, or older macOS release compatibility. Local fixture success is repeatable evidence for the documented behavior, not a guarantee that every remote server or media site permits downloading. Offline capture tests prove the documented static subset; they do not establish rendering equivalence for arbitrary malformed markup, CSS escapes or JavaScript applications. Queue update tests retain earlier versions rather than replacing them in place.

The first hosted macOS 15 build exposed an SDK name-resolution issue in the
media spawn call. Version 0.1.1 uses the compatible Darwin `_np` spelling;
source builds with an older SDK should use 0.1.1 or later instead of the original
0.1.0 tag. The downloaded macOS 27 application passed its packaged test gate.

Hosted macOS also exposed a reverse-DNS stall in Python's HTTP server startup.
The local HTTP and media fixtures now bind numeric loopback addresses without
hostname lookup. A regression check rejects any reverse-DNS call during startup
and verifies a complete HTTP response.

Firefox can deliver its download-created event before the matching GET event.
Version 0.1.1 waits up to one second for positive GET evidence, then checks the
browser download again before capture. Tests cover both browser API variants,
late POST/GET overlap, and downloads completed or paused during that wait.
