# autoresearch: AI driving policy

Adapted from [karpathy/autoresearch](https://github.com/karpathy/autoresearch)'s
`program.md` pattern to this project's task. An agent (human-prompted coding
agent, e.g. Claude Code, Codex, or Ziva itself) reads this file and runs the
experiment loop autonomously using its own normal tool access (edit files,
run shell commands, git) — there is no separate framework/binary to install.

## Setup

To set up a new experiment run, work with the user to:

1. **Agree on a run tag**: propose a tag based on today's date (e.g. `aug25`).
   The branch `autoresearch/<tag>` must not already exist — this is a fresh run.
2. **Create the branch**: `git checkout -b autoresearch/<tag>` from current master.
3. **Read the in-scope files**:
   - `res://ai/README_RESEARCH.md` — the full contract: objective, scoring
     formula, what may/mayn't change, sensing caveat.
   - `res://ai/ai_drive_task.gd` — the file you modify.
   - `res://race/race_manager.gd` — read-only reference for `compute_score()`
     (the ground-truth metric) and the fairness constants (`STEER_LIMIT`
     equivalent, track width, etc).
4. **Initialize results.tsv**: create `results.tsv` (repo root) with just the
   header row, and commit it. Unlike upstream `autoresearch`, this file IS
   tracked in git (not gitignored) — it's the permanent, replayable record
   of every experiment tried, including discarded and crashed ones, not
   just a local scratch log. See "The experiment loop" below for exactly
   when it gets committed.
5. **Confirm and go.**

## Experimentation

Each experiment is scored by a single headless command, run from the repo root:

```
/home/maitre/Documents/Godot_v4.7.2-stable_linux.x86_64 --headless --path . \
    --script res://tests/run_eval.gd -- \
    --seconds=65 --vehicles=car_base,trailer_truck,tow_truck
```

(Run this from the repo root. If the Godot binary has moved, find it with
`which godot` or check the project's usual launch shortcut first.)

This runs a full deterministic race for each of the three vehicles (a human
can drive any of them) and prints one line of JSON as the LAST line of
stdout (Godot prints a version banner first).

**What you CAN do:**
- Modify `res://ai/ai_drive_task.gd`, or add new files under `res://ai/` —
  this is the only place you edit. Everything about the driving algorithm is
  fair game: steering logic, braking logic, localization, lookahead,
  whatever. The policy may only actuate the car through the same control
  surface a human uses (steering clamped to `max_steer`, engine force,
  brake) — never write `global_position`/`linear_velocity` directly, never
  touch physics flags, never read/write `race_manager.gd` state.

**What you CANNOT do:**
- Modify anything under `res://vehicles/` (car physics — this is the "same
  car as the human" guarantee), `res://race/race_manager.gd` (the referee),
  the racetrack scene, or `res://tests/*.gd` (the judge). These are frozen.
  **Before every commit, run `tools/check_allowlist.sh`** — if it rejects
  your change set (this checks staged, unstaged, AND new untracked files),
  you have gone out of bounds; fix it before committing.
- Apply `car.engine_force` or `car.steering` values a human could never
  reach. The allowlist only stops you editing `vehicle.gd`; it does NOT
  stop `ai_drive_task.gd` itself from just calling those properties with
  bigger numbers (e.g. quietly raising `engine_power`). This is caught
  separately, at runtime, every eval: the JSON output's `fair`/`ok` fields
  go false if the peak applied engine force or steering ever exceeded the
  car's own limits (`STEER_LIMIT`, and the shared 100.0 low-speed-boost
  ceiling). **Treat `ok: false` as an automatic reject, no matter the
  score** — step 6/7 below.
- Loosen the AI's sensing beyond what it already has (direct `Path3D` curve
  access) without flagging it explicitly as a sensing change, not a driving
  improvement — see the caveat in `README_RESEARCH.md`.

**The goal: maximize `aggregate_score`** (the MINIMUM `score` across the
three vehicles, not the mean — a policy that only drives well in its
favorite car is not a better policy). Recall the scoring shape: below 1.0
for any run that doesn't finish the track, at or above 1.0 for any run that
does (faster finishes score higher, up to 2.0). The only hard constraints:
it must not fall off, and it must not cheat (no car/track advantage over
the human, no bypassing the actuation surface).

**Simplicity criterion**: all else being equal, simpler is better. A small
score improvement that adds a pile of special-cased hacks is not obviously
worth it — weigh it the same way you'd weigh a `val_bpb` win against added
complexity in the original autoresearch. Removing a knob and keeping the
same score is a genuine simplification win.

**The first run**: always establish the baseline first, on the current
(unmodified) `ai_drive_task.gd`.

## Logging results

Log EVERY experiment to `results.tsv` (tab-separated, NOT comma — commas
break in descriptions) — kept, discarded, AND crashed. This is the
permanent audit trail: it's how a human (or another agent, later) can see
every idea tried, not just the ones that stuck, so failed directions
aren't quietly re-tried. Columns:

```
commit	aggregate_score	mean_score	status	description
```

1. git commit hash (short, 7 chars) of the CODE commit this row is about —
   for `keep`, this is reachable on the branch and can be checked out
   directly; for `discard`/`crash`, `git reset --hard` makes it unreachable
   from the branch afterward, but it's still recoverable via `git reflog`
   for a while (not forever — don't rely on it past the session). The code
   diff itself is only ever preserved this way, but the run's full raw
   output is not — see `runs/<hash>.json` below, which IS permanent.
2. `aggregate_score` from the eval JSON (e.g. `1.223000`) — use `0.000000`
   for crashes
3. `mean_score` from the eval JSON, same format
4. status: `keep`, `discard`, or `crash`
5. short text description of what this experiment tried, AND the
   before/after `aggregate_score` (e.g. `"lower braking_factor 3.5->2.0:
   0.276 -> 0.301"`) so the row is self-explanatory without cross-referencing

Alongside `results.tsv`, also save the full raw eval JSON for every
experiment to `runs/<hash>.json` (`<hash>` = the same short commit hash as
the tsv row), and commit it in the SAME commit as the tsv row. This is the
one piece of upstream `autoresearch`'s design that didn't translate well
as-is: there, `results.tsv` itself is the whole record (a `val_bpb` float
is the complete story). Here, the eval JSON carries per-vehicle telemetry
(`avg_lateral_offset_m`, `max_speed_mps`, `fell_off_track`,
`fall_distance_m`, the `fair` flags, etc.) that a one-line tsv description
can't fully capture, and `run.log` — the only place that JSON otherwise
appears — is gitignored and overwritten by the very next run. Without this,
a `discard`/`crash` experiment's full telemetry is unrecoverable the moment
you move on (worse than the code diff: that at least survives in reflog for
a while). Because the tsv/JSON pair is committed as part of the LOG commit
(never `git reset --hard`, unlike the code commit), it survives permanently
regardless of whether the code was kept, discarded, or crashed.

## The experiment loop

Each experiment produces exactly two commits: one for the code change
(`ai_drive_task.gd`), one for the log (`results.tsv`) — kept separate so
`ai_drive_task.gd`'s own git history only ever shows genuine improvements
(clean `git log res://ai/ai_drive_task.gd` = clean improvement history),
while `results.tsv`'s history has a permanent row for every attempt.

LOOP:

1. Look at git state (current branch/commit).
2. Tune `res://ai/ai_drive_task.gd` with one experimental idea.
3. `tools/check_allowlist.sh` — must pass before committing.
4. `git commit -m "try: <one-line hypothesis>"` (code-only commit; message
   gets amended below if kept, so it's fine if this first pass is terse).
5. Run the eval command above, capturing stdout: `... > run.log 2>&1`
   (redirect everything, don't let output flood context).
6. Parse the LAST line of `run.log` as JSON. Read `ok`, `aggregate_score`,
   `mean_score`, and each vehicle's `fair` flag. Copy that same JSON line
   into `runs/<hash>.json`, where `<hash>` is the short hash of the code
   commit from step 4 (e.g. `mkdir -p runs && tail -n1 run.log >
   runs/<hash>.json`) — this is the run's permanent record, committed in
   step 7/8/9 below alongside the tsv row. Treat this filename as
   PROVISIONAL: it's final for discard/crash (step 7/9, no amend happens),
   but step 8 (keep) renames it — see the note there.
7. If `ok` is false, treat as a crash — this covers actual crashes/timeouts
   AND fairness violations (`fair: false` on any vehicle), which are
   reported the same way on purpose: neither is an acceptable result.
   `git reset --hard HEAD~1` to discard the code commit (fix-and-retry
   first only if the cause is a trivial, obvious bug — a fairness violation
   almost never is; it means the idea itself was "go faster by cheating",
   which isn't a real idea, drop it). Then append a `crash` row to
   `results.tsv` and commit both: `git add results.tsv runs/<hash>.json &&
   git commit -m "log: crash - <hypothesis>"`. (If step 5 crashed before
   producing any JSON at all — no parseable last line — skip the
   `runs/<hash>.json` file for that row; note that in the description.)
8. Else if `aggregate_score` improved: `git commit --amend -m "<hypothesis>
   — aggregate_score X.XXXXXX (was Y.YYYYYY)"` to bake the real result into
   the code commit's message. `--amend` changes the code commit's hash —
   get the NEW hash now (`git rev-parse --short HEAD`) and rename the
   step-6 file to match (`git mv runs/<old-hash>.json runs/<new-hash>.json`
   — or just re-derive it fresh from `run.log`, same content either way).
   Use this NEW hash for both the `runs/` filename and the tsv row: it's
   the one that stays reachable on the branch and checkable-out going
   forward, unlike the pre-amend hash from step 4, which no longer is.
   (This is the one case where the two differ — discard/crash above never
   amend, so the step-4 hash there is already final.) Append a `keep` row
   to `results.tsv` and commit both: `git add results.tsv
   runs/<new-hash>.json && git commit -m "log: keep - aggregate_score
   X.XXXXXX (was Y.YYYYYY)"`.
9. Else (`aggregate_score` equal or worse): note the code commit's short
   hash for the tsv row, then `git reset --hard HEAD~1` to discard it.
   Append a `discard` row to `results.tsv` and commit both: `git add
   results.tsv runs/<hash>.json && git commit -m "log: discard -
   aggregate_score X.XXXXXX (was Y.YYYYYY)"`.
10. Repeat.

**To replay/audit later**: `git log --oneline` on this branch shows the
full sequence (interleaved code + log commits for every improvement, log
commits for every discard/crash); `cat results.tsv` shows the complete
table at any point in history (`git show <commit>:results.tsv`); `cat
runs/<hash>.json` gives the full per-vehicle telemetry for any single
experiment, kept or not; and since the eval is deterministic, any
surviving code commit (i.e. any `keep`) can also be checked out and
re-run to reproduce its exact score from scratch.

**Timeout**: budget ~5-6 minutes wall-clock per experiment (3 vehicles ×
~68s racing+countdown, plus engine startup). If a run meaningfully exceeds
that, kill it, log `crash`, and revert. If your tool invocation has its own
default command timeout (e.g. a coding agent's shell tool defaulting to
~120s), raise it explicitly (~400s) for the eval command — the default is
not enough and will truncate `run.log` mid-run.

## Analysis tools

The aggregate score tells you THAT a candidate is worse; these help figure
out WHY, without giving the policy anything that could affect scoring
(all purely observational):

- **`trace`**: every eval run already includes a tick-sampled array
  (position, speed, lateral offset, steering, engine force, ~every 0.5s)
  in each vehicle's result, and therefore in `runs/<hash>.json` for free —
  no extra step needed. Good first stop before reaching for anything else:
  `cat runs/<hash>.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['per_vehicle']['tow_truck']['trace'])"`
  (or similar) shows the shape of a trajectory without re-running anything.
- **`debug_events`**: `ai_drive_task.gd` may push short labels onto the
  blackboard var `"debug_events"` at moments worth marking (e.g. "recovery
  start") — see `README_RESEARCH.md`'s "Analysing a run" section for the
  exact snippet. Each push shows up timestamped in the eval JSON's
  `events` list. Cheap, safe to leave in permanently once added.
- **Screenshots**: when trace + events still don't explain a failure,
  `res://tests/capture_run.gd` runs ONE vehicle with real rendering and
  saves PNGs of what the player sees at the start, periodic checkpoints,
  each debug event, the fall, and the finish:

      /home/maitre/Documents/Godot_v4.7.2-stable_linux.x86_64 \
          --display-driver x11 --rendering-driver vulkan --resolution 640x360 \
          --path . --script res://tests/capture_run.gd -- \
          --vehicle=tow_truck --seconds=65 \
          --dir=runs/<hash>/tow_truck_capture

  Note this does NOT use `--headless` (its "dummy" rendering driver never
  produces real pixels — confirmed by testing; every screenshot would come
  back empty). This briefly opens a real window and is slower than the
  normal eval, so treat it as an on-demand diagnostic, not something to run
  every iteration: reach for it after a few discards in a row on the same
  vehicle without a clear read on why, not by default. If a Godot EDITOR
  instance is open on this project at the same time, expect this to be
  noticeably slower or to stall outright (observed directly: two Vulkan
  clients contending for the same GPU) — close the editor first if a run
  seems stuck, and give it a generous timeout (2-3 min) regardless. You (the agent) can
  view the resulting PNGs directly. `runs/**/*.png` is gitignored by
  default (a merely exploratory look is diagnostic scratch, not part of
  the permanent record, and an untracked PNG would otherwise trip
  `check_allowlist.sh` on your next commit). If a set of screenshots was
  genuinely instructive enough to keep, force-add it explicitly (`git add
  -f runs/<hash>/<vehicle>_capture/`) and commit it alongside that
  experiment's log commit, same as `runs/<hash>.json`.

**NEVER STOP** (once past setup): don't pause to ask "should I keep going?".
Iterate until the human interrupts you. If out of ideas: re-read
`ai_drive_task.gd`'s own comments for previously-tried-and-reverted ideas
(don't blindly repeat them without a new angle), try combining two small
wins, try a different corner of the track, or use the analysis tools above
if you need more signal than the aggregate.
