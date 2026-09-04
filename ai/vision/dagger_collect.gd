extends SceneTree
## Tier C DAgger data collection: runs the CURRENT closed-loop vision policy
## (ai/vision/vision_driver.tscn, driving for real -- same setup as
## run_eval_vision.gd) and relabels every visited state with what the Tier A
## curve-following expert (ai/tier_a_drive_task.gd) would have done from
## that EXACT pose -- not what Tier C actually did. This is the core DAgger
## correction (Ross et al., 2011): pure behavior cloning (Phase 1) only ever
## saw expert trajectories, so the trained policy never learned how to
## recover once its own drift carries it slightly off the expert's
## distribution -- any small error compounds. Relabeling the trainee's own
## visited states with the expert's opinion teaches exactly that recovery
## signal. See ai/COMPARISON.md's Phase 2 note for the diagnosis this
## addresses.
##
## The expert relabeling needs no second real race: ai/tier_a_drive_task.gd's
## _drive(car, path, delta) is a pure function of the car's CURRENT
## global_transform/linear_velocity plus its own internal localization state
## (_known_offset) -- it doesn't go through the blackboard/behavior-tree
## plumbing _tick() normally uses. So this script keeps ONE Tier A instance
## alive for the whole race (continuous localization -- same continuity
## guarantee _localize()'s own doc comment describes, now tracking wherever
## Tier C's driving actually takes the car), and at each capture tick:
## 1. Saves the vision policy's actual steering/engine_force/brake.
## 2. Calls the expert's _drive() on the SAME live car -- which overwrites
##    those three properties with the expert's opinion as a side effect
##    (GDScript doesn't enforce the leading-underscore "internal" convention
##    as real privacy, so calling it directly from outside its class works).
## 3. Reads that back as the label.
## 4. Restores the vision policy's real values, so the actual physics this
##    tick isn't disturbed -- the car's own trajectory stays driven entirely
##    by Tier C throughout; only a label is harvested, never applied.
##
## REQUIRES REAL RENDERING (same constraint as record_dataset.gd /
## run_eval_vision.gd) -- do NOT run under --headless.
##
##   godot --display-driver x11 --rendering-driver vulkan --resolution 320x180 \
##       --path <repo> --script res://ai/vision/dagger_collect.gd -- \
##       --vehicle=car_base --dir=/abs/path/to/data/dagger_r1_car_base \
##       [--seconds=65] [--host=127.0.0.1] [--port=8765] [--decision_interval=0.1]
##
## infer_server.py must already be running -- serving whichever checkpoint
## the policy being critiqued this round actually is -- before this is
## invoked. Writes <dir>/manifest.json, same {"pairs": [...], "score",
## "fair", "reason"} shape record_dataset.gd writes -- "pairs" here carries
## the EXPERT's steering/engine_force at each state, not the vision policy's
## own (that's the whole point); "score"/"fair"/"reason" describe how the
## vision policy that generated this trajectory actually did, kept only for
## provenance/debugging, not fed into training.

const VEHICLE_SCENES := {
	"car_base": "res://vehicles/car_base.tscn",
	"trailer_truck": "res://vehicles/trailer_truck.tscn",
	"tow_truck": "res://vehicles/tow_truck.tscn",
}

const DEFAULT_RACING_SECONDS := 65.0
## Matches record_dataset.gd / ai_benchmark.gd's own trace cadence -- keeps
## DAgger rounds' pairs-per-second comparable to the Phase 1 dataset's.
const CAPTURE_INTERVAL_S := 0.5
const _ENGINE_FORCE_CEILING := 100.0
const _FAIRNESS_TOLERANCE := 0.01


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

	var host: String = String(args.get("host", "127.0.0.1"))
	var port: int = String(args.get("port", "8765")).to_int()
	var decision_interval: float = String(args.get("decision_interval", "0.1")).to_float()

	var dir_abs: String = ProjectSettings.globalize_path(dir) if dir.begins_with("res://") else dir
	DirAccess.make_dir_recursive_absolute(dir_abs)

	var result: Dictionary = await _run_vehicle(vehicle_key, racing_seconds, host, port, decision_interval, dir_abs)

	var manifest: Dictionary = {
		"pairs": result["pairs"],
		"score": result["score"],
		"fair": result["fair"],
		"reason": result["reason"],
	}
	var manifest_path: String = dir_abs.path_join("manifest.json")
	var f := FileAccess.open(manifest_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(manifest, "  "))
		f.close()

	var pairs_recorded: int = (manifest["pairs"] as Array).size()
	var ok: bool = pairs_recorded > 0
	if pairs_recorded == 0:
		push_warning("dagger_collect: 0 pairs recorded. Did you forget --display-driver x11 --rendering-driver vulkan, or is infer_server.py not running on --host:--port?")

	print(JSON.stringify({
		"ok": ok,
		"vehicle": vehicle_key,
		"pairs_recorded": pairs_recorded,
		"driving_score": result["score"],
		"fair": result["fair"],
		"reason": result["reason"],
		"manifest": manifest_path,
	}))
	quit(0 if ok else 1)


func _run_vehicle(vehicle_key: String, racing_seconds: float, host: String, port: int,
		decision_interval: float, dir_abs: String) -> Dictionary:
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

	# The relabeling expert. A fresh instance per race so _known_offset
	# starts unset (full-curve search on its first call, then continuous
	# tracking after -- see ai/tier_a_drive_task.gd's own _localize() doc).
	var expert: BTAction = preload("res://ai/tier_a_drive_task.gd").new()

	var fell_off := false
	var pairs: Array = []
	var sample_count := 0
	var _next_capture_s := 0.0

	var steer_limit: float = vehicle.STEER_LIMIT
	var max_abs_engine_force := 0.0
	var max_abs_steering := 0.0

	var total_ticks := int((race_scene.COUNTDOWN_DURATION + racing_seconds) * Engine.physics_ticks_per_second)

	for i in range(total_ticks):
		await physics_frame
		if race_scene._state != 1: # RaceState.RACING
			continue

		sample_count += 1
		var car_global: Vector3 = vehicle.global_position
		if car_global.y < race_scene._fall_kill_y and not fell_off:
			fell_off = true

		max_abs_engine_force = maxf(max_abs_engine_force, absf(vehicle.engine_force))
		max_abs_steering = maxf(max_abs_steering, absf(vehicle.steering))

		var race_time_now: float = sample_count / float(Engine.physics_ticks_per_second)
		if race_time_now >= _next_capture_s:
			# Only relabel states where the car is still meaningfully ON the
			# track (same TRACK_WIDTH tolerance race_manager.gd/run_eval_vision.gd
			# use to flag an off-track tick). Round 1's very first attempt
			# skipped this check and regressed the closed-loop score
			# (0.061 vs the 0.101 pre-DAgger baseline) -- inspecting the
			# harvested labels showed the LAST 1-2 samples of every
			# trajectory (right as the car is already off the physical
			# track or in freefall below it) had wildly inconsistent
			# steering, e.g. a hard +0.40 correction immediately followed by
			# -0.39 the very next sample. Root cause: ai/tier_a_drive_task.gd's
			# _localize() deliberately only searches a BOUNDED window around
			# _known_offset (see its own doc comment) for track-continuity
			# reasons, an assumption that holds for a car actually on the
			# track but breaks down once the car is already far off it or
			# falling -- the resulting "closest point in the window" can be
			# an unrelated, spatially-close-by-coincidence spot, producing a
			# steering opinion with no real relationship to how to recover.
			# Skipping these unrecoverable-by-construction states keeps
			# every label trustworthy, at the cost of a few fewer pairs per
			# trajectory.
			var car_local: Vector3 = path.global_transform.affine_inverse() * car_global
			var closest_offset: float = path.curve.get_closest_offset(car_local)
			var closest_point_local: Vector3 = path.curve.sample_baked(closest_offset)
			var closest_point_global: Vector3 = path.global_transform * closest_point_local
			var lateral: float = Vector2(car_global.x, car_global.z).distance_to(
					Vector2(closest_point_global.x, closest_point_global.z))
			if lateral <= race_scene.TRACK_WIDTH:
				_capture_pair(vehicle, path, expert, dir_abs, pairs.size(), race_time_now, pairs)
			_next_capture_s += CAPTURE_INTERVAL_S

		# Once fallen off (terminal/non-recoverable for scoring, see the
		# reason/score logic below) or finished, every remaining tick of the
		# nominal racing_seconds window is wasted real wall-clock time -- no
		# further useful state can ever be visited, and DAgger only wants
		# states the trainee actually reaches. Breaking here is the single
		# biggest lever on how long a round takes in practice: Tier C
		# currently falls off within the first ~10s on every vehicle (see
		# ai/COMPARISON.md's Phase 2 note), so waiting out the rest of a
		# nominal 65s window bought nothing but GPU-readback overhead from
		# vision_drive_task's own still-running inference queries.
		if fell_off or race_scene._total_distance >= race_scene._track_length - race_scene.FINISH_LINE_MARGIN:
			break

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

	race_scene.queue_free()
	return {"pairs": pairs, "score": score, "fair": fair, "reason": reason}


## Harvests one (image, expert_steering, expert_engine_force) triple at the
## car's CURRENT pose -- see class doc above for the save/query/restore
## sequence and why it never disturbs Tier C's own actuation.
func _capture_pair(car: VehicleBody3D, path: Path3D, expert: BTAction, dir_abs: String,
		idx: int, t: float, pairs: Array) -> void:
	var real_steering: float = car.steering
	var real_engine_force: float = car.engine_force
	var real_brake: float = car.brake

	expert._drive(car, path, CAPTURE_INTERVAL_S)
	var label_steering: float = car.steering
	var label_engine_force: float = car.engine_force

	car.steering = real_steering
	car.engine_force = real_engine_force
	car.brake = real_brake

	var viewport_texture: ViewportTexture = root.get_texture()
	if viewport_texture == null:
		return
	var img: Image = viewport_texture.get_image()
	if img == null:
		return
	var filename: String = "%03d_t%.0fs.png" % [idx, t]
	var image_path: String = dir_abs.path_join(filename)
	img.save_png(image_path)

	pairs.append({
		"image": image_path,
		"t": t,
		"steering": label_steering,
		"engine_force": label_engine_force,
	})


## Removes the default driver race_manager.gd's _setup_ai_driver() attached
## and mounts ai/vision/vision_driver.tscn instead -- identical trick to
## run_eval_vision.gd's own _swap_in_vision_driver(), duplicated here rather
## than shared (no common parent to hang a shared helper off between two
## standalone SceneTree scripts).
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
