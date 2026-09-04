# Tier C — vision policy (image-only sensing)

Third leg of the perception-tier comparison documented in
`ai/COMPARISON.md`: a driving policy that sees only a camera image, no
`Path3D` curve (Tier A) and no whisker/proprioception sensors (Tier B).
**Status: Phase 1 + Phase 2 built.** Phase 1 is data capture + offline
training. Phase 2 is closed-loop: the trained model actually drives the
car in real time, for a real, directly comparable `aggregate_score` — see
"Phase 2" below.

## Repo split (why training code isn't all in one place)

`tools/check_allowlist.sh` only allows changes under `res://ai/` on a
research branch. That's fine for anything that has to run *inside* Godot,
but wrong for a PyTorch training pipeline: committing raw captured frames
and intermediate checkpoints to git on every iteration would bloat branch
history fast (unlike the tiny per-experiment JSON blobs Tier A/B commit).

- **`ai/vision/`** (this directory, committed): everything that must
  execute inside Godot — `record_dataset.gd` (data capture) and, in Phase
  2, the closed-loop inference driver.
- **`/home/maitre/Documents/Godot/truck-town-vision-training/`** (sibling
  directory, **not** git-tracked in this repo): the actual training
  pipeline — raw captured frames, manifests, `train.py`, checkpoints.
  Structurally modeled on `/home/maitre/Documents/Godot/autoresearch/`
  (same "constants → model → timed loop → parseable summary" shape), just
  without the git link, same as that project has no link back here.
  Once a model is stable, only the final small deployment artifact
  (weights + a serving script) would be copied into `ai/vision/` and
  committed — small and reproducible, heavy/iterative training junk stays
  out of this repo's history.

## Phase 1 — data capture + offline training

### 1. Capture (image, action) pairs from an expert demonstrator

`ai/vision/record_dataset.gd` runs a full race with whichever policy is
currently checked into `ai/ai_drive_task.gd` (Tier A or Tier B — see
`ai/COMPARISON.md`'s dataset notes for which runs came from which; the
dataset is expert-agnostic and can mix demonstrators) as the deterministic
expert, mounts a stable forward-facing camera
on the car at runtime (the car's existing chase camera reorients every
frame — unusable as a consistent observation for a vision model, see the
script's own header comment for why), and records one (image, steering,
engine_force) triple every 0.5s, aligned with `tests/ai_benchmark.gd`'s own
internal trace sampling.

**Requires real rendering — do NOT run under `--headless`** (produces a
"dummy" driver with no real pixels, same constraint as
`tests/capture_run.gd`):

```
godot --display-driver x11 --rendering-driver vulkan --resolution 320x180 \
    --path <repo> --script res://ai/vision/record_dataset.gd -- \
    --vehicle=car_base --dir=/home/maitre/Documents/Godot/truck-town-vision-training/data/car_base_run1 \
    --seconds=65
```

Repeat per vehicle (`car_base`, `trailer_truck`, `tow_truck`) and ideally
across a few runs each (Jolt's non-determinism, see `PROGRAM.md`'s
Determinism caveat, means repeated runs of the same expert policy aren't
identical trajectories — that's actually useful here, it's free additional
coverage of the track rather than an exact duplicate). Writes
`<dir>/manifest.json`: `{"pairs": [{"image", "t", "steering",
"engine_force"}, ...], "score", "fair", "reason"}`.

If a Godot **editor** is open on this project at the same time, expect
this to be noticeably slower or to stall (two Vulkan clients contending
for one GPU) — close it first if a run seems stuck.

### 2. Train (external, `truck-town-vision-training/`)

A small CNN mapping image → `(steering, engine_force)`, normalized against
the car's real ranges (`steering ∈ [-0.4, 0.4]` — `vehicle.gd`'s
`STEER_LIMIT`; `engine_force ∈ [-100, 100]` — the same low-speed-boost
ceiling `tests/ai_benchmark.gd` uses as its fairness check). Structure
modeled on `autoresearch/train.py`: constants block → model → optimizer →
fixed wall-clock time-budget loop → NaN/fail-fast → a final parseable
summary block. **Deliberate departure from that template**: `train.py` is
ephemeral by design (no checkpointing, only the metric is logged) — this
pipeline *must* checkpoint, since the model has to be reloadable for Phase
2 closed-loop inference. `autoresearch/prepare.py`'s reusable
infinite-generator dataloader pattern is directly reusable for loading
`manifest.json` (image, action) pairs.

**Phase 1 metric**: mean-absolute prediction error (steering,
engine_force) on trajectories held out from training. This is an offline
proxy, **not** an `aggregate_score` — record it in `ai/COMPARISON.md`
explicitly marked as non-comparable to Tier A/B. It answers "does the
pipeline work at all", not "how well would this drive."

## Phase 2 — closed-loop (built)

The trained model drives the car in real time: capture a frame, run
inference, apply `(steering, engine_force)` through the same control
surface Tiers A/B use, every `decision_interval_s` seconds (default 0.1s,
holding the last action in between — see `vision_drive_task.gd`'s own doc
comment for why). No ONNX Runtime GDExtension or other Godot-side ML
inference was added — as planned, a local TCP bridge instead:

- **`../truck-town-vision-training/infer_server.py`** (external, not
  tracked here): loads `checkpoints/vision_policy.pt`, listens on a local
  socket, and serves `(image) -> (steer, engine_force)` predictions. Must
  already be running (`uv run infer_server.py`) before a Phase 2 eval is
  invoked. Resizes incoming frames with PIL to match `prepare.py`'s
  training preprocessing exactly (train/inference parity), rather than
  trusting Godot's own, different, resize algorithm.
- **`ai/vision/vision_inference_client.gd`** — `StreamPeerTCP` wrapper,
  the Godot side of that bridge. Fixed binary framing (no JSON), one
  persistent connection reused for the whole race.
- **`ai/vision/vision_drive_task.gd`** — the actual driving policy, a
  `BTAction` like Tiers A/B, mounted via `ai/vision/vision_driver.tscn` +
  `vision_drive_tree.tres`. Reads only `"car"` from the blackboard — no
  curve, no onboard sensors, only the camera. Mounts the same stable
  forward-facing camera `record_dataset.gd` used for capture (same
  position/rotation/FOV constants, duplicated with a comment explaining
  why — see the file), so the live view matches the training
  distribution.
- **`ai/vision/run_eval_vision.gd`** — non-headless eval driver, same JSON
  contract as `tests/run_eval.gd` (`per_vehicle`, `mean_score`,
  `aggregate_score`, `fair`/`ok`). One thing the original plan got wrong:
  it can't just call the frozen `AIBenchmark.run()` underneath, because
  that helper always attaches whichever policy is currently checked into
  `ai/ai_drive_task.gd` via `race_manager.gd`'s `_setup_ai_driver()`, with
  no hook to substitute a different driver. Instead this script lets
  `start_race()` attach the default driver as usual, then immediately
  swaps it for `vision_driver.tscn` (the same "reach into `race_scene`'s
  fields from allowed `ai/` tooling" trick `record_dataset.gd` already
  uses to add its own camera), and runs its own scoring/fairness tick
  loop — a close copy of `AIBenchmark.run()`'s, so the numbers stay
  directly comparable.

**Cost**: unlike headless A/B eval (~12 runs/hour), this cannot run faster
than real time — every decision needs an actually-rendered frame. A 65s
race takes ~65s wall-clock, plus per-vehicle startup overhead. Budget
accordingly; this is not a fast iteration loop.

**Known Phase 1 limitation carried into Phase 2**: the training dataset
never captured brake actions (only `steering`/`engine_force`), so the
model has no brake output — `vision_drive_task.gd` always sets
`car.brake = 0.0`. Also no stuck/recovery logic yet, unlike Tiers A/B —
this is the first working closed-loop version, scoped to proving the
pipeline works, not yet feature-matched with the sensor tiers.

## DAgger iteration (built)

`ai/vision/dagger_collect.gd` closes the loop Phase 2 leaves open: it runs
the CURRENT closed-loop policy for real (same driver-swap as
`run_eval_vision.gd`) and, at each capture instant, relabels the state the
policy actually visited with what the Tier A expert (`ai/tier_a_drive_task.gd`)
would have done from that exact pose -- no second race needed, since
`_drive(car, path, delta)` is a near-pure function of the car's current
transform, callable directly (steering/engine_force/brake saved and
restored around the call so the real drive is never disturbed). Only
captures states within `TRACK_WIDTH` of the track centerline -- states the
car visits once already well off-track produce unreliable expert opinions
(Tier A's own bounded localization search isn't designed to reason about
that regime). Same non-headless requirement and cost profile as
`record_dataset.gd`/`run_eval_vision.gd`.

```
godot --display-driver x11 --rendering-driver vulkan --resolution 320x180 \
    --path <repo> --script res://ai/vision/dagger_collect.gd -- \
    --vehicle=car_base --dir=/abs/path/to/data/dagger_rN_car_base \
    [--seconds=65] [--host=127.0.0.1] [--port=8765] [--decision_interval=0.1]
```

Loop: collect (all 3 vehicles) with `infer_server.py` serving the current
checkpoint -> merge the new run directories into `data/` -> `uv run train.py`
-> re-serve the new checkpoint -> `run_eval_vision.gd` to score it -> repeat
with the new checkpoint as the next round's demonstrator. `train.py` now
fixes a random seed (see its own comment) specifically so this comparison
is meaningful round to round -- without it, training-init variance alone
swings the closed-loop score by as much as a real dataset change does.
Results, the two bugs found along the way, and the final numbers are in
`ai/COMPARISON.md`.

Results are in `ai/COMPARISON.md`.
