#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/kiririn.xcarchive" >&2
  exit 64
fi

archive_path="${1%/}"
dsym_dir="$archive_path/dSYMs"
dsym_paths=(
  "$dsym_dir/kiririn.app.dSYM"
  "$dsym_dir/VLCKit.framework.dSYM"
)

if [[ ! -d "$archive_path" ]]; then
  echo "xcarchive not found: $archive_path" >&2
  exit 66
fi

if [[ ! -d "$dsym_dir" ]]; then
  echo "dSYMs directory not found: $dsym_dir" >&2
  exit 66
fi

missing_dsyms=()
for dsym_path in "${dsym_paths[@]}"; do
  if [[ ! -d "$dsym_path" ]]; then
    missing_dsyms+=("$dsym_path")
  fi
done

if (( ${#missing_dsyms[@]} > 0 )); then
  printf 'dSYM not found: %s\n' "${missing_dsyms[@]}" >&2
  exit 66
fi

sentry-cli debug-files upload --org ci7lus --project kiririn "${dsym_paths[@]}"
