#!/usr/bin/env bash
# Rejects a candidate change that touches anything outside the AI driving
# policy sandbox (res://ai/). Run this from the repo root BEFORE scoring a
# candidate -- an out-of-bounds change must never even be evaluated, let
# alone accepted, no matter what score it would have gotten.
#
# Usage:
#   tools/check_allowlist.sh                 # everything uncommitted right
#                                             # now: staged, unstaged, AND
#                                             # untracked new files
#   tools/check_allowlist.sh HEAD~1          # last commit vs its parent
#   tools/check_allowlist.sh main...HEAD     # a whole candidate branch
#
# Exit code 0 = OK to proceed to eval. Exit code 1 = reject: do not run
# eval, do not accept this candidate, revert it.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [ "$#" -eq 0 ]; then
	# `git diff` alone only shows unstaged changes against the index, and is
	# completely blind to brand-new untracked files -- either gap would let
	# an out-of-bounds file slip past this check unnoticed. `git status
	# --porcelain` covers staged, unstaged, and untracked in one pass.
	CHANGED=$(git status --porcelain --untracked-files=all | sed -E 's/^.{3}//')
else
	# Reviewing an already-committed range: untracked files aren't relevant
	# here since they'd have to be committed to be part of a diff at all.
	CHANGED=$(git diff --name-only "$@")
fi

if [ -z "$CHANGED" ]; then
	echo "No changes detected."
	exit 0
fi

VIOLATIONS=""
while IFS= read -r f; do
	[ -z "$f" ] && continue
	if [[ "$f" == *" -> "* ]]; then
		# Rename/copy line ("old/path -> new/path", after stripping the 2-char
		# XY status + space that `git status --porcelain` prefixes it with).
		# Check BOTH sides: a frozen file disappearing (old path outside ai/)
		# is exactly as out-of-bounds as one appearing (new path outside
		# ai/) -- and checking only the combined string against `^ai/` let
		# `ai/x.gd -> vehicles/vehicle.gd` (overwriting a frozen file with a
		# rename) pass, since the string itself starts with "ai/" even
		# though the actual write lands outside it.
		old_path="${f%% -> *}"
		new_path="${f##* -> }"
		if [[ ! "$old_path" =~ ^ai/ ]] || [[ ! "$new_path" =~ ^ai/ ]]; then
			VIOLATIONS+="  $f"$'\n'
		fi
	elif [[ ! "$f" =~ ^ai/ ]]; then
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
