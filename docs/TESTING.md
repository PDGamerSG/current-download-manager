# Testing Current

Acceptance tests use real engines and local HTTP/FTP/SFTP fixtures. Output is checked against independent file bytes or decoded media frames. Browser suites load the actual extension and execute the native messaging host; Node API fixtures additionally cover failure paths.

## Commands

```sh
scripts/test.sh
# Optional dependencies from requirements-test.txt and Playwright browsers:
scripts/test.sh --protocols --browsers
```

The script builds the native app, CLI and dependency-free Swift checks; regenerates both extension packages; runs Node, HTTP, regression, standalone media/grabber and media-service checks. `--protocols` adds real FTP/SFTP. Optional `--cross-volume` creates and detaches a temporary APFS disk image to exercise media copying across filesystems. `--browsers` adds sequential live Chromium/Firefox suites. Each Python harness owns its subprocesses and temporary directory. Browser tests restore any existing per-user native manifests in `finally`; their manifest edits must not overlap.

For a packaged CLI:

```sh
CURRENT_TEST_CLI="$PWD/dist/Current.app/Contents/MacOS/currentctl" scripts/test.sh --protocols --browsers
```

Development tools still generate the test fixtures. To test the packaged tools themselves, put `Current.app/Contents/Resources/bin` first in PATH and inspect running executable paths and `otool -L` output; the app bundle contains the runtime dependencies. `CURRENT_ARIA2C`, `CURRENT_YT_DLP`, `CURRENT_FFMPEG` and `CURRENT_FFPROBE` can explicitly override tool selection for development.

## Coverage

| Suite | What it proves |
| --- | --- |
| `CurrentCoreTests` | URL/header/filename/number validation, native framing, categories, schedules and export redaction |
| `tests/integration.py` | Segmented HTTP, retries, disconnects, auth/cookies/referer, proxy, queue/schedule policy, limits/quota, checksums, refresh, persistence, batches, category, scanner, native framing and bridge isolation |
| `tests/regressions.py` | Atomic failed batches, changed-destination preservation, generation-safe completion, no hidden Metalink transfers, host-bound cookies, oversized numeric rejection, deletion ownership, scanner-time replacement and unrelated sidecar preservation |
| `tests/extension.test.mjs` | Both generated workers, destination cookie scope, referer policy, trusted sender restrictions, GET/POST correlation, ACK-before-cancel, native failure fallback, discovery and cleanup |
| `tests/browser-e2e.mjs` | Actual Chromium extension ID, native status, popup-to-file, browser takeover/cancellation, HttpOnly cookie/referer handoff and media discovery |
| `tests/firefox-e2e.mjs` | Actual Firefox development extension, native host and download behavior; see recorded browser outcome below |
| `tests/run_media.py` | Bounded/isolated crawler, actual HLS/DASH and FFmpeg merge, private config, progress, literal filenames, cancellation, stubborn descendants, completion races and bounded await timeout |
| `tests/media_service.py` | Immediate media resume, aggregate mixed-worker rate allocation, serialized replacements, shutdown/restart and complete decoded frame SHA-256 |
| `tests/cross_volume.py` | Exclusive media publication and safe deletion on a separate mounted APFS image, with decoded frame verification |
| `tests/protocols.py` | Actual authenticated FTP and SFTP file transfers with pause/resume and independent SHA-256 |

Swift tests use an executable target because this Command Line Tools installation lacks usable XCTest/Swift Testing modules. They do not require Xcode test discovery. `--build-system native` works around a build-system issue on the tested CLT version; newer SwiftPM may emit a deprecation notice for that option.

## Recorded environment and boundaries

The source suite currently reports 39 core assertions, 43 extension behavior tests,
16 HTTP acceptance groups, 9 regression groups, 81 standalone media/grabber
assertions plus 4 process-tree and 1 timeout assertions, 6 media-service groups,
and 2 FTP/SFTP groups, all passing on the recorded environment. A real public
HTTPS download also matched an independent TLS client's 22,434-byte payload and
SHA-256. Chromium passed all 6 live extension groups, including HttpOnly cookies.
Firefox also passed all 6 live groups through a real temporary extension and native host, including authenticated transfers and browser-copy removal. Both browser suites passed with the packaged CLI. The packaged native app also completed/paused/ran fixture jobs and quit with no owned engine remaining. Cross-volume media commit and deletion passed on a temporary mounted APFS image with full decoded-frame verification. Final packaged-app counts are recorded in the release notes.

Release testing is performed on Apple silicon, macOS 27.0.1, Swift 6.4, aria2 1.37.0, FFmpeg 9.0.2 and yt-dlp 2026.10.26. Chromium is 158.0.8127.18 and the automated Firefox build is 159.0. The final release gate passed `scripts/test.sh --protocols --cross-volume --browsers` with `CURRENT_TEST_CLI` and explicit aria2/yt-dlp/FFmpeg/ffprobe overrides pointing into the packaged app. The release notes record the resulting counts.

The native window was launched against actual fixture downloads; completed, active and paused states were visually checked, and normal Quit exited without an owned aria2 process. Every sheet compiles and was source-reviewed, but individual UI actions, macOS folder/notification permission prompts and all accessibility interactions have not been exhaustively automated.

The shared preview browser rejected `chrome://extensions` as an unsupported URL. The actual extension acceptance suites therefore use isolated Playwright browser profiles. Firefox automation loads a temporary development add-on through Firefox's supported remote debugging mechanism; it does not prove a signed permanent installation.

No test claims arbitrary production website compatibility, DRM support, Safari, Windows IDM runtime behavior, Intel, or older macOS release compatibility. Local fixture success is repeatable evidence for the documented behavior, not a guarantee that every remote server or media site permits downloading.

The first hosted macOS 15 build exposed an SDK name-resolution issue in the
media spawn call. Current main uses the compatible Darwin `_np` spelling;
source builds with an older SDK should use main instead of the original
0.1.0 tag. The downloaded macOS 27 application passed its packaged test gate.
