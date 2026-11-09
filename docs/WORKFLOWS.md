# Added workflows in Current 0.2

## Keep a downloaded file up to date

1. Add a queue with the **+** beside Queues, or edit an existing queue.
2. Enable **Periodically check completed files** and choose the interval in minutes. Optional schedule windows restrict checks and transfers to selected weekdays/times.
3. Put a file with one HTTP or HTTPS source in that queue. Current checks it after completion while the queue is eligible and has quota available.
4. Select the completed download and use **File updates** in the inspector to check immediately or pause/resume its updates. Previous versions can be revealed in Finder.

The first check downloads a verified version to establish server validators. Later ETag/Last-Modified checks can skip unchanged files. Servers without usable metadata, unsupported HEAD, or a configured proxy may require another full transfer. Updates use the regular file engine, quota, bandwidth, checksum and scanner policies. A pinned checksum continues to apply to updates.

Every successful update has a new filename. The library row points to it; the previous file remains usable. Failed, interrupted or externally replaced files are not silently adopted. Interrupted transfers resume after restart, and manually paused updates stay paused. The inspector retains metadata for the last 100 previous versions. Old versions and failed attempts remain on disk for you to remove when no longer needed.

File updates currently support a single HTTP(S) source. FTP, SFTP, media-worker jobs and mirror batches are excluded. Current must remain open; scheduling does not wake the Mac or launch the app.

## Save a static website for offline reading

1. Open **Downloads → Site grabber… → Offline website projects**.
2. Name the project, enter its starting page, and choose an existing destination folder. The destination path must not pass through symbolic links.
3. Choose a single page or linked pages, depth, optional page/include and URL/exclude patterns, and capture limits.
4. Choose a repeat interval or **Start at** time if needed, then **Save project**.
5. Choose **Run**. On success, **Open website** opens its local entry page; **Show folder** reveals the snapshot.

`*` matches any text in path/full-URL patterns. Include patterns filter linked HTML pages; exclusions apply to both pages and resources. Navigation depth counts HTML links; CSS imports and image/font/media resources remain discoverable at the last page level. Captures remain on the exact source scheme, hostname and port.

Snapshots rewrite supported HTML/CSS references to local resources, remove executable scripts and event handlers, and block forms and automatic network requests with a content security policy. Uncaptured HTTP(S) hyperlinks remain live links after an explicit click. JavaScript applications, third-party assets and unsupported CSS syntax can produce incomplete snapshots.

**Stop** also pauses future scheduled runs; **Run** resumes them. **Remove** deletes project metadata and leaves all snapshot folders. Interrupted captures restart discovery while retaining the last complete snapshot. Each successful repeat creates a new snapshot; there is no automatic old-snapshot deletion.

Projects have independent safety limits: up to two running projects, depth 5, 500 files, 16 MiB/resource, 128 MiB/capture and 300 seconds. They do not inherit file/media queue bandwidth, quota, proxy or scanner settings. Project request headers can be supplied through the authenticated CLI and are scoped to the exact source origin. URL manifests contain source addresses, which may include private signed queries; review them before sharing an offline folder.

## Adjust browser capture

Open the Current popup, enable capture if desired, then choose **Capture settings**. Specify file suffixes, excluded domains and full HTTP(S) URL patterns with `*`. Empty suffixes allow all eligible types. Both initial and redirected URLs are checked.

Hold **Alt/Option** on a real primary click to keep that download in the browser. Popup/context-menu actions still explicitly request native downloads even for excluded addresses. A browser copy is cancelled only after the native app accepts the job. POST, unknown-method and unsupported URL downloads remain in the browser.

See [browser installation and privacy](../extensions/README.md) for Chrome/Firefox instructions and the exact rule syntax.

## Organize and tune downloads

- **Category folder:** Settings → Categories → Edit → custom folder. A per-download destination overrides it.
- **Server connections:** Settings → Network → Add server rule. Exact hostnames match that server; `*.example.org` matches proper subdomains. The most specific rule wins; mirrored downloads use the strictest matching cap. Rules are evaluated against supplied sources, not independently against redirected hosts.
- **User-Agent:** Settings → Network → Manual download User-Agent. A browser or explicit request header takes precedence. Blank restores the engine default. This setting covers file/media transfers; offline projects have their own headers.
- **Quota period:** Settings → Network → Quota per window / Quota window. Enter the allowance in MiB and duration in seconds. For example, 1024 MiB per 14400 seconds allows 1 GiB every four hours.
- **Description:** Select a download, edit Description in the inspector, and choose **Save description**. Descriptions persist privately with download history and are not part of the request-only JSON export.
