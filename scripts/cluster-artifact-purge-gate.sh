#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --root DIR (--disks "MOUNT1 MOUNT2" | --disks-file FILE) [--threshold 80] [--grace-hours 72] --state-dir DIR [--notify-cmd CMD] [--apply]\n' "$0" >&2
  exit 2
}
root=''
disks_text=''
disks_file=''
threshold=80
grace_hours=72
state_dir=''
notify_cmd=''
apply=false
while (($#)); do
  case "$1" in
    --root) (($# >= 2)) || usage; root=$2; shift 2 ;;
    --disks) (($# >= 2)) || usage; disks_text=$2; shift 2 ;;
    --disks-file) (($# >= 2)) || usage; disks_file=$2; shift 2 ;;
    --threshold) (($# >= 2)) || usage; threshold=$2; shift 2 ;;
    --grace-hours) (($# >= 2)) || usage; grace_hours=$2; shift 2 ;;
    --state-dir) (($# >= 2)) || usage; state_dir=$2; shift 2 ;;
    --notify-cmd) (($# >= 2)) || usage; notify_cmd=$2; shift 2 ;;
    --apply) apply=true; shift ;;
    *) usage ;;
  esac
done
[[ -n "$root" && "$root" != / && -d "$root" && ! -L "$root" ]] || { printf 'Refusing empty, missing, symlink, or root directory\n' >&2; exit 1; }
root=$(realpath -e -- "$root")
[[ "$root" != / ]] || { printf 'Refusing filesystem root\n' >&2; exit 1; }
[[ -n "$state_dir" ]] || usage
[[ "$threshold" =~ ^[0-9]+$ && "$threshold" -le 100 ]] || { printf 'Invalid threshold\n' >&2; exit 2; }
[[ "$grace_hours" =~ ^[0-9]+$ ]] || { printf 'Invalid grace period\n' >&2; exit 2; }
[[ -n "$disks_text" || -n "$disks_file" ]] || usage
[[ -z "$disks_text" || -z "$disks_file" ]] || { printf 'Specify only one disk list\n' >&2; exit 2; }
disks=()
if [[ -n "$disks_file" ]]; then
  [[ -f "$disks_file" ]] || { printf 'Disk list file is missing\n' >&2; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \\#* ]] || disks+=("$line")
  done < "$disks_file"
else
  read -r -a disks <<< "$disks_text"
fi
((${#disks[@]} > 0)) || { printf 'Disk list is empty\n' >&2; exit 2; }
mkdir -p -- "$state_dir"
state_key=$(printf '%s' "$(realpath -e -- "$root")" | sha256sum | cut -d' ' -f1)
warning_file="$state_dir/$state_key.warning"
log_file="$state_dir/$state_key.purges.log"
df_command=${PURGE_GATE_DF:-df}

usage_snapshot() {
  local mount output used
  local -a values=()
  for mount in "${disks[@]}"; do
    output=$("$df_command" -P -- "$mount") || { printf 'Unable to read disk usage for %s\n' "$mount" >&2; return 1; }
    used=$(awk 'NR == 2 {gsub(/%/, "", $5); print $5}' <<< "$output")
    [[ "$used" =~ ^[0-9]+$ ]] || { printf 'Invalid df usage for %s\n' "$mount" >&2; return 1; }
    values+=("$mount:$used")
  done
  printf '%s\n' "${values[@]}"
}
all_above() {
  local record used
  while IFS= read -r record; do
    used=${record##*:}
    ((used > threshold)) || return 1
  done <<< "$1"
  return 0
}

snapshot=$(usage_snapshot)
if ! all_above "$snapshot"; then
  below_count=0
  while IFS= read -r record; do
    used=${record##*:}
    if ((used <= threshold)); then below_count=$((below_count + 1)); fi
  done <<< "$snapshot"
  printf 'below threshold on %s disk(s); no purge\n' "$below_count"
  rm -f -- "$warning_file"
  exit 0
fi
warning_text="Cluster storage is above ${threshold}% on every listed disk. Artifacts remain on hold; purge review begins only after ${grace_hours} hours and only for backed-up data. Usage: $(tr '\n' ';' <<< "$snapshot")"
candidates_file=$(mktemp)
trap 'rm -f -- "$candidates_file"' EXIT
while IFS= read -r -d '' manifest; do
  artifact_dir=${manifest%/manifest.json}
  relative_dir=${artifact_dir#"$root"/}
  [[ "$relative_dir" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_-]+-[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$ && "$relative_dir" != *..* ]] || continue
  [[ -f "$artifact_dir/.backed-up" ]] && backed=true || backed=false
  if [[ "$backed" != true ]] && python3 - "$manifest" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        data = json.load(f)
    raise SystemExit(0 if data.get('backed_up') is True else 1)
except (OSError, ValueError):
    raise SystemExit(1)
PY
  then backed=true; fi
  [[ "$backed" == true ]] || continue
  created=$(python3 - "$manifest" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        print(json.load(f).get('created_utc', ''))
except (OSError, ValueError):
    print('')
PY
)
  [[ -n "$created" ]] || continue
  printf '%s\t%s\n' "$created" "$artifact_dir" >> "$candidates_file"
done < <(find "$root" -type f -name manifest.json -print0)

if [[ ! -f "$warning_file" ]]; then
  { date -u +%s; date -u +'%Y-%m-%dT%H:%M:%SZ'; printf '%s\n' "$snapshot"; } > "$warning_file"
  printf '%s\n' "$warning_text"
  printf '::warning::%s\n' "$warning_text"
  if [[ -n "$notify_cmd" ]]; then printf '%s\n' "$warning_text" | bash -c "$notify_cmd"; fi
  if [[ -s "$candidates_file" ]]; then
    while IFS=$'\t' read -r created artifact_dir; do
      [[ -n "$created" && -n "$artifact_dir" ]] || continue
      printf 'Would purge %s (created %s) after the grace period if usage remains high.\n' "$artifact_dir" "$created"
    done < <(LC_ALL=C sort -t $'\t' -k1,1 "$candidates_file")
  else
    printf 'No backed-up artifact directories are eligible.\n'
  fi
  exit 0
fi
warning_epoch=$(head -n 1 "$warning_file")
[[ "$warning_epoch" =~ ^[0-9]+$ ]] || { printf 'Invalid warning state\n' >&2; exit 1; }
now=$(date -u +%s)
((now - warning_epoch >= grace_hours * 3600)) || { printf 'Warning grace period has not elapsed; no purge\n'; exit 0; }

if [[ ! -s "$candidates_file" ]]; then
  printf 'No backed-up artifact directories are eligible.\n'
  exit 0
fi
while IFS=$'\t' read -r created artifact_dir; do
  [[ -n "$created" && -n "$artifact_dir" ]] || continue
  if [[ "$apply" != true ]]; then
    printf 'Would purge %s (created %s)\n' "$artifact_dir" "$created"
    continue
  fi
  [[ "$artifact_dir" == "$root"/* && ! -L "$artifact_dir" ]] || { printf 'Refusing candidate outside root or symlink\n' >&2; exit 1; }
  rm -rf --one-file-system -- "$artifact_dir"
  printf '%s\t%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$artifact_dir" >> "$log_file"
  printf 'Purged %s (created %s)\n' "$artifact_dir" "$created"
  snapshot=$(usage_snapshot)
  if ! all_above "$snapshot"; then
    printf 'Storage returned to threshold; stopping purge.\n'
    exit 0
  fi
done < <(LC_ALL=C sort -t $'\t' -k1,1 "$candidates_file")
