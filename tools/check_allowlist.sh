#!/usr/bin/env bash
# Rejects a candidate diff that touches anything outside the AI driving
# policy sandbox (res://ai/). Run this from the repo root BEFORE scoring a
# candidate -- an out-of-bounds diff must never even be evaluated, let alone
# accepted, no matter what score it would have gotten.
#
# Usage:
#   tools/check_allowlist.sh                 # working tree vs last commit
#   tools/check_allowlist.sh HEAD~1          # last commit vs its parent
#   tools/check_allowlist.sh main...HEAD     # a whole candidate branch
#
# Exit code 0 = OK to proceed to eval. Exit code 1 = reject, do not run eval,
# do not accept this candidate, revert it.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

CHANGED=$(git diff --name-only "$@")

if [ -z "$CHANGED" ]; then
	echo "No changes detected."
	exit 0
fi

VIOLATIONS=""
while IFS= read -r f; do
	if [[ ! "$f" =~ ^ai/ ]]; then
		VIOLATIONS+="  $f"$'\n'
	fi
done <<< "$CHANGED"

if [ -n "$VIOLATIONS" ]; then
	echo "REJECTED: candidate touches files outside the AI policy sandbox (res://ai/):"
	echo "$VIOLATIONS"
	echo "The driving policy may only live under res://ai/. Files governing the" 
	echo "car's physics, the race referee/scoring, or the track are frozen --"
	echo "see res://ai/README_RESEARCH.md."
	exit 1
fi

echo "OK: all changes confined to res://ai/"
exit 0
