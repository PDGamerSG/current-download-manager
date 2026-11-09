# Current browser integration

These are local source builds for Current on macOS. There is no Chrome Web Store or Mozilla Add-ons release in this repository. Safari is not included: it requires a separately signed Safari Web Extension container and full Xcode.

Build the generated directories after changing shared source:

```sh
node extensions/build.mjs
node --test tests/extension.test.mjs
```

No npm packages are required. Use Node 20 or later for these development commands; the installed extension and macOS app do not need Node.

## Install the native host

Install/build Current and keep the app in a permanent location. From the repository root:

```sh
scripts/install-browser-host.sh /Applications/Current.app
```

The script also accepts a path to `currentctl`, or finds the installed app/local build if called without an argument. The equivalent command is:

```sh
/Applications/Current.app/Contents/MacOS/currentctl install-browser-host
```

The installer registers `io.current.downloadmanager` for the current macOS user in the standard native messaging folders for Chrome, Chrome Canary, Chrome for Testing, Chromium, Edge, Brave and Firefox. It writes an executable wrapper into Current's private Application Support directory. That wrapper starts the absolute installed `currentctl native-host`; no browser credential or HTTP bridge token is embedded in the extension. Reinstall the native host after moving/removing the app or changing from a development build to the packaged app.

Native messaging directories and the wrapper directory have mode `700`; host manifests have mode `600`. Only these exact extension identities are allowed:

| Browser package | Extension ID |
| --- | --- |
| Chromium | `ljmcdchlnbjjjbeljjlhdinmdcimngmm` |
| Firefox | `current@current-downloadmanager.local` |

The Chromium public key in `build.mjs` fixes the unpacked extension ID. Its private key is not distributed. These local packages do not claim a signed store identity. Native manifests contain exact allowed origins/extensions and no wildcard.

## Chrome, Chromium, Edge and Brave

1. Open the browser's extension manager: `chrome://extensions`, `edge://extensions`, or `brave://extensions`.
2. Enable **Developer mode**.
3. Choose **Load unpacked** and select this repository's **`extensions/chromium`** directory, which contains `manifest.json`.
4. Confirm the displayed ID is `ljmcdchlnbjjjbeljjlhdinmdcimngmm`.
5. Pin Current to the toolbar. Open its popup and confirm **Connected to the macOS app**. Install the native host first if it reports an unavailable connection.

This is a Manifest V3 extension with a classic background service worker and session storage for bounded per-tab media discovery.

## Firefox

1. Open `about:debugging#/runtime/this-firefox`.
2. Choose **Load Temporary Add-on** and select **`extensions/firefox/manifest.json`**.
3. Pin/open Current in the toolbar and confirm the native app connection.

The Firefox package uses Manifest V2 with a persistent classic background script and fixed Gecko ID. This avoids Chromium-only worker/module syntax. Temporary loading ends when Firefox exits. A permanent installation in ordinary Firefox requires Mozilla signing. Developers may follow Mozilla's documented unsigned-extension process in an appropriate Developer Edition/Nightly profile; no preference is changed by these scripts.

## Download workflows

- Paste a network URL or newline-separated batch into the toolbar popup. HTTP, HTTPS, FTP and SFTP are accepted. One request is created per URL so its cookies cannot be reused for another destination.
- Use link, video/audio, selected-links or all-page-links context menus. Batches are bounded to 100 distinct URLs; use the app for larger lists.
- Play media to populate **Media on this page**. Discovery combines video/audio DOM sources and observed audio/video response URLs, HLS `.m3u8` and DASH `.mpd` playlists. Each tab keeps at most 60 unique entries, which are removed on navigation/tab close. Per-video buttons appear when a usable DOM network source exists.
- Use popup controls to pause, resume or cancel recent native jobs. Download progress comes from Current's native status response.

**Capture browser downloads starts off.** Enable it in the popup to capture new eligible HTTP/HTTPS downloads. Current only captures an in-progress, unpaused download whose original and final URLs correlate with recently observed GET requests. It pauses the browser copy, sends a native add request and requires a successful response containing an accepted job ID before cancelling the browser copy. If native acceptance fails, it resumes the paused browser copy. If browser cancellation fails after native acceptance, the browser copy stays paused to avoid running both copies, and an error explains that state.

POST, unknown request methods, redirects originating in POST, blob/data URLs, already paused and finished downloads stay in the browser. If a URL had an overlapping POST request, capture skips it conservatively. Context-menu and manual actions explicitly request a fresh URL download; they do not cancel any existing browser transfer. Native errors appear in the popup, a red toolbar badge and a browser notification. Repeated popup polling does not repeat the same notification.

Browsers can deliver the download-created event before the request-method event.
Current waits up to one second for positive GET evidence without pausing that
transfer. It then checks that the browser download is still active and unpaused
before attempting capture; missing or unsafe evidence leaves it in the browser.

## Cookies, privacy and supported media

For every requested HTTP/HTTPS resource, `cookies.getAll({url})` retrieves destination-scoped cookies. The extension checks cookie domain, host-only flag, path and Secure scope again before building that URL's `Cookie` header. It never reads the popup's cookies and never attaches one URL's cookie header to a batch of unrelated URLs. Page referers follow the usual strict-origin-when-cross-origin shape; extension/internal page URLs and HTTPS-to-HTTP referers are omitted. The native app stores sensitive request headers privately and excludes them from browser status responses.

The extension runs on normal HTTP/HTTPS pages, including frames, and requests broad host permission for media discovery and explicit browser integration. It cannot inspect browser-protected pages, and private browsing is disabled. Firefox containers and partitioned-cookie sessions are not claimed as verified; unusual cookie stores or authentication flows may require using the original browser. The extension does not scrape browser passwords or promise replay of POST bodies.

Direct audio/video downloads are supported by the native engine. Clear HLS/DASH and supported media websites need the app's optional `yt-dlp` and `ffmpeg` tools. DRM, encrypted service playback and universal website coverage are not supported. Manifest/segment detection does not decrypt playback. Signed media URLs can expire; refresh them from the original page when necessary.

## Verification

`tests/extension.test.mjs` runs the shared URL/cookie/media/handoff logic and executes the generated Chromium and Firefox background scripts against explicit browser/native API fixtures. It checks GET/POST correlation, native acknowledgement ordering, pause/resume fallback, error reporting, capture opt-in and per-tab cleanup. Generated JavaScript is syntax-checked for both browser packages. These Node fixture checks are separate from real browser tests. `tests/browser-e2e.mjs` exercises Chromium and `tests/firefox-e2e.mjs` exercises Firefox against the real native host and byte-verified local fixture files.

The T3 preview route rejected the browser extension-manager protocol, so real tests use isolated Playwright browsers. Firefox loads the local package temporarily through its supported DevTools add-on actor; its popup DOM controls are driven through that actor because Playwright/Juggler cannot attach to privileged extension pages. See [testing details](../docs/TESTING.md) for recorded checks and limits. These tests back up and restore per-user native host manifests; run them sequentially, not in parallel.

## Protocol for maintainers

The popup/content scripts communicate only with the extension background. The background uses native messaging host `io.current.downloadmanager`, with commands:

```json
{"action":"status"}
{"action":"add","requests":[{"urls":["https://example.org/file.zip"],"headers":{},"kind":"file"}]}
{"action":"pause","id":"native-job-id"}
{"action":"resume","id":"native-job-id"}
{"action":"cancel","id":"native-job-id"}
```

Success is `{ "ok": true, "result": ... }`; failure is `{ "ok": false, "error": "Actionable message" }`. Add returns an array of accepted jobs containing IDs. Status returns an object containing `jobs`; the native host redacts request credentials and cookies. Content scripts cannot invoke job actions or native status. Privileged popup actions require the exact extension ID and extension-page URL; opening the popup page as a browser tab retains those controls. Website requests are not exposed through `externally_connectable`.

Edit `extensions/shared`, then run `node extensions/build.mjs`; the browser-specific directories are generated distributable packages. `BrowserInstaller` in `CurrentCore` must retain the exact IDs recorded above if changing manifests.
