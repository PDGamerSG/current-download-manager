#!/usr/bin/env python3
"""Archive the exact installed sources/recipes for the binaries in a Current app.

Source selection follows build-info's Cellar paths, never today's formula versions.
File patches are read from a pinned Homebrew commit after matching its patch blocks
against the installed recipe. Cache files not selected for this build are excluded.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import urllib.parse
import urllib.request

HOMEBREW_REVISION = "cc6e2d6b8ebbe15061baf39dea095290298a5b89"


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def blocks(recipe, kind):
    return re.findall(r"(?m)^([ \t]*)" + kind + r"[^\n]* do\n(.*?)^\1end\s*$", recipe, re.S)


def field(text, name):
    match = re.search(r'(?m)^\s*' + name + r'\s+"([^"\n]+)"', text)
    return match.group(1) if match else None


def download(url, target, expected=None):
    if not target.exists() or (expected and sha256(target) != expected):
        request = urllib.request.Request(url, headers={"User-Agent": "Current-source-packaging/0.1"})
        temporary = target.with_suffix(target.suffix + ".download")
        with urllib.request.urlopen(request, timeout=120) as response, open(temporary, "wb") as stream:
            shutil.copyfileobj(response, stream)
        if expected and sha256(temporary) != expected:
            temporary.unlink()
            raise RuntimeError("Source hash mismatch: " + url)
        temporary.replace(target)
    return {"file": target.name, "url": url, "sha256": sha256(target), "upstreamChecksum": expected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, default=Path("dist/Current-third-party-sources.tar.gz"))
    parser.add_argument("--homebrew-revision", default=HOMEBREW_REVISION)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-f0-9]{40}", args.homebrew_revision):
        raise RuntimeError("Pin the Homebrew patch repository to a full Git commit.")
    info = json.loads((args.app / "Contents/Resources/build-info.json").read_text())
    output = Path(".artifacts/third-party-sources")
    output.mkdir(parents=True, exist_ok=True)
    prefixes = {name: Path(path) for name, path in info.get("formulaPrefixes", {}).items()}
    if not prefixes:
        for raw in info["sourceFiles"].values():
            parts = Path(raw).parts
            index = parts.index("Cellar")
            name, version = parts[index+1:index+3]
            prefix = Path(*parts[:index+3])
            if name in prefixes and prefixes[name] != prefix:
                raise RuntimeError("Multiple installed versions must be packaged separately: " + name)
            prefixes[name] = prefix
    if set(prefixes) != set(info["formulae"]):
        raise RuntimeError("Incomplete installed formula provenance.")

    selected = []
    inputs = []
    results = []
    formulae = []
    for name, prefix in sorted(prefixes.items()):
        recipe_path = prefix / ".brew" / (name + ".rb")
        recipe = recipe_path.read_text()
        recipe_target = output / (name + "-" + prefix.name + ".rb")
        shutil.copy2(recipe_path, recipe_target)
        selected.append(recipe_target)
        # The first URL/SHA are the stable source, before livecheck/head/resources.
        url = field(recipe, "url")
        header = recipe[:re.search(r'(?m)^\s*(?:livecheck|head|resource|patch)\b', recipe).start()] if re.search(r'(?m)^\s*(?:livecheck|head|resource|patch)\b', recipe) else recipe
        checksum = field(header, "sha256")
        revision_match = re.search(r'revision:\s*"([a-f0-9]{40})"', header)
        revision = revision_match.group(1) if revision_match else None
        if not url:
            raise RuntimeError("No stable source URL in installed recipe: " + name)
        metadata = {"name": name, "installedVersion": prefix.name, "recipe": recipe_target.name, "recipeSHA256": sha256(recipe_target), "sourceURL": url}
        if url.endswith(".git") or revision:
            if not revision:
                raise RuntimeError("Unpinned Git source: " + name)
            checkout = output / (name + "-checkout-" + revision)
            if not (checkout / ".git").exists():
                subprocess.run(["git", "init", "--quiet", str(checkout)], check=True)
                subprocess.run(["git", "-C", str(checkout), "remote", "add", "origin", url], check=True)
                # Full ancestor history is needed by x264's version.sh.
                subprocess.run(["git", "-C", str(checkout), "fetch", "--quiet", "origin", revision], check=True)
                subprocess.run(["git", "-C", str(checkout), "checkout", "--quiet", "--detach", revision], check=True)
            actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
            if actual != revision:
                raise RuntimeError("Git source revision mismatch: " + name)
            subprocess.run(["git", "-C", str(checkout), "diff", "--exit-code", "HEAD"], check=True)
            target = output / (name + "-" + revision + ".tar.gz")
            with tarfile.open(target, "w:gz") as archive:
                archive.add(checkout, arcname=name + "-" + revision)
            selected.append(target)
            results.append({"file": target.name, "url": url, "gitRevision": revision, "sha256": sha256(target), "includesGitHistory": True})
            metadata["gitRevision"] = revision
        else:
            if not checksum:
                raise RuntimeError("No source checksum in installed recipe: " + name)
            filename = Path(urllib.parse.urlparse(url).path).name
            inputs.append((url, output / (name + "-" + filename), checksum))
            metadata["sourceSHA256"] = checksum

        patch_blocks = [body for _, body in blocks(recipe, "patch")]
        if any(field(body, "file") for body in patch_blocks):
            path = "Formula/" + name[0] + "/" + name + ".rb"
            # Formulas beginning with 'lib' live in their own bucket.
            if name.startswith("lib"):
                path = "Formula/lib/" + name + ".rb"
            pinned_url = "https://raw.githubusercontent.com/Homebrew/homebrew-core/" + args.homebrew_revision + "/" + path
            with urllib.request.urlopen(pinned_url, timeout=60) as response:
                pinned_recipe = response.read().decode()
            pinned_blocks = [body for _, body in blocks(pinned_recipe, "patch")]
            normalize = lambda items: [re.sub(r"\s+", " ", body).strip() for body in items]
            if normalize(pinned_blocks) != normalize(patch_blocks):
                raise RuntimeError("Pinned Homebrew patch blocks differ from installed " + name + "; select the matching --homebrew-revision.")
            metadata["patchRepositoryRevision"] = args.homebrew_revision
        for index, body in enumerate(patch_blocks):
            patch_url = field(body, "url")
            patch_file = field(body, "file")
            if patch_file:
                patch_url = "https://raw.githubusercontent.com/Homebrew/homebrew-core/" + args.homebrew_revision + "/" + patch_file
            if not patch_url:
                raise RuntimeError("Unrecognized external patch in " + name)
            inputs.append((patch_url, output / (name + "-patch-%d.patch" % index), field(body, "sha256")))
        # Inline patch :DATA content is already preserved in the exact recipe.
        for index, (_, body) in enumerate(blocks(recipe, 'resource "[^"\\n]+"')):
            resource_url, resource_checksum = field(body, "url"), field(body, "sha256")
            if not resource_url or not resource_checksum:
                raise RuntimeError("Unpinned resource in " + name)
            filename = Path(urllib.parse.urlparse(resource_url).path).name
            inputs.append((resource_url, output / (name + "-resource-%d-" % index + filename), resource_checksum))
        formulae.append(metadata)

    def fetch(item):
        url, target, checksum = item
        return target, download(url, target, checksum)
    yt_info = info.get("ytDlp")
    if yt_info:
        version = yt_info["version"]
        source_url = "https://github.com/yt-dlp/yt-dlp/releases/download/" + version + "/yt-dlp.tar.gz"
        with urllib.request.urlopen("https://github.com/yt-dlp/yt-dlp/releases/download/" + version + "/SHA2-256SUMS", timeout=60) as response:
            source_checksum = next(line.split()[0] for line in response.read().decode().splitlines() if line.split()[-1] == "yt-dlp.tar.gz")
        inputs.append((source_url, output / ("yt-dlp-" + version + ".tar.gz"), source_checksum))
        # The standalone executable embeds mutagen (GPL) and certifi (MPL).
        # Accompany it with those exact unmodified source distributions as well.
        for name, dependency_version in yt_info["sourceDependencies"].items():
            with urllib.request.urlopen("https://pypi.org/pypi/" + name + "/" + dependency_version + "/json", timeout=60) as response:
                distribution = next(item for item in json.load(response)["urls"] if item["packagetype"] == "sdist")
            inputs.append((distribution["url"], output / distribution["filename"], distribution["digests"]["sha256"]))
        notice = args.app / "Contents/Resources/Licenses/yt-dlp/THIRD_PARTY_LICENSES.txt"
        notice_target = output / "yt-dlp-THIRD_PARTY_LICENSES.txt"
        shutil.copy2(notice, notice_target)
        selected.append(notice_target)
    with ThreadPoolExecutor(max_workers=4) as pool:
        for target, result in pool.map(fetch, inputs):
            selected.append(target)
            results.append(result)
    manifest = output / "SOURCES.json"
    manifest.write_text(json.dumps({"formulae": formulae, "ytDlp": yt_info, "files": sorted(results, key=lambda item: item["file"])}, indent=2) + "\n")
    readme = output / "README.md"
    readme.write_text("""# Corresponding third-party sources

This archive accompanies Current's bundled aria2, FFmpeg and shared libraries.
SOURCES.json identifies the exact installed binary versions, recipes, upstream
URLs, pinned Git revisions and verified SHA-256 values. Only files selected for
this build are archived. Formula resources and all external/inline patches are
included; Homebrew file patches are pinned to a commit whose patch declarations
match the installed recipe. x264 includes its Git history for version.sh.

To rebuild a library, unpack its source, apply the patches in recipe order, and
follow its recipe's install steps and dependency/build-tool declarations on the
target architecture. The .rb files retain Homebrew's configure/CMake flags. The
Current repository's scripts/bundle-tools.py records how binaries and dylibs are
copied, relinked and signed; scripts/build-app.sh assembles the app. Current's own
source is in this release's public repository and GitHub Source code archives.

Libraries are dynamically linked in Contents/Frameworks. You may modify/rebuild
and replace them, then ad hoc sign your modified app. Licenses and copyright
notices are in the sources and in Current.app/Contents/Resources/Licenses.
yt-dlp's upstream standalone binary is separately supplied under the Unlicense,
with aggregated third-party notices. Its source tarball and exact embedded
mutagen (GPL) and certifi (MPL) source distributions accompany this archive.
The yt-dlp source contains the pinned bundle/requirements and build scripts for
its remaining permissively licensed runtime components.
""")
    selected += [manifest, readme]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(args.output, "w:gz") as archive:
        for file in sorted(selected):
            archive.add(file, arcname="Current-third-party-sources/" + file.name)
    print("Verified %d exact source archives/resources/patches for %d formulae; wrote %s" % (len(results), len(formulae), args.output))


if __name__ == "__main__":
    main()
