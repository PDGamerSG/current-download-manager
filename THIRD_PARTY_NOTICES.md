# Third-party notices

Current is an independent project and is not affiliated with Tonec FZE or Internet Download Manager. No IDM code, installer, branding or artwork is included.

- **aria2 1.37.0**: GPL-2.0-or-later with its OpenSSL exception. https://github.com/aria2/aria2. License and exception are copied into `Current.app/Contents/Resources/Licenses/aria2/` when packaging.
- **FFmpeg / ffprobe**: bundled Homebrew build, GPL-3.0-or-later when built with its enabled GPL dependencies. https://ffmpeg.org. Build information, recipe and licenses are included with the application and accompanying source archive.
- **yt-dlp**: upstream standalone macOS release, Unlicense. https://github.com/yt-dlp/yt-dlp. Its executable includes third-party code under their respective licenses; the exact upstream aggregated `THIRD_PARTY_LICENSES.txt` is included in the app. The corresponding source archive also includes yt-dlp, its embedded GPL mutagen version and MPL certifi version. The standalone binary is independently versioned from Current.
- **Homebrew dylibs**: copied recursively from the build machine. Their original license files and exact Homebrew formulae are included in `Contents/Resources/Licenses/`. `Contents/Resources/build-info.json` lists every bundled formula. The accompanying `Current-third-party-sources.tar.gz` contains verified upstream sources, patches and build recipes for those binaries.
- **Playwright**: Apache-2.0; used only for development acceptance tests, never included in the macOS application.

Current's source is GPL-3.0-or-later. The application's ad hoc signature is for local packaging, and is not an Apple Developer ID signature or notarization.
