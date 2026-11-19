#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --src DIR --name NAME\n' "$0" >&2
  exit 2
}

src=''
name=''
while (($#)); do
  case "$1" in
    --src) (($# >= 2)) || usage; src=$2; shift 2 ;;
    --name) (($# >= 2)) || usage; name=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$src" && -d "$src" ]] || { printf '::error::Artifact source directory is missing\n' >&2; exit 1; }
[[ -n "$name" && "$name" != . && "$name" != .. && "$name" =~ ^[A-Za-z0-9_.-]+$ && "$name" != *..* ]] || { printf '::error::Invalid artifact name\n' >&2; exit 1; }
root=${CLUSTER_ARTIFACT_ROOT:-}
[[ -n "$root" ]] || { printf '::error::CLUSTER_ARTIFACT_ROOT is not configured\n' >&2; exit 1; }
[[ -d "$root" && -w "$root" ]] || { printf '::error::CLUSTER_ARTIFACT_ROOT is missing or not writable\n' >&2; exit 1; }
root=$(realpath -e -- "$root")
[[ -d "$root" && -w "$root" ]] || { printf '::error::CLUSTER_ARTIFACT_ROOT is missing or not writable\n' >&2; exit 1; }
[[ -z "$(find "$src" -type l -print -quit)" ]] || { printf '::error::Artifact source contains symlinks\n' >&2; exit 1; }
repo=${GITHUB_REPOSITORY:-}
[[ "$repo" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]] || { printf '::error::GITHUB_REPOSITORY is invalid\n' >&2; exit 1; }
owner=${BASH_REMATCH[1]}
repository=${BASH_REMATCH[2]}
[[ "$owner" != *..* && "$repository" != *..* ]] || { printf '::error::GITHUB_REPOSITORY contains an invalid path component\n' >&2; exit 1; }
run_id=${GITHUB_RUN_ID:-}
attempt=${GITHUB_RUN_ATTEMPT:-}
[[ "$run_id" =~ ^[A-Za-z0-9_-]+$ && "$run_id" != *..* ]] || { printf '::error::GITHUB_RUN_ID is invalid\n' >&2; exit 1; }
[[ "$attempt" =~ ^[A-Za-z0-9_-]+$ && "$attempt" != *..* ]] || { printf '::error::GITHUB_RUN_ATTEMPT is invalid\n' >&2; exit 1; }

parent="$root/$owner/$repository/$run_id-$attempt"
destination="$parent/$name"
mkdir -p "$root/$owner"
[[ ! -L "$root/$owner" ]] || { printf '::error::Artifact owner path is a symlink\n' >&2; exit 1; }
mkdir -p "$root/$owner/$repository"
[[ ! -L "$root/$owner/$repository" ]] || { printf '::error::Artifact repository path is a symlink\n' >&2; exit 1; }
mkdir -p "$parent"
[[ ! -L "$parent" ]] || { printf '::error::Artifact run path is a symlink\n' >&2; exit 1; }
[[ ! -e "$destination" && ! -L "$destination" ]] || { printf '::error::Artifact destination already exists\n' >&2; exit 1; }
tmp=$(mktemp -d "$parent/.${name}.tmp.XXXXXXXX")
cleanup() { [[ -z "${tmp:-}" ]] || rm -rf -- "$tmp"; }
trap cleanup EXIT
cp -R -- "$src/." "$tmp/"
(
  cd "$tmp"
  find . -type f ! -name SHA256SUMS ! -name manifest.json -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 -r sha256sum > SHA256SUMS
  sha256sum -c SHA256SUMS
)
python3 - "$tmp" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
from datetime import datetime, timezone

root = pathlib.Path(sys.argv[1])
files = []
for path in sorted(p for p in root.rglob('*') if p.is_file() and p.name not in {'SHA256SUMS', 'manifest.json'}):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    files.append({'name': path.relative_to(root).as_posix(), 'size': path.stat().st_size, 'sha256': digest})
manifest = {
    'repo': os.environ['GITHUB_REPOSITORY'],
    'sha': os.environ.get('GITHUB_SHA', ''),
    'ref': os.environ.get('GITHUB_REF', ''),
    'run_id': os.environ['GITHUB_RUN_ID'],
    'run_attempt': os.environ['GITHUB_RUN_ATTEMPT'],
    'workflow': os.environ.get('GITHUB_WORKFLOW', ''),
    'created_utc': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
    'files': files,
    'retention': 'hold',
    'backed_up': False,
}
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
PY
mv -nT -- "$tmp" "$destination"
[[ ! -e "$tmp" ]] || { printf '::error::Artifact destination already exists\n' >&2; exit 1; }
tmp=''
printf 'Stored artifacts: %s\n' "$destination"
cat "$destination/SHA256SUMS"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '\n### Cluster build artifacts\n\nStored at `%s`.\n\n' "$destination"
    printf '| File | SHA-256 |\n|---|---|\n'
    awk '{name=$2; sub(/^\*/, "", name); printf "| `%s` | `%s` |\n", name, $1}' "$destination/SHA256SUMS"
  } >> "$GITHUB_STEP_SUMMARY"
fi
