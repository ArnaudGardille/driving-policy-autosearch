extends SceneTree
## Run with --headless --path . --script res://tests/random_track_regression.gd

var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		push_error(message)
		failures += 1

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var straight := Curve3D.new()
	for i in 40:
		straight.add_point(Vector3(0, 0, i * 6))
	check(TrackGenerator._is_valid(straight), "Straight track must pass clearance")
	var crossing := Curve3D.new()
	for p in [Vector3(-30,0,-30), Vector3(30,0,30), Vector3(-30,0,30), Vector3(30,0,-30)]:
		crossing.add_point(p)
	check(not TrackGenerator._is_valid(crossing), "Crossing track must fail clearance")
	for seed_value in 20:
		var curve := TrackGenerator.generate_valid_curve(40, seed_value)
		check(TrackGenerator._is_valid(curve), "Invalid seed %d" % seed_value)
		check(curve.get_baked_points() == TrackGenerator.generate_valid_curve(40, seed_value).get_baked_points(), "Seed must reproduce route")
	var menu = load("res://car_select/car_select.tscn").instantiate()
	root.add_child(menu)
	check(menu.option_driver.item_count == 3, "Driver selection lost during merge")
	check(menu.button_random_track.button_pressed, "Random track option missing")
	menu.free()
	var packed := load("res://race/race_scene.tscn") as PackedScene
	var fixed := packed.instantiate() as RaceManager
	root.add_child(fixed)
	fixed.set_physics_process(false)
	var original := fixed._path.curve.get_baked_points()
	var floor_size: Vector3 = fixed.get_node("CollisionFloor/CollisionShape3D").shape.size
	var random_race := packed.instantiate() as RaceManager
	root.add_child(random_race)
	random_race.set_physics_process(false)
	random_race.randomize_track = true
	random_race.track_seed = 42
	await random_race.start_race(load("res://vehicles/car_base.tscn").instantiate())
	check(fixed._path.curve.get_baked_points() == original, "Randomization changed shared curve")
	check(fixed.get_node("CollisionFloor/CollisionShape3D").shape.size == floor_size, "Randomization changed shared floor")
	check(random_race._record_suffix == "_random_v1_42" and fixed._record_suffix == "", "Records must be scoped by track")
	for offset in [5.0, 40.0, 100.0, 180.0]:
		var point := random_race._path.to_global(random_race._path.curve.sample_baked(offset))
		var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 4, point - Vector3.UP * 4)
		var hit := random_race.get_world_3d().direct_space_state.intersect_ray(query)
		check(not hit.is_empty(), "Generated collision missing at %s" % offset)
	# Use a disposable record namespace and verify all three save/load pairs.
	var suffix: String = "_regression_%d" % Time.get_ticks_usec()
	random_race._record_suffix = suffix
	random_race._best_distance = 123.0
	random_race._best_time = 45.0
	random_race._best_score = 1.25
	random_race._save_best_distance()
	random_race._save_best_time()
	random_race._save_best_score()
	check(random_race._load_best_distance() == 123.0, "Distance record roundtrip")
	check(random_race._load_best_time() == 45.0, "Time record roundtrip")
	check(random_race._load_best_score() == 1.25, "Score record roundtrip")
	random_race._record_suffix = suffix + "_other"
	check(random_race._load_best_distance() == 0.0 and random_race._load_best_time() == INF and random_race._load_best_score() == 0.0, "Records leaked between tracks")
	for stem in ["race_best", "race_best_time", "race_best_score"]:
		DirAccess.remove_absolute("user://%s%s.save" % [stem, suffix])
	random_race.free()
	var later := packed.instantiate() as RaceManager
	root.add_child(later)
	later.set_physics_process(false)
	check(later._path.curve.get_baked_points() == original, "Later fixed race lost authored curve")
	check(later.get_node("CollisionFloor/CollisionShape3D").shape.size == floor_size, "Later fixed race lost floor size")
	later.free()
	fixed.free()
	print("Random track regression: %d failures" % failures)
	quit(1 if failures else 0)
