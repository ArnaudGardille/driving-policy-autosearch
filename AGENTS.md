# AGENTS.md

Entry point for any coding agent working in this repo. See `README.md` for
what the game itself is; this file is about how to work here effectively.

## Project basics

- Godot 4 (4.7.2), GDScript, Jolt Physics. Engine binary on this machine:
  `/home/maitre/Documents/Godot_v4.7.2-stable_linux.x86_64` (if it's moved,
  `which godot` or check the project's usual launch shortcut).
- Three drivable vehicles, all sharing the same `vehicle.gd` control surface
  (steering/engine_force/brake) but different physical rigs:
  - `car_base` — a plain `VehicleBody3D`.
  - `trailer_truck` — tractor + trailer joined by a single constrained joint
    (rigid-ish articulation, like a real semi hitch).
  - `tow_truck` — **not a semi-trailer**. It drags a second, fully passive
    `VehicleBody3D` (no steering/engine script of its own) behind it on a
    5-segment chain of `RigidBody3D`s pinned together with `PinJoint3D`s (see
    `README.md`'s "How does it work?" and `vehicles/tow_truck.tscn`). This
    matters a lot for anything touching AI driving or vehicle balance: the
    towed car only follows via chain tension + its own momentum, so it swings
    much more than a rigid trailer on tight turns and has no way to correct
    itself.

## Jolt Physics is NOT bit-for-bit deterministic

This project uses Jolt's default multi-threaded solver. The exact same
committed code, re-run minutes apart with zero changes, can produce different
outcomes (confirmed directly, repeatedly) — contact resolution order varies
with OS thread scheduling. Invisible for a comfortable margin, real for
anything sitting close to one (which is exactly what tuning loops tend to
converge on). **Never trust a single good run** as proof of an improvement in
physics-dependent work here — re-run at least 3x before believing it. See the
"Determinism caveat" in `PROGRAM.md` for the fuller writeup and the
`--repeats=N` mechanism in `tests/run_eval.gd` built specifically for this.

## Active initiative: autonomous driving-policy research

There's an ongoing autoresearch-style loop (adapted from
[karpathy/autoresearch](https://github.com/karpathy/autoresearch)) tuning
`ai/ai_drive_task.gd` to drive all three vehicles as fast as possible without
cheating. If you're picking up that work:

- Read `PROGRAM.md` first — full loop spec, guardrails, logging protocol.
- Read `ai/README_RESEARCH.md` — the contract (objective, scoring, what
  may/mayn't change).
- `tools/check_allowlist.sh` enforces the sandbox: only `ai/` may change.
  Run it before every commit in that loop.
- `results.tsv` + `runs/<hash>.json` are the permanent experiment log —
  check them before starting a new idea so you don't re-try something
  already proven not to work.

## Concurrent branches/worktrees

Multiple agents/sessions are often working this repo at once, each in its
own `git worktree` off a differently-named branch (e.g. `autoresearch/aug31`,
`autoresearch/tier-b-aug31`, `feature/random-track-generation-clean`).
`git worktree list` from any checkout shows what's currently active.

**Always work in a dedicated worktree, never directly in another
session's checkout** — even read-only-looking git commands (`git branch -f`,
`git fetch . x:branch`) can corrupt a checkout that has a different session's
uncommitted work or stale index. If you need a branch that's already checked
out elsewhere, branch off its tip into a new worktree instead
(`git worktree add ../truck-town-demo-<tag> -b <new-branch> <existing-branch>`)
and merge back with `git merge --ff-only` once you're done, from the
directory that actually has the target branch checked out.

Before touching any file, `git status` — an open Godot editor on this
project periodically re-touches `PROGRAM.md` with whitespace-only
reformatting (leading spaces to tabs); that's harmless editor noise, safe to
`git checkout --` before committing anything real, not another session's
work. But don't assume that about files outside `PROGRAM.md`: investigate
unfamiliar modified/untracked state before discarding anything.

## Rendering

`--headless` uses a dummy rendering driver that never produces real pixels
(`get_texture()` returns null) — fine for scoring runs, useless for
screenshots. For visual capture, use `res://tests/capture_run.gd` with
`--display-driver x11 --rendering-driver vulkan` and a real display (see
`PROGRAM.md`'s "Analysis tools" section). Expect it to be slow or stall if a
Godot editor is open on the same project at the same time (GPU contention
between two Vulkan clients) — close the editor first if it seems stuck.
