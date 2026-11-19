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
expect_failure 'store rejects dot name' "$store" --src "$tmp/source" --name .
expect_failure 'store rejects dot-dot name' "$store" --src "$tmp/source" --name ..
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
mount=${@: -1}
case ${FAKE_DF_MODE:-above} in
  below) usage=70 ;;
  mixed) [[ "$mount" == /disk-a ]] && usage=90 || usage=80 ;;
  drops) ((count > 2)) && usage=75 || usage=90 ;;
  *) [[ "$mount" == /disk-a ]] && usage=${FAKE_DISK_A:-90} || usage=${FAKE_DISK_B:-90} ;;
esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 100 90 10 %s%% %s\n' "$usage" "$mount"
EOF_DF
chmod +x "$tmp/fake-df"
export PURGE_GATE_DF="$tmp/fake-df"
export FAKE_DF_COUNT="$tmp/df-count"

state_key_for() { printf '%s' "$(realpath -e "$1")" | sha256sum | cut -d' ' -f1; }
make_artifact() {
  local root=$1 run=$2 name=$3 created=$4 backed=$5
  local dir="$root/example-owner/example-repo/$run-1/$name"
  mkdir -p "$dir"
  printf '{"created_utc":"%s","backed_up":%s}\n' "$created" "$backed" > "$dir/manifest.json"
}
expired_state() {
  local root=$1 state=$2 age=${3:-200}
  mkdir -p "$state"
  local key
  key=$(state_key_for "$root")
  printf '%s\n2020-01-01T00:00:00Z\n/dev/fake:90\n' "$(( $(date -u +%s) - 3600 * age ))" > "$state/$key.warning"
}

export FAKE_DF_MODE=below
printf '0\n' > "$FAKE_DF_COUNT"
purge_root="$tmp/purge-below"
mkdir -p "$purge_root" "$tmp/state-below"
below_key=$(state_key_for "$purge_root")
printf 'epoch\n' > "$tmp/state-below/$below_key.warning"
if "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --threshold 80 --state-dir "$tmp/state-below" >"$tmp/out"; then
  grep -q 'below threshold on 2 disk(s); no purge' "$tmp/out" && [[ ! -e "$tmp/state-below/$below_key.warning" ]] && pass 'below threshold clears warning and does not purge' || fail 'below threshold clears warning and does not purge'
else fail 'below threshold gate exits successfully'; fi

export FAKE_DF_MODE=mixed
printf '0\n' > "$FAKE_DF_COUNT"
purge_root="$tmp/purge-mixed"
state="$tmp/state-mixed"
mkdir -p "$purge_root"
make_artifact "$purge_root" 1 backed 2026-01-01T00:00:00Z true
if "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --state-dir "$state" >"$tmp/out"; then
  grep -q 'below threshold on 1 disk(s); no purge' "$tmp/out" && [[ -e "$purge_root/example-owner/example-repo/1-1/backed/manifest.json" ]] && pass 'mixed disks block purge and clear warning' || fail 'mixed disks block purge and clear warning'
else fail 'mixed disk gate exits successfully'; fi

export FAKE_DF_MODE=above
printf '0\n' > "$FAKE_DF_COUNT"
purge_root="$tmp/purge-warning"
mkdir -p "$purge_root" "$tmp/state-warning"
make_artifact "$purge_root" 4 backed 2026-03-01T00:00:00Z true
if "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --state-dir "$tmp/state-warning" >"$tmp/out"; then
  grep -q '^::warning::' "$tmp/out" && grep -q '^Would purge ' "$tmp/out" && [[ -n "$(find "$tmp/state-warning" -name '*.warning' -print -quit)" ]] && [[ -f "$purge_root/example-owner/example-repo/4-1/backed/manifest.json" ]] && pass 'first high usage records warning and lists candidates without deletion' || fail 'first high usage records warning and lists candidates without deletion'
else fail 'warning gate exits successfully'; fi

printf '  # disk list comment\n\n/disk-a\n  # indented comment\n/disk-b\n' > "$tmp/disks.txt"
export FAKE_DF_MODE=below
printf '0\n' > "$FAKE_DF_COUNT"
if "$purge" --root "$purge_root" --disks-file "$tmp/disks.txt" --state-dir "$tmp/state-disks" >"$tmp/out"; then
  grep -q 'below threshold on 2 disk(s)' "$tmp/out" && pass 'disk file ignores comments and blank lines' || fail 'disk file ignores comments and blank lines'
else fail 'disk file comments gate exits successfully'; fi

export FAKE_DF_MODE=above
printf '0\n' > "$FAKE_DF_COUNT"
purge_root="$tmp/purge-grace"
state="$tmp/state-grace"
mkdir -p "$purge_root"
make_artifact "$purge_root" 1 backed 2026-01-01T00:00:00Z true
expired_state "$purge_root" "$state" 1
if "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --state-dir "$state" --grace-hours 72 --apply >"$tmp/out"; then
  grep -q 'Warning grace period has not elapsed' "$tmp/out" && [[ -e "$purge_root/example-owner/example-repo/1-1/backed/manifest.json" ]] && pass 'active grace window refuses purge' || fail 'active grace window refuses purge'
else fail 'active grace gate exits successfully'; fi

printf '0\n' > "$FAKE_DF_COUNT"
purge_root="$tmp/purge-marker"
state="$tmp/state-marker"
mkdir -p "$purge_root"
make_artifact "$purge_root" 1 marker 2026-01-01T00:00:00Z false
touch "$purge_root/example-owner/example-repo/1-1/marker/.backed-up"
expired_state "$purge_root" "$state"
if "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --state-dir "$state" >"$tmp/out"; then
  grep -q 'Would purge .*marker' "$tmp/out" && pass '.backed-up marker makes artifact eligible' || fail '.backed-up marker makes artifact eligible'
else fail 'marker eligibility gate exits successfully'; fi

printf '0\n' > "$FAKE_DF_COUNT"
purge_root="$tmp/purge-notify"
state="$tmp/state-notify"
mkdir -p "$purge_root"
export NOTIFY_CAPTURE="$tmp/notify-message"
if "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --state-dir "$state" --notify-cmd 'cat > "$NOTIFY_CAPTURE"' >"$tmp/out"; then
  key=$(state_key_for "$purge_root")
  [[ -s "$NOTIFY_CAPTURE" && -s "$state/$key.warning" ]] && pass 'notify success records warning after delivery' || fail 'notify success records warning after delivery'
else fail 'notify success gate exits successfully'; fi
printf '0\n' > "$FAKE_DF_COUNT"
purge_root="$tmp/purge-notify-fail"
state="$tmp/state-notify-fail"
mkdir -p "$purge_root"
expect_failure 'notify failure exits nonzero' "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --state-dir "$state" --notify-cmd 'exit 7'
key=$(state_key_for "$purge_root")
[[ ! -e "$state/$key.warning" ]] && pass 'notify failure records no warning state' || fail 'notify failure records no warning state'

export FAKE_DF_MODE=drops
printf '0\n' > "$FAKE_DF_COUNT"
purge_root="$tmp/purge-apply"
state="$tmp/state-apply"
mkdir -p "$purge_root"
make_artifact "$purge_root" 1 oldest 2026-01-01T00:00:00Z true
make_artifact "$purge_root" 2 newer 2026-02-01T00:00:00Z true
make_artifact "$purge_root" 3 unbacked 2025-01-01T00:00:00Z false
expired_state "$purge_root" "$state"
if "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --state-dir "$state" --apply >"$tmp/out"; then
  key=$(state_key_for "$purge_root")
  [[ ! -e "$purge_root/example-owner/example-repo/1-1/oldest" && -e "$purge_root/example-owner/example-repo/2-1/newer" && -e "$purge_root/example-owner/example-repo/3-1/unbacked" ]] && grep -q 'Storage returned to threshold' "$tmp/out" && [[ ! -e "$state/$key.warning" ]] && pass 'apply purges oldest first, clears warning, and stops at threshold' || fail 'apply purge order and stop threshold'
else fail 'apply purge exits successfully'; fi
apply_key=$(state_key_for "$purge_root")
[[ -s "$state/$apply_key.purges.log" ]] && pass 'purge deletion logged' || fail 'purge deletion logged'

export FAKE_DF_MODE=above
printf '0\n' > "$FAKE_DF_COUNT"
purge_root="$tmp/purge-symlink"
state="$tmp/state-symlink"
outside="$tmp/outside"
mkdir -p "$purge_root/example-owner/example-repo" "$outside/1-1/escaped"
printf '{"created_utc":"2026-01-01T00:00:00Z","backed_up":true}\n' > "$outside/1-1/escaped/manifest.json"
ln -s "$outside/1-1" "$purge_root/example-owner/example-repo/1-1"
expired_state "$purge_root" "$state"
if "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --state-dir "$state" --apply >"$tmp/out"; then
  [[ -f "$outside/1-1/escaped/manifest.json" ]] && pass 'symlinked run directory is not followed or deleted' || fail 'symlinked run directory is not followed or deleted'
else fail 'symlink refusal gate exits successfully'; fi
expect_failure 'purge refuses filesystem root' "$purge" --root / --disks /disk-a --state-dir "$tmp/state-root"
expect_failure 'purge refuses empty root' "$purge" --root '' --disks /disk-a --state-dir "$tmp/state-empty"

purge_root="$tmp/purge-lock"
state="$tmp/state-lock"
mkdir -p "$purge_root" "$state"
lock_key=$(state_key_for "$purge_root")
lock_path="$state/$lock_key.lock"
export LOCK_HELD="$tmp/lock-held"
flock -n "$lock_path" -c 'touch "$LOCK_HELD"; sleep 3' &
locker_pid=$!
for _ in {1..100}; do [[ -e "$LOCK_HELD" ]] && break; sleep 0.02; done
if [[ -e "$LOCK_HELD" ]]; then
  expect_failure 'concurrent purge run refused by lock' "$purge" --root "$purge_root" --disks '/disk-a /disk-b' --state-dir "$state"
  grep -q 'state lock' "$tmp/err" && pass 'lock refusal explains the conflict' || fail 'lock refusal explains the conflict'
else fail 'lock holder started'; fi
wait "$locker_pid"

printf '\nResult: %d PASS, %d FAIL\n' "$passed" "$failed"
((failed == 0))
