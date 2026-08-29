#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: misc/backfill-sentry-releases.sh [options]

Create and finalize Sentry releases for version tags, and associate the
commits between adjacent tags. The default mode is dry-run.

Options:
  --apply                 Apply the changes to Sentry.
  --dry-run               Print commands without changing Sentry (default).
  --tag TAG               Process only TAG. May be specified more than once.
  --legacy-builds LIST    Additional build numbers for one tag, comma-separated.
  -h, --help              Show this help.

Environment:
  SENTRY_AUTH_TOKEN       Sentry auth token for --apply.
  SENTRY_ORG              Sentry organization (default: ci7lus).
  SENTRY_PROJECT          Sentry project (default: kiririn).
  SENTRY_REPOSITORY       Sentry repository name (default: ci7lus/kiririn).
  SENTRY_BUNDLE_ID        Bundle identifier (default: jp.pronama.kiririn).
  SENTRY_CLI_BIN          sentry-cli path (default: sentry-cli).
  SENTRY_LEGACY_BUILD_NUMBERS
                          Additional build numbers for one tag, comma-separated.

The canonical release is <bundle-id>@<marketing-version>. Existing native
release names ending in +<build> are also associated with the same tag when
they are returned by `sentry-cli releases list --raw`.
EOF
}

mode=dry-run
requested_tags=()
configured_builds=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      mode=apply
      shift
      ;;
    --dry-run)
      mode=dry-run
      shift
      ;;
    --tag)
      if [[ $# -lt 2 ]]; then
        echo "--tag requires a tag name" >&2
        exit 64
      fi
      requested_tags+=("$2")
      shift 2
      ;;
    --legacy-builds)
      if [[ $# -lt 2 ]]; then
        echo "--legacy-builds requires a comma-separated list" >&2
        exit 64
      fi
      IFS=',' read -r -a configured_builds <<< "$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -n "${SENTRY_LEGACY_BUILD_NUMBERS:-}" ]]; then
  IFS=',' read -r -a environment_builds <<< "$SENTRY_LEGACY_BUILD_NUMBERS"
  configured_builds+=("${environment_builds[@]}")
fi

sentry_cli="${SENTRY_CLI_BIN:-sentry-cli}"
sentry_org="${SENTRY_ORG:-ci7lus}"
sentry_project="${SENTRY_PROJECT:-kiririn}"
sentry_repository="${SENTRY_REPOSITORY:-ci7lus/kiririn}"
bundle_id="${SENTRY_BUNDLE_ID:-jp.pronama.kiririn}"

if ! command -v git >/dev/null 2>&1; then
  echo "git is required" >&2
  exit 69
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "Run this script from inside the Git repository" >&2
  exit 69
fi

all_tags=()
while IFS= read -r tag; do
  all_tags+=("$tag")
done < <(git tag --list 'v*' --sort=version:refname)

if [[ "${#requested_tags[@]}" -gt 0 ]]; then
  tags=()
  for requested_tag in "${requested_tags[@]}"; do
    duplicate=false
    for tag in "${tags[@]}"; do
      if [[ "$tag" == "$requested_tag" ]]; then
        duplicate=true
        break
      fi
    done
    if [[ "$duplicate" == false ]]; then
      tags+=("$requested_tag")
    fi
  done
else
  tags=("${all_tags[@]}")
fi

if [[ "${#tags[@]}" -eq 0 ]]; then
  echo "No v* tags found" >&2
  exit 0
fi

if [[ "${#configured_builds[@]}" -gt 0 && "${#tags[@]}" -ne 1 ]]; then
  echo "--legacy-builds can only be used when processing exactly one tag" >&2
  exit 64
fi

if ! command -v "$sentry_cli" >/dev/null 2>&1; then
  if [[ "$mode" == apply ]]; then
    echo "sentry-cli is required for --apply: $sentry_cli" >&2
    exit 69
  fi
  echo "Warning: sentry-cli is not available; existing Sentry build variants cannot be discovered." >&2
  sentry_versions=""
else
  if ! sentry_versions="$(
    "$sentry_cli" releases \
      --org "$sentry_org" \
      --project "$sentry_project" \
      list --raw 2>/dev/null
  )"; then
    if [[ "$mode" == apply ]]; then
      echo "Could not list existing Sentry releases. Refusing to apply an incomplete backfill." >&2
      exit 69
    fi
    echo "Warning: existing Sentry releases could not be discovered; configured build numbers only will be used." >&2
    sentry_versions=""
  fi
fi

append_unique_build() {
  local candidate="$1"
  local existing

  if [[ ! "$candidate" =~ ^[0-9]+$ ]]; then
    echo "Invalid build number: $candidate" >&2
    exit 64
  fi

  for existing in "${build_numbers[@]}"; do
    if [[ "$existing" == "$candidate" ]]; then
      return
    fi
  done

  build_numbers+=("$candidate")
}

release_exists() {
  local candidate="$1"
  local sentry_version

  while IFS= read -r sentry_version; do
    if [[ "$sentry_version" == "$candidate" ]]; then
      return 0
    fi
  done <<< "$sentry_versions"

  return 1
}

run_sentry() {
  if [[ "$mode" == dry-run ]]; then
    printf '  DRY-RUN:'
    printf ' %q' "$sentry_cli" releases --org "$sentry_org" --project "$sentry_project" "$@"
    printf '\n'
    return 0
  fi

  "$sentry_cli" releases --org "$sentry_org" --project "$sentry_project" "$@"
}

process_release() {
  local release="$1"
  local commit_spec="$2"

  if release_exists "$release"; then
    echo "  existing Sentry release: $release (skip new)"
  else
    run_sentry new "$release"
  fi
  run_sentry set-commits \
    --commit "${sentry_repository}@${commit_spec}" \
    "$release"
  run_sentry finalize "$release"
}

previous_version_tag() {
  local target="$1"
  local candidate
  local previous=""

  for candidate in "${all_tags[@]}"; do
    if [[ "$candidate" == "$target" ]]; then
      printf '%s' "$previous"
      return 0
    fi
    previous="$candidate"
  done

  return 1
}

for tag in "${tags[@]}"; do
  if ! git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    echo "Tag not found: $tag" >&2
    exit 66
  fi

  if ! previous_tag="$(previous_version_tag "$tag")"; then
    echo "Version tag not found in v* tags: $tag" >&2
    exit 66
  fi

  tag_commit="$(git rev-list -n 1 "$tag")"
  version="$(git show "$tag:kiririn.xcodeproj/project.pbxproj" \
    | sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);/\1/p' \
    | head -n 1)"
  tag_version="${tag#v}"

  if [[ -z "$version" ]]; then
    echo "Could not read MARKETING_VERSION from $tag" >&2
    exit 66
  fi
  if [[ "$tag_version" != "$version" ]]; then
    echo "Tag/version mismatch: $tag contains MARKETING_VERSION=$version" >&2
    exit 65
  fi

  build_number="$(git show "$tag:kiririn.xcodeproj/project.pbxproj" \
    | sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' \
    | head -n 1)"
  if [[ -z "$build_number" ]]; then
    echo "Could not read CURRENT_PROJECT_VERSION from $tag" >&2
    exit 66
  fi

  canonical_release="${bundle_id}@${version}"
  build_numbers=()
  append_unique_build "$build_number"

  for configured_build in "${configured_builds[@]}"; do
    if [[ -n "$configured_build" ]]; then
      append_unique_build "$configured_build"
    fi
  done

  while IFS= read -r sentry_version; do
    if [[ "$sentry_version" != "${canonical_release}+"* ]]; then
      continue
    fi

    legacy_build="${sentry_version#"${canonical_release}"+}"
    if [[ "$legacy_build" =~ ^[0-9]+$ ]]; then
      append_unique_build "$legacy_build"
    fi
  done <<< "$sentry_versions"

  if [[ -n "$previous_tag" ]]; then
    if ! git merge-base --is-ancestor "$previous_tag" "$tag"; then
      echo "Previous version tag $previous_tag is not an ancestor of $tag" >&2
      exit 65
    fi

    previous_commit="$(git rev-list -n 1 "$previous_tag")"
    commit_spec="${previous_commit}..${tag_commit}"
    range_description="${previous_tag}..${tag}"
  else
    root_commit="$(git rev-list --max-parents=0 "$tag" | tail -n 1)"
    commit_spec="${root_commit}..${tag_commit}"
    range_description="root..${tag}"
  fi

  echo "$tag: $canonical_release (commits: $range_description)"
  process_release "$canonical_release" "$commit_spec"

  for build in "${build_numbers[@]}"; do
    legacy_release="${canonical_release}+${build}"
    if [[ "$legacy_release" == "$canonical_release+${build_number}" ]]; then
      echo "  legacy native release: $legacy_release"
    else
      echo "  detected native release: $legacy_release"
    fi
    process_release "$legacy_release" "$commit_spec"
  done
done

if [[ "$mode" == dry-run ]]; then
  echo "Dry-run complete. Use --apply after reviewing the commands above."
else
  echo "Sentry release backfill complete."
fi
