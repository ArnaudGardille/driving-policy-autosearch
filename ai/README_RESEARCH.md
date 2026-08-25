# AI Driving Policy — Research Sandbox Rules

This directory (`res://ai/`) is the **only** part of the project an automated
tuning or research loop (e.g. an `autoresearch`-style agent) is allowed to
edit when searching for a better driving policy.

## Objective

Reach the end of the track as fast as possible, without falling off, without
cheating — "cheating" meaning: no advantage over what a human player has.
Same car physics, same track, same control surface as the human.

## Scoring

`RaceManager.compute_score()` (`res://race/race_manager.gd`) is the single
source of truth:

    score = pct_of_track_completed * (1 + time_bonus)

`time_bonus` (fraction of the race clock left unused) is only awarded if the
track was actually finished. Below 1.0 for any run that doesn't finish, at
or above 1.0 for any run that does (faster finishes score higher, up to
2.0). A run that gets further but doesn't finish can never outscore one
that finishes slowly — finishing is the primary criterion.

`res://tests/run_eval.gd` reports `aggregate_score`, which is the **minimum**
score across the vehicle suite (car_base / trailer_truck / tow_truck), not
the mean — a human can pick any of the three cars, so a policy that only
drives well in its favorite one is not a better policy.

## What may change

- `res://ai/ai_drive_task.gd` and any new scripts/resources added under
  `res://ai/` — the driving algorithm and its tunables.
- The policy may only actuate the car through the same control surface the
  human player uses: steering (clamped to the car's own `max_steer`, which
  must match `vehicle.gd`'s `STEER_LIMIT`), engine force, braking. Never
  write `global_position` / `linear_velocity` directly, never disable
  physics, never read or write `race_manager.gd` state.

## What must never change

Enforced mechanically, in two layers — a candidate is rejected if it fails
either one, independent of what score it would otherwise have gotten:

**1. File-level allowlist** (`tools/check_allowlist.sh`, run before every
eval): rejects any candidate whose change set — staged, unstaged, *and*
untracked new files, not just `git diff` — touches anything outside
`res://ai/`:

- `res://vehicles/*.gd` — car physics: steering limit, engine force, mass,
  suspension. This *is* the "same car as the human" guarantee.
- `res://race/race_manager.gd` — the referee: scoring, win/fall/off-track
  detection, race duration, track width, finish-line margin.
- `res://town/model/racetrack_csg.tscn` — the track geometry.
- `res://tests/*.gd` — the judge that scores the candidate. It must not be
  able to grade its own homework.

**2. Runtime fairness check** (built into `res://tests/ai_benchmark.gd`,
reported as `fair`/`ok` in the eval JSON): the file allowlist stops a
candidate from *editing* `vehicle.gd`, but nothing stops code living inside
the *allowed* `ai_drive_task.gd` from just calling `car.engine_force` /
`car.steering` with values a human could never reach (e.g. quietly bumping
its own `engine_power` export past what the player's own car ever applies).
Since `ai_drive_task.gd` fully owns those properties every tick while the AI
drives, this can only be caught by checking the values actually *applied* to
the car, every tick, against the car's own frozen constants — not by
reading the policy script's intentions. Every eval run tracks the peak
`engine_force` and `steering` actually used and compares them against the
car's own `STEER_LIMIT` and the shared low-speed-boost ceiling of `100.0`
(the highest `engine_force` a human can ever get from `vehicle.gd`, at any
speed). A violation sets `fair: false` and `ok: false` in the output —
treat that as an automatic reject, regardless of the score value.

## How to evaluate a candidate

Headless, deterministic, no editor required:

    /home/maitre/Documents/Godot_v4.7.2-stable_linux.x86_64 --headless --path . \
        --script res://tests/run_eval.gd -- \
        --seconds=65 --vehicles=car_base,trailer_truck,tow_truck

Optional flags: `--overrides={"cross_track_gain":0.75}` (JSON object of
`AIDriveTask` exported properties, for parameter sweeps without editing the
script).

Prints one line of JSON as the LAST line of stdout (Godot prints a version
banner first) with a `score` per vehicle plus `aggregate_score`. Exit code
is non-zero on any failure — bad args, unknown vehicle, script error, *or a
fairness violation* — treat that as "do not accept this candidate",
independent of whatever score value is or isn't present in the output.

## Recommended loop (per candidate)

1. Propose a change, implemented ONLY under `res://ai/`.
2. `tools/check_allowlist.sh` — reject immediately if it fails.
3. Run the eval command above.
4. Compare `aggregate_score` to the current best; keep or `git revert`.
5. Log the hypothesis, the diff, and the resulting score somewhere durable
   (this is what makes iteration auditable and stops silent regressions).

## Known caveat: sensing is currently privileged

The current policy reads the track's `Path3D` curve directly (exact offset
and curvature), which is more information than a human gets by looking at
the screen. This has not been restricted. Any research loop is free to
*try* something more sensor-realistic, but should not treat loosening this
constraint as free progress — flag it explicitly if a candidate's gains come
from privileged sensing rather than a better driving policy.
