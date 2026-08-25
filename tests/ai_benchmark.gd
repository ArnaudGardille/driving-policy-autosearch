extends RefCounted
class_name AIBenchmark
## Headless benchmark for the LimboAI race driver. Spins up a real race
## (countdown + racing) with the AI driving, and measures objective
## performance metrics independent of the manager's own off-track logic,
## so different AI/track tweaks can be A/B compared with real numbers.

## Runs the AI for `racing_seconds` of actual racing time (after the fixed
## countdown) and returns a Dictionary of performance metrics. `overrides` lets
## callers poke exported properties on the AIDriveTask (e.g. {"cross_track_gain": 0.0})
## for ablation testing without editing the script. `vehicle_scene_path` picks
## which car to drive -- a policy tuned against only one vehicle can look
## better than it is, so callers doing real comparisons should run this for
## every vehicle the human can actually pick and aggregate conservatively
## (e.g. minimum, not mean) across the results.
##
## `capture` (optional, off by default -- the normal fast/headless eval path
## is entirely unaffected) enables screenshot capture at key moments: run
## start, periodic checkpoints, agent-pushed debug events (see below), the
## fall moment, and the finish moment. Requires REAL rendering -- this does
## NOT work under `--headless` (its "dummy" rendering driver never produces
## actual pixels; `get_texture()` returns null). Call with
## `--display-driver x11 --rendering-driver vulkan` (or another real
## rendering driver) instead. Keys: `enabled: bool`, `dir: String` (output
## directory, created if missing), `interval_s: float` (periodic cadence,
## default 15.0), `max_shots: int` (safety cap on total screenshots, default
## 12 -- guards against a chatty debug_events stream filling the disk).
##
## `ai/` scripts (e.g. ai_drive_task.gd) may optionally push short string
## labels onto the blackboard var "debug_events" (append to the Array,
## creating it via set_var if absent) to mark moments worth a closer look --
## e.g. when a stuck-recovery maneuver triggers. This is purely observational
## and has zero effect on scoring: every event is timestamped and recorded
## in the output's "events" list, and (if capture is enabled) triggers a
## screenshot, but nothing here reads it back into the driving logic itself.
static func run(tree: SceneTree, racing_seconds: float, overrides: Dictionary = {},
		vehicle_scene_path: String = "res://vehicles/car_base.tscn",
		capture: Dictionary = {}) -> Dictionary:
	var race_scene: Node3D = preload("res://race/race_scene.tscn").instantiate()
	tree.root.add_child(race_scene)
	race_scene.ai_enabled = true

	var car: Node3D = (load(vehicle_scene_path) as PackedScene).instantiate()
	car.name = "car"

	# Let _ready() run for the freshly added subtree before calling start_race.
	await tree.process_frame
	# start_race() itself now awaits a couple of physics frames internally
	# (waiting for the racetrack's CSG collision to be ready), so it must be
	# awaited here too -- otherwise _car/_ai_driver are read before they're set.
	await race_scene.start_race(car)

	if not overrides.is_empty():
		var driver: BTPlayer = race_scene._ai_driver
		# BTPlayer runs a per-instance clone of the tree (get_bt_instance()),
		# not the shared on-disk resource, so overrides must target that.
		var root_task: BTAction = driver.get_bt_instance().get_root_task()
		for key: String in overrides:
			root_task.set(key, overrides[key])

	var path: Path3D = race_scene._path
	var vehicle: VehicleBody3D = race_scene._car
	var track_width: float = race_scene.TRACK_WIDTH

	var sum_lateral := 0.0
	var max_lateral := 0.0
	var off_track_ticks := 0
	var sample_count := 0
	var sum_speed := 0.0
	var max_speed := 0.0
	var min_car_y := INF
	var fell_off := false
	var fall_distance_m := -1.0

	# Tick-sampled trace: a lightweight "flight recorder" independent of
	# screenshot capture, cheap enough to always collect (no GPU needed,
	# works fine under --headless). Sampled at a fixed cadence rather than
	# every physics tick to keep the output small (~130 samples per vehicle
	# at the default 65s race) while still being enough to see the shape of
	# a trajectory or spot oscillation after the fact.
	const _TRACE_INTERVAL_S := 0.5
	var trace: Array = []
	var _next_trace_s := 0.0

	# Agent-writable event channel: ai_drive_task.gd may push short labels
	# onto the blackboard var "debug_events" (see class doc above). Drained
	# here every tick and timestamped; purely observational. Capped like
	# screenshots below -- unlike the (gitignored-by-default) screenshots,
	# "events" gets permanently committed into runs/<hash>.json every
	# experiment, so an unbounded push stream (e.g. one push per tick)
	# would bloat the repo's history forever, not just clutter one run.
	const _MAX_EVENTS := 100
	var events: Array = []
	var _events_seen := 0

	# Screenshot capture (see class doc above for the capture dict's keys).
	var _capture_enabled: bool = capture.get("enabled", false)
	var _capture_dir: String = capture.get("dir", "")
	var _capture_interval_s: float = capture.get("interval_s", 15.0)
	var _capture_max_shots: int = capture.get("max_shots", 12)
	var _next_capture_s := 0.0
	var _captured_fall := false
	var _captured_finish := false
	var screenshots: Array = []
	if _capture_enabled and _capture_dir != "":
		DirAccess.make_dir_recursive_absolute(_capture_dir)

	# Fairness enforcement: the allowlist (tools/check_allowlist.sh) stops a
	# candidate from editing vehicle.gd/race_manager.gd, but nothing stops
	# code living inside the allowed ai_drive_task.gd from just calling
	# car.engine_force / car.steering with values a human could never reach
	# (e.g. bumping its own "engine_power" export past the player's actual
	# ceiling). Since ai_drive_task.gd fully owns those properties every
	# tick while the AI drives (vehicle.gd's own _physics_process is
	# disabled), a file-level allowlist alone cannot catch that -- so this
	# checks the ACTUAL applied values against the car's own frozen physics
	# constants every tick, regardless of what the policy script claims.
	# Steering ceiling comes directly from the car (vehicle.gd's STEER_LIMIT
	# const), so it stays correct even if that constant ever changes.
	# Engine force ceiling is 100.0: vehicle.gd's own low-speed torque boost
	# is clampf(engine_force_value * 5.0 / speed, 0.0, 100.0), so 100.0 is
	# the highest engine_force a human can ever get from any speed, and is
	# therefore the correct fairness ceiling independent of speed or vehicle.
	const _ENGINE_FORCE_CEILING := 100.0
	const _FAIRNESS_TOLERANCE := 0.01
	var steer_limit: float = vehicle.STEER_LIMIT
	var max_abs_engine_force := 0.0
	var max_abs_steering := 0.0

	var total_ticks := int((race_scene.COUNTDOWN_DURATION + racing_seconds) * Engine.physics_ticks_per_second)

	for i in range(total_ticks):
		await tree.physics_frame
		if race_scene._state != 1: # RaceState.RACING
			continue

		var car_global: Vector3 = vehicle.global_position
		min_car_y = minf(min_car_y, car_global.y)
		if car_global.y < race_scene._fall_kill_y and not fell_off:
			fell_off = true
			fall_distance_m = race_scene._total_distance

		max_abs_engine_force = maxf(max_abs_engine_force, absf(vehicle.engine_force))
		max_abs_steering = maxf(max_abs_steering, absf(vehicle.steering))

		var car_local: Vector3 = path.global_transform.affine_inverse() * car_global
		var closest_offset: float = path.curve.get_closest_offset(car_local)
		var closest_point_local: Vector3 = path.curve.sample_baked(closest_offset)
		var closest_point_global: Vector3 = path.global_transform * closest_point_local
		var lateral: float = Vector2(car_global.x, car_global.z).distance_to(
				Vector2(closest_point_global.x, closest_point_global.z))

		sum_lateral += lateral
		max_lateral = maxf(max_lateral, lateral)
		sample_count += 1
		if lateral > track_width:
			off_track_ticks += 1

		var speed: float = vehicle.linear_velocity.length()
		sum_speed += speed
		max_speed = maxf(max_speed, speed)

		var race_time_now: float = sample_count / float(Engine.physics_ticks_per_second)

		if race_time_now >= _next_trace_s:
			trace.append({
				"t": race_time_now,
				"x": car_global.x,
				"z": car_global.z,
				"speed": speed,
				"lateral": lateral,
				"steering": vehicle.steering,
				"engine_force": vehicle.engine_force,
			})
			_next_trace_s += _TRACE_INTERVAL_S

		if is_instance_valid(race_scene._ai_driver):
			var bb = race_scene._ai_driver.get_blackboard()
			if bb and bb.has_var("debug_events"):
				var pushed: Array = bb.get_var("debug_events")
				while _events_seen < pushed.size() and events.size() < _MAX_EVENTS:
					var label: String = str(pushed[_events_seen])
					events.append({"tick": i, "t": race_time_now, "label": label})
					if _capture_enabled and screenshots.size() < _capture_max_shots:
						screenshots.append(_capture_shot(tree, _capture_dir,
								"%03d_event_%s" % [screenshots.size(), _sanitize_tag(label)]))
					_events_seen += 1

		if _capture_enabled and screenshots.size() < _capture_max_shots and race_time_now >= _next_capture_s:
			screenshots.append(_capture_shot(tree, _capture_dir, "%03d_t%.0fs" % [screenshots.size(), race_time_now]))
			_next_capture_s += _capture_interval_s

		if fell_off and not _captured_fall:
			_captured_fall = true
			if _capture_enabled and screenshots.size() < _capture_max_shots:
				screenshots.append(_capture_shot(tree, _capture_dir, "%03d_fell_off" % screenshots.size()))

		if not _captured_finish and race_scene._total_distance >= race_scene._track_length - race_scene.FINISH_LINE_MARGIN:
			_captured_finish = true
			if _capture_enabled and screenshots.size() < _capture_max_shots:
				screenshots.append(_capture_shot(tree, _capture_dir, "%03d_finish" % screenshots.size()))

	var fair_steering: bool = max_abs_steering <= steer_limit + _FAIRNESS_TOLERANCE
	var fair_engine_force: bool = max_abs_engine_force <= _ENGINE_FORCE_CEILING + _FAIRNESS_TOLERANCE
	var fair: bool = fair_steering and fair_engine_force

	# race_manager's own state machine actually ran (fall/finish/off-track
	# checks included), so infer the outcome from its own thresholds rather
	# than re-deriving it, keeping the benchmark's score consistent with
	# what a real race would report.
	var distance: float = race_scene._total_distance
	var track_length: float = race_scene._track_length
	var reason: String
	if distance >= track_length - race_scene.FINISH_LINE_MARGIN:
		reason = "won"
	elif fell_off:
		reason = "fell_off"
	else:
		reason = "time_up" # Also covers off_track; scored identically either way.
	# Each sampled tick is one physics tick of actual RACING time, so this is
	# the true elapsed racing time even if the run ended before racing_seconds.
	var race_time: float = sample_count / float(Engine.physics_ticks_per_second)
	var race_manager_script: GDScript = preload("res://race/race_manager.gd")
	var score: float = race_manager_script.compute_score(reason, distance, track_length, race_time, racing_seconds)

	var result := {
		"distance_m": distance,
		"avg_lateral_offset_m": (sum_lateral / sample_count) if sample_count > 0 else 0.0,
		"max_lateral_offset_m": max_lateral,
		"pct_time_off_track": (100.0 * off_track_ticks / sample_count) if sample_count > 0 else 0.0,
		"avg_speed_mps": (sum_speed / sample_count) if sample_count > 0 else 0.0,
		"max_speed_mps": max_speed,
		"fell_off_track": fell_off,
		"fall_distance_m": fall_distance_m,
		"racing_ticks_sampled": sample_count,
		"reason": reason,
		"race_time_s": race_time,
		"score": score,
		"fair": fair,
		"max_steering_used": max_abs_steering,
		"steer_limit": steer_limit,
		"max_engine_force_used": max_abs_engine_force,
		"engine_force_ceiling": _ENGINE_FORCE_CEILING,
		"trace": trace,
		"events": events,
		"screenshots": screenshots,
	}

	race_scene.queue_free()
	return result


## Captures the current frame (whatever the active camera sees -- i.e. the
## same view the player would have) and saves it as a PNG. Returns the saved
## path, or "" if capture isn't actually possible right now (e.g. running
## under --headless, where the rendering driver is "dummy" and never
## produces real pixels -- silently skipped rather than crashing the eval,
## since capture is an optional diagnostic extra, not part of scoring).
## Strips a debug_events label down to safe filename characters (alnum,
## underscore, hyphen). Labels come from ai/ scripts, which are allowed to
## push arbitrary strings -- without this, a label containing "/" or ".."
## could write a screenshot outside the intended capture directory. (Not
## String.is_valid_identifier() per-character -- that rejects digits when
## checked alone, since identifiers can't START with one; a plain
## character-class check is what's actually needed here.)
static func _sanitize_tag(s: String) -> String:
	var re := RegEx.new()
	re.compile("[^A-Za-z0-9_-]")
	var out: String = re.sub(s, "_", true)
	return out.substr(0, 40) if out.length() > 40 else out


static func _capture_shot(tree: SceneTree, dir: String, tag: String) -> String:
	var viewport_texture: ViewportTexture = tree.root.get_texture()
	if viewport_texture == null:
		return ""
	var img: Image = viewport_texture.get_image()
	if img == null:
		return ""
	var path: String = dir.path_join(tag + ".png")
	img.save_png(path)
	return path
