extends Node3D
class_name RaceManager

## Race state machine.
enum RaceState {
	COUNTDOWN,
	RACING,
	FINISHED,
}

## Duration of the race in seconds.
const RACE_DURATION := 60.0
## Duration of the pre-race countdown in seconds.
const COUNTDOWN_DURATION := 3.0
## Maximum horizontal distance from the track center before being considered off-track.
const TRACK_WIDTH := 4.0
## Seconds the player has to return to the track before the race ends.
const OFF_TRACK_GRACE := 1.5
## Clamp per-frame distance delta to avoid exploits from flipping/teleporting.
const MAX_DELTA_DISTANCE := 20.0
## Vertical margin below the lowest track point before the race ends (falling off).
const FALL_MARGIN := 2.0
## How close (in meters, along the track) to the very end of the path counts
## as having finished it. Triggers the win before the car can drive off the
## physical end of the track (which has no surface beyond it) and "falls".
## Kept generous: the track's final stretch is right at the edge of what the
## car can steer through at all, so a driver that gets this close has, in
## practice, finished the track.
## Measured (via headless benchmark) as just past the car's demonstrated
## reach with the current AI/track: it consistently gets to ~361.5m of the
## 366.5m track before the shared max_steer kinematic limit stops it. Set
## just below that (with a small buffer for run-to-run variance) so winning
## genuinely requires reaching that ceiling, rather than being credited
## comfortably before it.
const FINISH_LINE_MARGIN := 6.0

## When true, LimboAI drives the player's selected car instead of the player.
## When false, the player drives normally. There is no separate opponent car.
@export var ai_enabled := false

## Which driver scene to instantiate when ai_enabled is true. Must be a scene
## exposing the same shape as ai/ai_driver.tscn (a Node3D with a child
## "BTPlayer" BTPlayer). Lets the caller (car_select.gd) pick between the
## different driving policies under ai/ (see ai/COMPARISON.md) without this
## script needing to know about any of them by name. Set before start_race().
@export var ai_driver_scene: PackedScene = preload("res://ai/ai_driver.tscn")

## Single objective score for one race attempt, meant to make different
## drivers (human or AI) directly comparable without eyeballing it:
##
##   score = pct_of_track_completed * (1 + time_bonus)
##
## where pct_of_track_completed = distance / track_length, clamped to
## [0, 1], and time_bonus is the fraction of the race clock left unused --
## but ONLY awarded when the track was actually finished (reason == "won").
## An unfinished run, no matter how far it got, always scores < 1.0; a
## finished run always scores >= 1.0, with faster finishes scoring higher
## (up to 2.0 for a hypothetical instant finish). This means a driver that
## finishes slowly can never be outscored by one that merely gets further
## without finishing, while still ranking finishers by speed. Static so it
## can be reused by tooling (e.g. the AI benchmark) without a live scene.
static func compute_score(reason: String, distance: float, track_length: float,
		race_time: float, race_duration: float) -> float:
	if track_length <= 0.0:
		return 0.0
	var pct := clampf(distance / track_length, 0.0, 1.0)
	if reason == "won":
		var time_bonus := clampf((race_duration - race_time) / race_duration, 0.0, 1.0)
		return pct * (1.0 + time_bonus)
	return pct

var _state: RaceState = RaceState.COUNTDOWN
var _state_timer: float = 0.0
var _car: VehicleBody3D
var _ai_driver: BTPlayer
var _path: Path3D
var _last_offset: float = 0.0
var _total_distance: float = 0.0
var _off_track_timer: float = 0.0
var _best_distance: float = 0.0
var _best_time: float = INF
var _best_score: float = 0.0
var _countdown_whole_second := -1
## Y position below which the car has fallen off the track (computed from the path).
var _fall_kill_y: float = -INF
## Total length of the track path, cached once the curve is ready.
var _track_length: float = 0.0

@onready var _car_spawn: Marker3D = %CarSpawn
@onready var _racetrack: Node3D = %Racetrack
@onready var _race_ui: CanvasLayer = %RaceUI


func _ready() -> void:
	_path = _racetrack.get_node("Path3D") as Path3D
	# Curve3D auto-bakes on first call to sample_baked() or get_baked_length().
	_track_length = _path.curve.get_baked_length()
	_best_distance = _load_best_distance()
	_best_time = _load_best_time()
	_best_score = _load_best_score()
	if _race_ui:
		_race_ui.setup(self)
	_compute_fall_kill_y()


## Compute the Y threshold below which the car is considered to have fallen
## off the track (lowest track point minus a margin). Falls are relative to
## the track surface, so this stays correct even if the scene is moved.
func _compute_fall_kill_y() -> void:
	var baked_length: float = _path.curve.get_baked_length()
	var lowest: float = INF
	var offset := 0.0
	while offset <= baked_length:
		var point: Vector3 = _path.global_transform * _path.curve.sample_baked(offset)
		lowest = minf(lowest, point.y)
		offset += 1.0
	_fall_kill_y = lowest - FALL_MARGIN


## Raycasts straight down from above `point` to find the actual physical
## track surface below it (which can differ from the Path3D curve's own Y).
## Falls back to the curve point's own Y if nothing is hit, or if the hit is
## implausibly far away (e.g. the scene's big safety-net CollisionFloor,
## which sits far below the track -- if the racetrack's own CSG collision
## isn't registered with the physics server yet, that floor is the only
## thing left to hit, and blindly trusting it would spawn the car in a pit).
const _SURFACE_SANITY_MARGIN := 3.0

func _find_surface_y(point: Vector3) -> float:
	var space_state := get_world_3d().direct_space_state
	var from := point + Vector3.UP * 20.0
	var to := point + Vector3.DOWN * 20.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var result := space_state.intersect_ray(query)
	if not result.is_empty() and absf(result.position.y - point.y) <= _SURFACE_SANITY_MARGIN:
		return result.position.y
	return point.y


func start_race(car_node: Node3D) -> void:
	# The racetrack's CSG collision shape is generated procedurally and may
	# not be registered with the physics server yet on the very same frame
	# the race scene enters the tree (car_select adds the scene and calls
	# this immediately, with no frame in between). Wait a couple of physics
	# frames so the surface raycast below queries real, ready geometry.
	await get_tree().physics_frame
	await get_tree().physics_frame

	# Extract the VehicleBody3D from the car scene (car scenes wrap it in a Node3D).
	_car = car_node.get_child(0) as VehicleBody3D
	_car.turbometer = _race_ui.get_node("%Turbometer")
	_car.turbo_animator = _race_ui.get_node("%TurboAnimator")
	_race_ui.get_node("%Speedometer").car_body = _car

	# Place the car at the start of the track.
	var car_container := car_node
	_car_spawn.add_child(car_container)
	# Place the car 5 meters along the track (past the unstable start).
	var start_offset := 5.0
	var start_point: Vector3 = _path.global_transform * _path.curve.sample_baked(start_offset)
	var next_point: Vector3 = _path.global_transform * _path.curve.sample_baked(start_offset + 2.0)
	var track_dir := (next_point - start_point).normalized()

	# Spawn barely above the ACTUAL track surface. The Path3D curve's own Y is
	# not the physical road surface (the CSG cross-section sits ~1m above it),
	# so a fixed offset from the curve point silently under-places every car.
	# Vehicles with generous wheel suspension (e.g. the minivan) can recover
	# from that gap on their own; smaller-wheeled ones (the tow truck) can't
	# and are left visibly sunk into the ground. Raycasting for the real
	# surface makes spawning correct for every vehicle, regardless of its
	# suspension setup.
	var surface_y := _find_surface_y(start_point)
	car_container.global_position = Vector3(start_point.x, surface_y + 0.2, start_point.z)
	var y_rotation := atan2(track_dir.x, track_dir.z)
	car_container.global_rotation = Vector3(0.0, y_rotation, 0.0)
	
	# Initialize distance tracking from the spawn offset.
	_last_offset = start_offset

	# Attach camera.
	var camera: Camera3D = _car.get_node("CameraBase/Camera3D")
	camera.make_current()

	# Attach the LimboAI driver to the player's car if enabled.
	if ai_enabled:
		_setup_ai_driver()

	# Start countdown.
	_enter_state(RaceState.COUNTDOWN)


## Attach a LimboAI driver (BTPlayer) to the player's car so the AI follows
## the track path. The driver reads "car" and "path" from its blackboard.
func _setup_ai_driver() -> void:
	# Instantiate a scene that embeds the BTPlayer so its owner is set at
	# load time (a runtime-created BTPlayer otherwise fails to detect its
	# scene root and won't initialize its behavior tree).
	var driver_node: Node3D = ai_driver_scene.instantiate()
	driver_node.name = "AIDriver"
	_car.add_child(driver_node)

	var driver := driver_node.get_node("BTPlayer") as BTPlayer
	var blackboard := driver.get_blackboard()
	blackboard.set_var("car", _car)
	blackboard.set_var("path", _path)
	_ai_driver = driver


func _physics_process(delta: float) -> void:
	if _state == RaceState.FINISHED:
		return

	_state_timer += delta

	match _state:
		RaceState.COUNTDOWN:
			_process_countdown(delta)
		RaceState.RACING:
			_process_racing(delta)


func _process_countdown(_delta: float) -> void:
	var remaining := COUNTDOWN_DURATION - _state_timer
	var whole := ceili(remaining)

	if whole != _countdown_whole_second and whole >= 0:
		_countdown_whole_second = whole
		if whole > 0:
			_race_ui.show_countdown(str(whole))
		else:
			_race_ui.show_countdown("GO!")

	if _state_timer >= COUNTDOWN_DURATION:
		_enter_state(RaceState.RACING)


func _process_racing(delta: float) -> void:
	var remaining := RACE_DURATION - (_state_timer - COUNTDOWN_DURATION)
	_race_ui.update_timer(remaining)

	if remaining <= 0.0:
		_end_race("time_up")
		return

	# Distance tracking along the Path3D curve.
	# The curve methods operate in local space, so transform the car position.
	var car_global: Vector3 = _car.global_position
	var car_local: Vector3 = _path.global_transform.affine_inverse() * car_global
	var closest_offset: float = _path.curve.get_closest_offset(car_local)

	var delta_dist := absf(closest_offset - _last_offset)
	delta_dist = minf(delta_dist, MAX_DELTA_DISTANCE)
	_total_distance += delta_dist
	_last_offset = closest_offset

	_race_ui.update_distance(_total_distance)

	# Finish detection: reaching (near) the end of the track wins the race.
	# Checked before the fall check because the track has no surface past its
	# very last point, so without this the car would just drive off the end
	# and register as having "fallen" instead of having finished. Gated on
	# the accumulated _total_distance (built up via small, clamped increments
	# every frame) rather than a single instantaneous closest-point lookup:
	# this track loops close to itself in places, so a raw one-frame check
	# could false-positive if the car is merely near the endpoint in space
	# without actually having driven the track to get there.
	if _total_distance >= _track_length - FINISH_LINE_MARGIN:
		_end_race("won")
		return

	# Fall detection: if the car drops below the track surface by more than the
	# margin, it has fallen off the track. End the race immediately.
	if _car.global_position.y < _fall_kill_y:
		_end_race("fell_off")
		return

	# Off-track detection: compare in world space.
	var closest_point_local: Vector3 = _path.curve.sample_baked(closest_offset)
	var closest_point_global: Vector3 = _path.global_transform * closest_point_local
	var car_2d := Vector2(car_global.x, car_global.z)
	var track_2d := Vector2(closest_point_global.x, closest_point_global.z)
	var horizontal_dist := car_2d.distance_to(track_2d)

	if horizontal_dist > TRACK_WIDTH:
		_off_track_timer += delta
		_race_ui.show_off_track_warning(true, _off_track_timer >= OFF_TRACK_GRACE * 0.5)
		if _off_track_timer >= OFF_TRACK_GRACE:
			_end_race("off_track")
	else:
		_off_track_timer = maxf(0.0, _off_track_timer - delta * 2.0)
		if _off_track_timer <= 0.0:
			_race_ui.show_off_track_warning(false, false)


func _end_race(reason: String) -> void:
	# Capture elapsed racing time before _enter_state() resets _state_timer.
	var race_time := _state_timer
	_enter_state(RaceState.FINISHED)

	var is_new_best_distance := _total_distance > _best_distance
	if is_new_best_distance:
		_best_distance = _total_distance
		_save_best_distance()

	var is_new_best_time := false
	if reason == "won":
		is_new_best_time = race_time < _best_time
		if is_new_best_time:
			_best_time = race_time
			_save_best_time()

	var score := compute_score(reason, _total_distance, _track_length, race_time, RACE_DURATION)
	var is_new_best_score := score > _best_score
	if is_new_best_score:
		_best_score = score
		_save_best_score()

	_race_ui.show_results(_total_distance, _best_distance, is_new_best_distance, reason,
			race_time, _best_time, is_new_best_time, score, _best_score, is_new_best_score)


func restart_race() -> void:
	# Remove old cars (the AIDriver BTPlayer is a child of the car, so it is
	# freed along with it).
	if is_instance_valid(_car):
		_car.get_parent().queue_free()
		_car = null
	_ai_driver = null

	_total_distance = 0.0
	_last_offset = 0.0
	_off_track_timer = 0.0
	_countdown_whole_second = -1

	_race_ui.hide_results()
	get_tree().call_group(&"car_select", &"restart_race")


func go_back_to_menu() -> void:
	get_tree().call_group(&"car_select", &"go_back_to_menu")


func _enter_state(new_state: RaceState) -> void:
	_state = new_state
	_state_timer = 0.0

	match new_state:
		RaceState.COUNTDOWN:
			_race_ui.show_countdown_phase()
			_set_car_controls_enabled(false)
		RaceState.RACING:
			_race_ui.show_racing_phase()
			_set_car_controls_enabled(true)
		RaceState.FINISHED:
			_set_car_controls_enabled(false)


func _set_car_controls_enabled(enabled: bool) -> void:
	if not is_instance_valid(_car):
		return

	_car.freeze = not enabled

	if ai_enabled:
		# The LimboAI driver controls the car: keep the player-input physics
		# script off so it doesn't fight the AI's steering/throttle.
		_car.set_process_input(false)
		_car.set_physics_process(false)
		if is_instance_valid(_ai_driver):
			_ai_driver.set_active(enabled)
	else:
		_car.set_process_input(enabled)
		_car.set_physics_process(enabled)


func _load_best_distance() -> float:
	var file := FileAccess.open("user://race_best.save", FileAccess.READ)
	if file:
		var value: float = file.get_float()
		file.close()
		return value
	return 0.0


func _save_best_distance() -> void:
	var file := FileAccess.open("user://race_best.save", FileAccess.WRITE)
	if file:
		file.store_float(_best_distance)
		file.close()


func _load_best_time() -> float:
	var file := FileAccess.open("user://race_best_time.save", FileAccess.READ)
	if file:
		var value: float = file.get_float()
		file.close()
		return value
	return INF


func _save_best_time() -> void:
	var file := FileAccess.open("user://race_best_time.save", FileAccess.WRITE)
	if file:
		file.store_float(_best_time)
		file.close()


func _load_best_score() -> float:
	var file := FileAccess.open("user://race_best_score.save", FileAccess.READ)
	if file:
		var value: float = file.get_float()
		file.close()
		return value
	return 0.0


func _save_best_score() -> void:
	var file := FileAccess.open("user://race_best_score.save", FileAccess.WRITE)
	if file:
		file.store_float(_best_score)
		file.close()
