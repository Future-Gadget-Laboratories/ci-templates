#!/usr/bin/env bash
# Generic secret-scan baseline, shared across every FGL repo. Vendor this
# file in (don't symlink - CI checkouts of the calling repo don't have
# ci-templates' tree present) and layer any repo-specific forbidden-path
# checks in a wrapper script that sources or calls this one first.
#
# Extracted from LabCluster's ci/scan-secrets.sh (Gate 0) - kept only the
# genuinely generic checks; LabCluster-specific paths (WireGuard configs,
# munge.key, its own portal config) stay in LabCluster's own script.
set -euo pipefail
ROOT=${1:-.}
cd "$ROOT"

fail=0
note() { echo "SECRET-SCAN: $*" >&2; fail=1; }

scan_tree() {
  local pattern=$1
  local label=$2
  if grep -R -I -n --exclude-dir=.git --exclude-dir=.venv --exclude-dir=node_modules \
      --exclude-dir=__pycache__ --exclude='*.zip' \
      -E "$pattern" . 2>/dev/null | grep -v 'scan-secrets' ; then
    note "matched $label"
  fi
}

scan_tree 'BEGIN OPENSSH PRIVATE KEY|BEGIN RSA PRIVATE KEY|BEGIN EC PRIVATE KEY|BEGIN PGP PRIVATE KEY' 'PEM/OpenSSH/PGP private key'
scan_tree '^[[:space:]]*PrivateKey[[:space:]]*=' 'WireGuard-style PrivateKey assignment'
scan_tree 'AKIA[0-9A-Z]{16}' 'AWS access key ID'
scan_tree '(api[_-]?key|secret|password|token)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9/+_-]{16,}["'"'"']' 'hardcoded credential-shaped assignment'

if [[ $fail -ne 0 ]]; then
  echo "scan-secrets-baseline.sh FAILED" >&2
  exit 1
fi
echo "scan-secrets-baseline.sh OK"
