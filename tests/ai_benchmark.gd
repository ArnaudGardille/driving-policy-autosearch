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
static func run(tree: SceneTree, racing_seconds: float, overrides: Dictionary = {},
		vehicle_scene_path: String = "res://vehicles/car_base.tscn") -> Dictionary:
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
	}

	race_scene.queue_free()
	return result
