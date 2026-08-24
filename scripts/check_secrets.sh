#!/usr/bin/env bash
# scripts/check_secrets.sh
#
# Scan a chunk of text for sensitive strings that must NEVER reach a
# public remote (GitHub).  Used by both the pre-commit hook (input =
# staged diff) and the pre-push hook (input = diff of commits about to
# be pushed).
#
# Exit codes:
#   0  clean
#   1  hit -- abort the git op
#   2  internal error (no input, missing tools)
#
# Bypass with `git commit --no-verify` / `git push --no-verify`.
#
# This script reads stdin (the diff/text to scan).  It assumes the
# caller has already filtered to "added lines only" if that's desired
# (we just regex over whatever's piped in).

set -u

# ----------------------------------------------------------------------
# Patterns.  Keep these in sync with USER profile rules.
# ----------------------------------------------------------------------
# Each entry: "<label>|<extended_regex>"
PATTERNS=(
  "company-email|lizeqiang@kurogame\.com"
  "company-domain|kurogame\.com"
  "kuro-gitlab|git\.kuro\.com"
  "project-codename-ueaki|\bUEAki\b"
  "project-appid-mingchao|com\.kurogame\.mingchao"
  "personal-user-path|([A-Za-z]:[\\/]+|/(mnt/)?[a-z]/)Users[\\/]lizeqiang([\\/]|$)"
  "private-project-root|[A-Za-z]:[\\/]+(aki[\\/]+(zeqiang_aki|android_)|project[\\/]+(uetemp|UnrealEngine))"
  "private-ipv4|(^|[^0-9])(10\.[0-9]{1,3}(\.[0-9]{1,3}){2}|192\.168(\.[0-9]{1,3}){2}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2})([^0-9]|$)"
  "private-key-pem|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----"
  "github-pat-classic|ghp_[A-Za-z0-9]{36}"
  "github-pat-fine|github_pat_[A-Za-z0-9_]{82}"
  "aws-access-key|AKIA[0-9A-Z]{16}"
)

# ----------------------------------------------------------------------
# Read stdin.
# ----------------------------------------------------------------------
input=$(cat)
if [ -z "$input" ]; then
  # Nothing to scan -- treat as clean (caller decides whether that's odd).
  exit 0
fi

hits=0
hit_report=""

for entry in "${PATTERNS[@]}"; do
  label="${entry%%|*}"
  regex="${entry#*|}"
  # grep -n gives line numbers within the diff, -E for ERE, -i case-insensitive
  matches=$(printf '%s\n' "$input" | grep -nEi -e "$regex" || true)
  if [ -n "$matches" ]; then
    hits=$((hits + 1))
    hit_report+=$'\n'"  [$label]"
    while IFS= read -r line; do
      hit_report+=$'\n'"    $line"
    done <<< "$matches"
  fi
done

if [ "$hits" -gt 0 ]; then
  cat >&2 <<EOF

[check_secrets] BLOCKED -- $hits sensitive pattern(s) hit:
$hit_report

Either:
  - remove the offending content, OR
  - bypass with --no-verify (DANGER: only if you're 100% sure this remote is private)

EOF
  exit 1
fi

exit 0
