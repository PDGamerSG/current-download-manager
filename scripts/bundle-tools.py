#!/usr/bin/env python3
"""Bundle installed Mach-O tools and their non-system dylibs, preserving licenses."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def dependencies(file):
    lines = run("otool", "-L", str(file)).splitlines()[1:]
    return [line.strip().split(" (", 1)[0] for line in lines]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--yt-dlp", type=Path, required=True)
    parser.add_argument("--yt-dlp-notices", type=Path, required=True)
    args = parser.parse_args()
    contents = args.app / "Contents"
    tools = contents / "Resources/bin"
    frameworks = contents / "Frameworks"
    licenses = contents / "Resources/Licenses"
    for directory in [tools, frameworks, licenses]: directory.mkdir(parents=True, exist_ok=True)
    originals = {}
    destinations = {}
    formulae = {}

    def identify(source):
        parts = source.resolve().parts
        if "Cellar" in parts:
            index = parts.index("Cellar")
            name, version = parts[index+1:index+3]
            formulae[name] = Path(*parts[:index+3])

    def copy(source, destination):
        source = source.resolve()
        if str(source) in originals: return originals[str(source)]
        if destination.name in destinations and destinations[destination.name] != str(source):
            raise RuntimeError("Dylib name collision: " + destination.name)
        shutil.copy2(source, destination); destination.chmod(0o755)
        originals[str(source)] = destination; destinations[destination.name] = str(source)
        identify(source)
        for dependency in dependencies(source):
            if dependency.startswith(("/opt/homebrew/", "/usr/local/")):
                copy(Path(dependency), frameworks / Path(dependency).name)
            elif dependency.startswith("@"):
                # Fail rather than silently ship an unresolved third-party dependency.
                if not dependency.startswith("@rpath/libswift"):
                    raise RuntimeError("Resolve this input dependency before bundling: " + dependency)
        return destination

    for name in ["aria2c", "ffmpeg", "ffprobe"]:
        source = shutil.which(name)
        if not source: raise RuntimeError("Required build tool is missing: " + name)
        copy(Path(source), tools / name)
    if not args.yt_dlp.is_file(): raise RuntimeError("Download the upstream standalone yt-dlp_macos binary first.")
    shutil.copy2(args.yt_dlp,tools / "yt-dlp"); (tools / "yt-dlp").chmod(0o755)
    yt_version = run(str(args.yt_dlp.resolve()), "--version")
    details = subprocess.run([str(args.yt_dlp.resolve()), "--verbose", "--list-impersonate-targets"], text=True, capture_output=True, check=True)
    yt_sources = {}
    for name in ["mutagen", "certifi"]:
        found = re.search(r"\b"+name+r"-([0-9.]+)",details.stdout+details.stderr)
        if not found: raise RuntimeError("Check the standalone yt-dlp source obligations for missing dependency: "+name)
        yt_sources[name] = found.group(1)

    minos = (13, 0)
    for original, destination in originals.items():
        is_library = destination.parent == frameworks
        if is_library: subprocess.run(["install_name_tool", "-id", "@loader_path/"+destination.name, str(destination)], check=True)
        for dependency in dependencies(Path(original)):
            if dependency.startswith(("/opt/homebrew/", "/usr/local/")):
                copied = originals[str(Path(dependency).resolve())]
                replacement = ("@loader_path/" if is_library else "@executable_path/../../Frameworks/") + copied.name
                subprocess.run(["install_name_tool", "-change", dependency, replacement, str(destination)], check=True)
        version = run("vtool", "-show-build", str(destination))
        for number in re.findall(r"minos\s+([\d.]+)", version): minos = max(minos, tuple(map(int, number.split("."))))
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(destination)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    notice_names = re.compile(r"^(licen[sc]e|copying|copyright|authors|notice)", re.I)
    for name, prefix in formulae.items():
        folder = licenses / name; folder.mkdir(exist_ok=True)
        for source in prefix.iterdir():
            if source.is_file() and notice_names.match(source.name): shutil.copy2(source, folder / source.name)
        recipes = prefix / ".brew"
        if recipes.is_dir(): shutil.copytree(recipes, folder / "homebrew", dirs_exist_ok=True)
    # Standalone yt-dlp is Unlicense; its release embeds notices for its dependencies.
    shutil.copy2(Path(__file__).resolve().parents[1] / "THIRD_PARTY_NOTICES.md", licenses / "THIRD_PARTY_NOTICES.md")
    yt_notices = licenses / "yt-dlp"; yt_notices.mkdir(exist_ok=True)
    shutil.copy2(args.yt_dlp_notices,yt_notices / "THIRD_PARTY_LICENSES.txt")
    report = {
        "architecture":run("uname", "-m"), "minimumSystemVersion":".".join(map(str,minos)),
        "formulae":sorted(formulae), "formulaPrefixes":{name:str(prefix) for name,prefix in sorted(formulae.items())}, "libraries":len(originals)-3,
        "bundledTools":["aria2c", "ffmpeg", "ffprobe", "yt-dlp"],
        "ytDlp":{"version":yt_version,"upstreamSHA256":hashlib.sha256(args.yt_dlp.read_bytes()).hexdigest(),"sourceDependencies":yt_sources},
        "sourceFiles":{str(destination.relative_to(contents)):original for original,destination in originals.items()}
    }
    (contents / "Resources/build-info.json").write_text(json.dumps(report, indent=2)+"\n")
    print(json.dumps({k:v for k,v in report.items() if k != "sourceFiles"}, indent=2))


if __name__ == "__main__": main()
