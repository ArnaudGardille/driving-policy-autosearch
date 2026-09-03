extends SceneTree
## Tier C Phase 1: records (camera image, action) pairs from a deterministic
## expert demonstrator (whichever policy is currently checked into
## ai/ai_drive_task.gd -- Tier A or Tier B, see ai/COMPARISON.md for which
## runs came from which) driving a full race, for OFFLINE imitation-learning
## training of a vision policy
## in the external truck-town-vision-training/ pipeline. See
## ai/vision/README.md for the full Tier C plan and the repo/non-repo split.
##
## Modeled on tests/capture_run.gd's non-headless capture pattern, but lives
## under ai/ -- a new file under tests/ would fail tools/check_allowlist.sh
## (only res://ai/ is a legal change target for this research sandbox).
##
## Zero changes to any frozen file: reuses the exact same public
## AIBenchmark.run() API that tests/run_eval.gd and tests/capture_run.gd
## already call. Two things this script adds on top of capture_run.gd:
##
## 1. A dedicated, STABLE forward-facing recording camera, mounted at
##    runtime as a child of the car. The car's existing
##    Body/CameraBase/Camera3D (vehicles/follow_camera.gd) is a
##    reorienting third-person chase cam -- fine for a human player, but a
##    moving/rotating viewpoint is a bad observation for a vision policy to
##    learn from. vehicles/*.tscn is frozen, so this camera can't be added
##    to the scene file; it's added here instead, at runtime, from
##    allowed ai/ code (car.add_child(...) from a script under ai/ is
##    known-safe, see ai/README_RESEARCH.md history).
## 2. `capture.interval_s` is set to match AIBenchmark's own internal trace
##    cadence (ai_benchmark.gd's `_TRACE_INTERVAL_S = 0.5`) so each
##    screenshot lines up tick-for-tick with a `trace` entry (which already
##    carries `steering`/`engine_force`) -- no separate action-logging
##    needed. AIBenchmark also takes a few OFF-cadence screenshots (fell_off,
##    finish, debug_events -- neither Tier A's nor Tier B's ai_drive_task.gd
##    currently pushes debug_events, so only fell_off/finish apply here); those are filtered
##    out by filename pattern in _build_manifest() before pairing, so the
##    kept pairs stay exactly aligned with `trace`.
##
## REQUIRES REAL RENDERING, same constraint as capture_run.gd -- do NOT run
## with --headless (the "dummy" rendering driver never produces real
## pixels). If a Godot EDITOR is open on this project at the same time,
## expect this to be noticeably slower or to stall (two Vulkan clients
## contending for one GPU) -- close it first if a run seems stuck.
##
##   godot --display-driver x11 --rendering-driver vulkan --resolution 320x180 \
##       --path <repo> --script res://ai/vision/record_dataset.gd -- \
##       --vehicle=car_base --dir=/abs/path/to/dataset/car_base_run1 \
##       [--seconds=65] [--overrides={}]
##
## Writes <dir>/manifest.json: {"pairs": [{"image","t","steering",
## "engine_force"}, ...], "score", "fair", "reason"}. Prints a short JSON
## summary as the last stdout line and exits non-zero if the run was unfair
## or zero pairs were recorded (e.g. ran under --headless by mistake).

const VEHICLE_SCENES := {
	"car_base": "res://vehicles/car_base.tscn",
	"trailer_truck": "res://vehicles/trailer_truck.tscn",
	"tow_truck": "res://vehicles/tow_truck.tscn",
}

const DEFAULT_RACING_SECONDS := 65.0
## Must match ai_benchmark.gd's own _TRACE_INTERVAL_S -- see class doc above.
const TRACE_INTERVAL_S := 0.5
## Extra headroom (beyond the interval-cadence count) for the one-off
## fell_off/finish/debug_event shots AIBenchmark also takes.
const MAX_SHOTS_MARGIN := 20

## Runtime-mounted recording camera: local mount point in the car's own
## reference frame (roughly windshield height, a bit back from the nose),
## aimed down the car's forward direction. vehicle.gd applies turbo thrust
## along `global_transform.basis.z`, confirming the car's forward is local
## +Z -- but Camera3D looks down its own local -Z by default, hence the
## 180-degree yaw below.
const CAMERA_LOCAL_POSITION := Vector3(0.0, 1.1, 0.6)
const CAMERA_LOCAL_ROTATION_DEG := Vector3(0.0, 180.0, 0.0)
const CAMERA_FOV := 80.0


func _init() -> void:
	var args := _parse_args()

	var vehicle_key: String = String(args.get("vehicle", "car_base"))
	if not VEHICLE_SCENES.has(vehicle_key):
		push_error("Unknown vehicle '%s'. Valid: %s" % [vehicle_key, ", ".join(VEHICLE_SCENES.keys())])
		quit(1)
		return

	var dir: String = String(args.get("dir", ""))
	if dir == "":
		push_error("--dir=<output directory> is required (where frames + manifest.json go).")
		quit(1)
		return

	var racing_seconds: float = DEFAULT_RACING_SECONDS
	if args.has("seconds"):
		racing_seconds = String(args["seconds"]).to_float()

	var overrides := {}
	if args.has("overrides"):
		var parsed: Variant = JSON.parse_string(String(args["overrides"]))
		if parsed is Dictionary:
			overrides = parsed
		else:
			push_error("--overrides must be a JSON object, got: %s" % args["overrides"])
			quit(1)
			return

	var dir_abs: String = ProjectSettings.globalize_path(dir) if dir.begins_with("res://") else dir
	# Sized from the ACTUAL racing_seconds, not a fixed constant -- a cap
	# sized only for the 65s default silently truncated the dataset's tail
	# on longer --seconds captures (AIBenchmark's screenshot cap stops
	# adding shots once hit, while `trace` keeps growing unbounded, and
	# _build_manifest() below only warns about the mismatch, it doesn't
	# fail loudly).
	var max_shots: int = int(racing_seconds / TRACE_INTERVAL_S) + MAX_SHOTS_MARGIN
	var capture := {
		"enabled": true,
		"dir": dir_abs,
		"interval_s": TRACE_INTERVAL_S,
		"max_shots": max_shots,
	}

	# Runs concurrently with AIBenchmark.run() below (fire-and-not-awaited-
	# here) -- swaps in the recording camera the moment it's safe to, without
	# needing to hook into AIBenchmark's internals.
	_mount_camera_when_ready()

	var result: Dictionary = await AIBenchmark.run(
			self, racing_seconds, overrides, VEHICLE_SCENES[vehicle_key], capture)

	var manifest: Dictionary = _build_manifest(result)

	DirAccess.make_dir_recursive_absolute(dir_abs)
	var manifest_path: String = dir_abs.path_join("manifest.json")
	var f := FileAccess.open(manifest_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(manifest, "  "))
		f.close()

	var pairs_recorded: int = manifest["pairs"].size()
	var ok: bool = result.get("fair", false) and pairs_recorded > 0
	if pairs_recorded == 0:
		push_warning("record_dataset: 0 pairs recorded. Did you forget to drop --headless " +
				"and pass --display-driver x11 --rendering-driver vulkan (or similar)?")

	print(JSON.stringify({
		"ok": ok,
		"vehicle": vehicle_key,
		"pairs_recorded": pairs_recorded,
		"score": result.get("score", 0.0),
		"fair": result.get("fair", false),
		"manifest": manifest_path,
	}))
	quit(0 if ok else 1)


## Waits for the car to exist (group "car", set in every vehicle .tscn --
## see vehicle.gd), then waits a further fixed WALL-CLOCK margin before
## mounting+activating the recording camera, so this camera's own
## make_current() call is the one that sticks. race_manager.gd's
## start_race() calls make_current() on the car's default chase camera
## during its own setup; since that timing isn't exposed to hook into
## directly, this polls instead. There's a full COUNTDOWN_DURATION (3s)
## before AIBenchmark.run() starts sampling/capturing anything, so a
## real-time margin here is comfortably safe.
##
## Deliberately a TIME-based wait (create_timer), not a process-frame-count
## loop: this project's own docs (this file's header, and
## tests/capture_run.gd's) call out that an open Godot editor makes runs
## "noticeably slower" via GPU contention -- and under that exact slowdown,
## Godot's physics-catchup runs MULTIPLE physics ticks per rendered process
## frame to keep up. COUNTDOWN_DURATION is measured in physics ticks, so a
## process-frame-count margin can complete AFTER those 3s/180 ticks have
## already elapsed and AIBenchmark has started capturing -- silently
## poisoning the first interval screenshot(s) with the wrong (still
## reorienting-chase-cam) view. A real-time timer doesn't have that failure
## mode: physics ticks catching up doesn't make wall-clock time pass faster.
func _mount_camera_when_ready() -> void:
	var car: Node = null
	for i in range(600): # up to ~10s at 60fps -- generous, this is a poll not a deadline
		car = get_first_node_in_group("car")
		if car:
			break
		await process_frame
	if not car:
		push_warning("record_dataset: car never appeared in group 'car' -- recording camera not mounted, screenshots will show the default chase cam instead.")
		return

	await create_timer(1.5).timeout

	var recording_camera := Camera3D.new()
	recording_camera.fov = CAMERA_FOV
	recording_camera.position = CAMERA_LOCAL_POSITION
	recording_camera.rotation_degrees = CAMERA_LOCAL_ROTATION_DEG
	car.add_child(recording_camera)
	recording_camera.make_current()


## Pairs each interval-cadence screenshot with its matching trace sample --
## see the "2." point in the class doc above for why filtering by filename
## pattern first is what keeps this alignment exact rather than approximate.
func _build_manifest(result: Dictionary) -> Dictionary:
	var trace: Array = result.get("trace", [])
	var screenshots: Array = result.get("screenshots", [])

	# Fully anchored to the EXACT interval-shot filename shape
	# ("%03d_t%.0fs.png", from ai_benchmark.gd's _capture_shot()) -- a
	# suffix-only match ("_t\d+s.png$") would also match an off-cadence
	# debug_events shot whose label happens to end that way (e.g.
	# "003_event_stuck_recovery_t3s.png"), silently pairing it into `trace`
	# alignment as if it were a real interval shot. Dormant today only
	# because Tier A's ai_drive_task.gd currently pushes no debug_events.
	var re := RegEx.new()
	re.compile("^\\d+_t\\d+s\\.png$")
	var interval_shots: Array = []
	for path: String in screenshots:
		if path != "" and re.search(path.get_file()):
			interval_shots.append(path)

	var pair_count: int = mini(trace.size(), interval_shots.size())
	if pair_count < trace.size() or pair_count < interval_shots.size():
		push_warning("record_dataset: trace (%d) and interval screenshots (%d) don't match 1:1 -- keeping only the first %d aligned pairs." % [trace.size(), interval_shots.size(), pair_count])

	var pairs: Array = []
	for i in range(pair_count):
		var sample: Dictionary = trace[i]
		pairs.append({
			"image": interval_shots[i],
			"t": sample["t"],
			"steering": sample["steering"],
			"engine_force": sample["engine_force"],
		})

	return {
		"pairs": pairs,
		"score": result.get("score", 0.0),
		"fair": result.get("fair", false),
		"reason": result.get("reason", ""),
	}


func _parse_args() -> Dictionary:
	var result := {}
	for raw: String in OS.get_cmdline_user_args():
		var s := raw
		if s.begins_with("--"):
			s = s.substr(2)
		var eq := s.find("=")
		if eq == -1:
			result[s] = true
		else:
			result[s.substr(0, eq)] = s.substr(eq + 1)
	return result
