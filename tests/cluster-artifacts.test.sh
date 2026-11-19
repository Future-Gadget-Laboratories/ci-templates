#!/usr/bin/env bash
set -euo pipefail

base=$(cd "$(dirname "$0")/.." && pwd)
store="$base/scripts/cluster-artifact-store.sh"
purge="$base/scripts/cluster-artifact-purge-gate.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
passed=0
failed=0

pass() { printf 'PASS: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }
expect_success() {
  local label=$1; shift
  if "$@" >"$tmp/out" 2>"$tmp/err"; then pass "$label"; else fail "$label (exit $?)"; fi
}
expect_failure() {
  local label=$1; shift
  if "$@" >"$tmp/out" 2>"$tmp/err"; then fail "$label unexpectedly succeeded"; else pass "$label"; fi
}

mkdir -p "$tmp/source" "$tmp/storage"
printf 'wheel data\n' > "$tmp/source/package.whl"
printf 'source data\n' > "$tmp/source/package.tar.gz"
export CLUSTER_ARTIFACT_ROOT="$tmp/storage"
export GITHUB_REPOSITORY='example-owner/example-repo'
export GITHUB_RUN_ID=31415 GITHUB_RUN_ATTEMPT=2
export GITHUB_SHA=0123456789abcdef GITHUB_REF=refs/heads/main GITHUB_WORKFLOW='build test'
export GITHUB_STEP_SUMMARY="$tmp/summary"
expect_success 'store happy path' "$store" --src "$tmp/source" --name dist-engine
stored="$tmp/storage/example-owner/example-repo/31415-2/dist-engine"
if (cd "$stored" && sha256sum -c SHA256SUMS >/dev/null) && python3 - "$stored/manifest.json" <<'PY'
import json, sys
m=json.load(open(sys.argv[1], encoding='utf-8'))
assert m['repo']=='example-owner/example-repo'
assert m['sha']=='0123456789abcdef'
assert m['ref']=='refs/heads/main'
assert m['run_id']=='31415' and m['run_attempt']=='2'
assert m['workflow']=='build test'
assert m['retention']=='hold' and m['backed_up'] is False
assert len(m['files'])==2 and all({'size','sha256'} <= f.keys() for f in m['files'])
PY
then pass 'manifest fields and checksums'; else fail 'manifest fields and checksums'; fi
[[ -s "$GITHUB_STEP_SUMMARY" ]] && pass 'step summary written' || fail 'step summary written'
expect_failure 'store refuses overwrite' "$store" --src "$tmp/source" --name dist-engine
unset CLUSTER_ARTIFACT_ROOT
expect_failure 'store fails closed when root is unset' "$store" --src "$tmp/source" --name missing-root
export CLUSTER_ARTIFACT_ROOT="$tmp/storage"
mkdir "$tmp/readonly"
chmod 555 "$tmp/readonly"
export CLUSTER_ARTIFACT_ROOT="$tmp/readonly"
expect_failure 'store fails closed when root is not writable' "$store" --src "$tmp/source" --name readonly
chmod 755 "$tmp/readonly"
export CLUSTER_ARTIFACT_ROOT="$tmp/storage"
export GITHUB_RUN_ID='../escape'
expect_failure 'store rejects bad run id traversal' "$store" --src "$tmp/source" --name bad-run
export GITHUB_RUN_ID=31416
export GITHUB_REPOSITORY='example-owner/../escape'
expect_failure 'store rejects repo path traversal' "$store" --src "$tmp/source" --name bad-repo
export GITHUB_REPOSITORY='example-owner/example-repo'

cat > "$tmp/fake-df" <<'EOF_DF'
#!/usr/bin/env bash
set -euo pipefail
count_file=${FAKE_DF_COUNT:?}
count=0
[[ ! -f "$count_file" ]] || read -r count < "$count_file"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [[ ${FAKE_DF_MODE:-} == below ]]; then usage=70
elif [[ ${FAKE_DF_MODE:-} == drops && $count -gt 2 ]]; then usage=75
else usage=90
fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 100 90 10 %s%% %s\n' "$usage" "${@: -1}"
EOF_DF
chmod +x "$tmp/fake-df"
export PURGE_GATE_DF="$tmp/fake-df"
export FAKE_DF_COUNT="$tmp/df-count"
export FAKE_DF_MODE=below
purge_root="$tmp/purge-below"
mkdir -p "$purge_root" "$tmp/state-below"
below_key=$(printf '%s' "$(realpath -e "$purge_root")" | sha256sum | cut -d' ' -f1)
printf 'epoch\n' > "$tmp/state-below/$below_key.warning"
if "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --threshold 80 --state-dir "$tmp/state-below" >"$tmp/out"; then
  grep -q 'below threshold on 2 disk(s); no purge' "$tmp/out" && [[ ! -e "$tmp/state-below/$below_key.warning" ]] && pass 'below threshold clears warning and does not purge' || fail 'below threshold clears warning and does not purge'
else fail 'below threshold gate exits successfully'; fi

export FAKE_DF_MODE=above
printf '0\n' > "$FAKE_DF_COUNT"
purge_root="$tmp/purge-warning"
mkdir -p "$purge_root" "$tmp/state-warning"
mkdir -p "$purge_root/example-owner/example-repo/4-1/artifact"
printf '{"created_utc":"2026-03-01T00:00:00Z","backed_up":true}\n' > "$purge_root/example-owner/example-repo/4-1/artifact/manifest.json"
if "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --state-dir "$tmp/state-warning" >"$tmp/out"; then
  grep -q '^::warning::' "$tmp/out" && grep -q '^Would purge ' "$tmp/out" && [[ -n "$(find "$tmp/state-warning" -name '*.warning' -print -quit)" ]] && [[ -f "$purge_root/example-owner/example-repo/4-1/artifact/manifest.json" ]] && pass 'first high usage records warning and lists candidates without deletion' || fail 'first high usage records warning and lists candidates without deletion'
else fail 'warning gate exits successfully'; fi

make_artifact() {
  local root=$1 run=$2 name=$3 created=$4 backed=$5
  local dir="$root/example-owner/example-repo/$run-1/$name"
  mkdir -p "$dir"
  printf '{"created_utc":"%s","backed_up":%s}\n' "$created" "$backed" > "$dir/manifest.json"
}
expired_state() {
  local root=$1 state=$2
  mkdir -p "$state"
  local key
  key=$(printf '%s' "$(realpath -e "$root")" | sha256sum | cut -d' ' -f1)
  printf '%s\n2020-01-01T00:00:00Z\n/dev/fake:90\n' "$(( $(date -u +%s) - 3600 * 200 ))" > "$state/$key.warning"
}

export FAKE_DF_MODE=above
printf '0\n' > "$FAKE_DF_COUNT"
purge_root="$tmp/purge-dry"
state="$tmp/state-dry"
mkdir -p "$purge_root"
make_artifact "$purge_root" 1 backed 2026-01-01T00:00:00Z true
expired_state "$purge_root" "$state"
if "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --state-dir "$state" >"$tmp/out"; then
  grep -q 'Would purge' "$tmp/out" && [[ -f "$purge_root/example-owner/example-repo/1-1/backed/manifest.json" ]] && pass 'dry-run lists backed-up artifacts and deletes nothing' || fail 'dry-run lists backed-up artifacts and deletes nothing'
else fail 'dry-run gate exits successfully'; fi

printf '0\n' > "$FAKE_DF_COUNT"
export FAKE_DF_MODE=drops
purge_root="$tmp/purge-apply"
state="$tmp/state-apply"
mkdir -p "$purge_root"
make_artifact "$purge_root" 1 oldest 2026-01-01T00:00:00Z true
make_artifact "$purge_root" 2 newer 2026-02-01T00:00:00Z true
make_artifact "$purge_root" 3 unbacked 2025-01-01T00:00:00Z false
expired_state "$purge_root" "$state"
if "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --state-dir "$state" --apply >"$tmp/out"; then
  [[ ! -e "$purge_root/example-owner/example-repo/1-1/oldest" && -e "$purge_root/example-owner/example-repo/2-1/newer" && -e "$purge_root/example-owner/example-repo/3-1/unbacked" ]] && grep -q 'Storage returned to threshold' "$tmp/out" && pass 'apply purges oldest backed-up first and stops below threshold' || fail 'apply purge order and stop threshold'
else fail 'apply purge exits successfully'; fi
apply_key=$(printf '%s' "$(realpath -e "$purge_root")" | sha256sum | cut -d' ' -f1)
[[ -s "$state/$apply_key.purges.log" ]] && pass 'purge deletion logged' || fail 'purge deletion logged'

printf '\nResult: %d PASS, %d FAIL\n' "$passed" "$failed"
((failed == 0))
