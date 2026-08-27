#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/kiririn.xcarchive" >&2
  exit 64
fi

archive_path="${1%/}"
dsym_dir="$archive_path/dSYMs"
sentry_cli="${SENTRY_CLI_BIN:-sentry-cli}"
sentry_org="${SENTRY_ORG:-ci7lus}"
sentry_project="${SENTRY_PROJECT:-kiririn}"

if [[ ! -d "$archive_path" ]]; then
  echo "xcarchive not found: $archive_path" >&2
  exit 66
fi

if [[ ! -d "$dsym_dir" ]]; then
  echo "dSYMs directory not found: $dsym_dir" >&2
  exit 66
fi

if ! command -v "$sentry_cli" >/dev/null 2>&1; then
  echo "sentry-cli not found: $sentry_cli" >&2
  exit 69
fi

dsym_paths=()
while IFS= read -r -d '' dsym_path; do
  dsym_paths+=("$dsym_path")
done < <(find "$dsym_dir" -type d -name '*.dSYM' -prune -print0)

if (( ${#dsym_paths[@]} == 0 )); then
  echo "No dSYM found under: $dsym_dir" >&2
  exit 66
fi

sentry_args=(
  --org "$sentry_org"
  --project "$sentry_project"
)

"$sentry_cli" debug-files upload "${sentry_args[@]}" "${dsym_paths[@]}"
