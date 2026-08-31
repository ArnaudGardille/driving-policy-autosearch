# Tier C — vision policy (image-only sensing)

Third leg of the perception-tier comparison documented in
`ai/COMPARISON.md`: a driving policy that sees only a camera image, no
`Path3D` curve (Tier A) and no whisker/proprioception sensors (Tier B).
**Status: Phase 1 only** (data capture + offline training). Phase 2
(closed-loop, the model actually driving the car for a real
`aggregate_score`) is deliberately not built yet — see "Phase 2" below.

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

`ai/vision/record_dataset.gd` runs a full race with the Tier A (curve-based)
policy as the deterministic expert, mounts a stable forward-facing camera
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

## Phase 2 — closed-loop (not built yet)

For a real, comparable `aggregate_score`, a trained model has to actually
drive the car: capture a frame every tick, run inference, apply
`(steering, engine_force)` through the same control surface Tiers A/B use.
No ONNX Runtime GDExtension or other Godot-side ML inference is installed
in this project. Recommended approach (over adding a native GDExtension
dependency): a local socket/IPC bridge — a `StreamPeerTCP` client in a new
`ai/vision/ai_drive_task_vision.gd`, talking to a small standalone Python
process holding the trained model on GPU. Needs a new non-headless eval
driver too (`ai/vision/run_eval_vision.gd`, same JSON contract as
`tests/run_eval.gd` but necessarily non-headless, since real pixels are
needed every tick — it still calls the frozen `AIBenchmark.run()` /
`compute_score()` underneath, so the "judge can't grade its own homework"
guarantee holds). **Explicitly deferred** — see `ai/COMPARISON.md` and
`PROGRAM.md`/plan history for the reasoning: this is new infra (sockets, a
long-running Python server, a slower non-headless eval mode) with real
open questions (inference latency budget, protocol) that deserves review
of the Phase 1 results before committing to it.
