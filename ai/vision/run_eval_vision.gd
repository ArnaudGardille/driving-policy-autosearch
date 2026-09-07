extends SceneTree
## Tier C Phase 2: closed-loop eval driver for the vision policy. Mirrors
## tests/run_eval.gd's JSON output contract exactly (same keys: "ok",
## "per_vehicle", "mean_score", "aggregate_score", same per-vehicle fields:
## "score", "fair", "max_steering_used", "steer_limit",
## "max_engine_force_used", "engine_force_ceiling", "trace") so Tier C
## Phase 2 results are directly comparable to Tier A/B's, no schema
## conversion needed. See ai/COMPARISON.md.
##
## Can't reuse tests/ai_benchmark.gd's AIBenchmark.run() as-is: that helper
## always drives via race_manager.gd's own _setup_ai_driver(), which always
## attaches whichever policy is currently checked into ai/ai_drive_task.gd
## (Tier A or B) -- there is no hook to substitute a different driver, and
## tests/ai_benchmark.gd is a frozen file (see ai/README_RESEARCH.md), not
## something this sandbox may edit to add one. Instead this script lets
## start_race() attach the default driver as normal, then immediately
## swaps it out for ai/vision/vision_driver.tscn (same trick
## ai/vision/record_dataset.gd already uses to add its own recording
## camera to the car after start_race() returns -- reaching into
## race_scene's own fields from allowed ai/ tooling is an established,
## known-safe pattern in this codebase). The scoring/fairness-tracking tick
## loop below is intentionally a close copy of AIBenchmark.run()'s (same
## semantics, so the two are comparable), minus screenshot capture (not
## needed for scoring) and minus the debug_events channel (the vision
## policy doesn't push any).
##
## REQUIRES REAL RENDERING (the camera the vision policy drives from needs
## actual pixels) -- do NOT run with --headless. Also, unlike run_eval.gd,
## this CANNOT run faster than real time: every decision needs a real
## rendered frame, so a 65s race takes ~65s wall-clock. Budget accordingly;
## this is not a fast iteration loop the way headless A/B eval is.
##
##   godot --display-driver x11 --rendering-driver vulkan \
##       --path <repo> --script res://ai/vision/run_eval_vision.gd -- \
##       --seconds=65 --vehicles=car_base,trailer_truck,tow_truck \
##       [--host=127.0.0.1] [--port=8765] [--decision_interval=0.1] \
##       [--repeats=1]
##
## infer_server.py (../truck-town-vision-training/) must already be
## running and listening on --host:--port before this is invoked.

const VEHICLE_SCENES := {
	"car_base": "res://vehicles/car_base.tscn",
	"trailer_truck": "res://vehicles/trailer_truck.tscn",
	"tow_truck": "res://vehicles/tow_truck.tscn",
}

const DEFAULT_RACING_SECONDS := 65.0
const _TRACE_INTERVAL_S := 0.5
const _ENGINE_FORCE_CEILING := 100.0 # See ai_benchmark.gd's own doc comment for why this exact ceiling.
const _FAIRNESS_TOLERANCE := 0.01


func _init() -> void:
	var args := _parse_args()
	var ok := true

	var racing_seconds: float = DEFAULT_RACING_SECONDS
	if args.has("seconds"):
		racing_seconds = String(args["seconds"]).to_float()

	var host: String = String(args.get("host", "127.0.0.1"))
	var port: int = String(args.get("port", "8765")).to_int()
	var decision_interval: float = String(args.get("decision_interval", "0.1")).to_float()

	var vehicle_keys: Array = VEHICLE_SCENES.keys()
	if args.has("vehicles"):
		vehicle_keys = String(args["vehicles"]).split(",", false)

	var repeats: int = 1
	if args.has("repeats"):
		repeats = String(args["repeats"]).to_int()

	var per_vehicle := {}
	var scores: Array[float] = []

	for key: String in vehicle_keys:
		if not VEHICLE_SCENES.has(key):
			push_error("Unknown vehicle '%s'. Valid: %s" % [key, ", ".join(VEHICLE_SCENES.keys())])
			ok = false
			continue

		var runs: Array = []
		var worst_score := INF
		var worst_run: Dictionary = {}
		var all_fair := true
		var unfair_run: Dictionary = {}
		for _r in range(maxi(repeats, 1)):
			var result: Dictionary = await _run_vehicle(
					key, racing_seconds, host, port, decision_interval)
			runs.append(result)
			if not result.get("fair", false):
				all_fair = false
				if unfair_run.is_empty():
					unfair_run = result
			var s: float = result.get("score", 0.0)
			if s < worst_score:
				worst_score = s
				worst_run = result

		var summary: Dictionary = worst_run.duplicate()
		summary["score"] = worst_score
		summary["fair"] = all_fair
		if repeats > 1:
			summary["repeats"] = runs
		per_vehicle[key] = summary
		scores.append(summary.get("score", 0.0))
		if not summary.get("fair", false):
			ok = false
			push_error("FAIRNESS VIOLATION on '%s': max_steering_used=%.3f (limit %.3f), max_engine_force_used=%.3f (ceiling %.3f)" % [
				key, unfair_run.get("max_steering_used", 0.0), unfair_run.get("steer_limit", 0.0),
				unfair_run.get("max_engine_force_used", 0.0), unfair_run.get("engine_force_ceiling", 0.0)])

	var mean_score := 0.0
	var min_score := 0.0
	if scores.size() > 0:
		min_score = INF
		for s: float in scores:
			mean_score += s
			min_score = minf(min_score, s)
		mean_score /= scores.size()
	else:
		ok = false

	var output := {
		"ok": ok,
		"per_vehicle": per_vehicle,
		"mean_score": mean_score,
		"aggregate_score": min_score,
	}
	print(JSON.stringify(output))
	quit(0 if ok else 1)


## Runs one vehicle for racing_seconds under the vision policy. Returns the
## same result shape as AIBenchmark.run() (see tests/ai_benchmark.gd).
func _run_vehicle(vehicle_key: String, racing_seconds: float, host: String,
		port: int, decision_interval: float) -> Dictionary:
	var race_scene: Node3D = preload("res://race/race_scene.tscn").instantiate()
	root.add_child(race_scene)
	race_scene.ai_enabled = true

	var car: Node3D = (load(VEHICLE_SCENES[vehicle_key]) as PackedScene).instantiate()
	car.name = "car"

	await process_frame
	await race_scene.start_race(car)

	_swap_in_vision_driver(race_scene, host, port, decision_interval)

	var path: Path3D = race_scene._path
	var vehicle: VehicleBody3D = race_scene._car
	var track_width: float = race_scene.TRACK_WIDTH

	var sum_lateral := 0.0
	var max_lateral := 0.0
	var off_track_ticks := 0
	var sample_count := 0
	var sum_speed := 0.0
	var max_speed := 0.0
	var fell_off := false
	var fall_distance_m := -1.0

	var trace: Array = []
	var _next_trace_s := 0.0

	var steer_limit: float = vehicle.STEER_LIMIT
	var max_abs_engine_force := 0.0
	var max_abs_steering := 0.0

	var total_ticks := int((race_scene.COUNTDOWN_DURATION + racing_seconds) * Engine.physics_ticks_per_second)

	for i in range(total_ticks):
		await physics_frame
		if race_scene._state != 1: # RaceState.RACING
			continue

		var car_global: Vector3 = vehicle.global_position
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

	var fair_steering: bool = max_abs_steering <= steer_limit + _FAIRNESS_TOLERANCE
	var fair_engine_force: bool = max_abs_engine_force <= _ENGINE_FORCE_CEILING + _FAIRNESS_TOLERANCE
	var fair: bool = fair_steering and fair_engine_force

	var distance: float = race_scene._total_distance
	var track_length: float = race_scene._track_length
	var reason: String
	if distance >= track_length - race_scene.FINISH_LINE_MARGIN:
		reason = "won"
	elif fell_off:
		reason = "fell_off"
	else:
		reason = "time_up"
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
	}

	race_scene.queue_free()
	return result


## Removes the default driver race_manager.gd's _setup_ai_driver() attached
## (whichever policy is currently checked into ai/ai_drive_task.gd -- Tier
## A or B, irrelevant here) and attaches ai/vision/vision_driver.tscn in
## its place. See this file's class doc for why this swap is necessary.
func _swap_in_vision_driver(race_scene: Node3D, host: String, port: int, decision_interval: float) -> void:
	var default_driver_node: Node = race_scene._ai_driver.get_parent() if is_instance_valid(race_scene._ai_driver) else null
	if default_driver_node:
		default_driver_node.queue_free()
		await process_frame

	var driver_node: Node3D = preload("res://ai/vision/vision_driver.tscn").instantiate()
	driver_node.name = "VisionDriver"
	race_scene._car.add_child(driver_node)

	var driver := driver_node.get_node("BTPlayer") as BTPlayer
	var root_task: BTAction = driver.get_bt_instance().get_root_task()
	root_task.set("inference_host", host)
	root_task.set("inference_port", port)
	root_task.set("decision_interval_s", decision_interval)

	var blackboard := driver.get_blackboard()
	blackboard.set_var("car", race_scene._car)
	race_scene._ai_driver = driver


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
