#!/bin/sh
# Install from an existing local app or CLI. This script never changes browser settings.
set -eu

if [ "$#" -gt 1 ]; then
  printf '%s\n' 'Usage: scripts/install-browser-host.sh [Current.app | /path/to/currentctl]' >&2
  exit 2
fi

if [ "$#" -eq 1 ]; then
  case "$1" in
    *.app|*.app/) current_tool="${1%/}/Contents/MacOS/currentctl" ;;
    *) current_tool="$1" ;;
  esac
elif [ -x /Applications/Current.app/Contents/MacOS/currentctl ]; then
  current_tool=/Applications/Current.app/Contents/MacOS/currentctl
elif [ -x "$HOME/Applications/Current.app/Contents/MacOS/currentctl" ]; then
  current_tool="$HOME/Applications/Current.app/Contents/MacOS/currentctl"
elif command -v currentctl >/dev/null 2>&1; then
  current_tool=$(command -v currentctl)
else
  current_script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
  current_repo_dir=$(dirname -- "$current_script_dir")
  if [ -x "$current_repo_dir/.build/release/currentctl" ]; then
    current_tool="$current_repo_dir/.build/release/currentctl"
  elif [ -x "$current_repo_dir/.build/debug/currentctl" ]; then
    current_tool="$current_repo_dir/.build/debug/currentctl"
  else
    printf '%s\n' 'Cannot find currentctl. Build/install Current first, or pass the path to Current.app.' >&2
    exit 1
  fi
fi

if [ ! -x "$current_tool" ]; then
  printf '%s\n' "Not an executable Current CLI: $current_tool" >&2
  exit 1
fi

# A relative app/CLI path is resolved now so the native host wrapper remains valid.
current_tool_dir=$(CDPATH='' cd -- "$(dirname -- "$current_tool")" && pwd)
current_tool="$current_tool_dir/$(basename -- "$current_tool")"
exec "$current_tool" install-browser-host
