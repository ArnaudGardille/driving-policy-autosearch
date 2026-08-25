extends BTAction
## Drives a VehicleBody3D along a Path3D curve using steering and throttle control.
## Reads "path" (Path3D) and "car" (VehicleBody3D) from the blackboard.
##
## Uses the SAME car (engine force, acceleration curve) and the SAME track as
## the human player -- all of the driving skill lives in how this task
## localizes itself on the path and chooses steering/speed, not in any car or
## track advantage.

## How far ahead (in meters) the AI looks to steer towards.
@export var look_ahead: float = 8.0
## Base engine force applied when accelerating. Matches the player's default
## engine_force_value (vehicle.gd) so the AI has no power advantage.
@export var engine_power: float = 40.0
## Maximum steering angle in radians.
@export var max_steer: float = 0.4
## Minimum speed to maintain (won't slow below this).
@export var min_speed: float = 4.0
## Maximum target speed.
@export var max_speed: float = 25.0
## How sharply speed drops when approaching a turn (higher = brakes harder).
@export var braking_factor: float = 3.5
## How strongly to correct sideways drift back toward the track centerline
## (0 = pure pursuit only, which tends to hug one edge; 1 = fully snap back).
## 0.75 was found (by benchmark) to be the point where further increases
## stop helping -- the remaining limit past that is the shared max_steer
## kinematic turning radius, not correction strength.
@export var cross_track_gain: float = 0.75
## Vertical/horizontal slope ratio above which the AI treats the path as a
## climb or descent (ramp) and slows down for it.
@export var slope_speed_threshold: float = 0.25
## How sharply speed drops on steep climbs/descents (higher = brakes harder).
@export var slope_braking_factor: float = 2.5
## How far back/forward (meters) to search for the car's position on the
## curve once locked on. Keeps localization continuous instead of jumping to
## a spatially-close-but-wrong lap segment on a track that loops near itself.
@export var track_search_back: float = 6.0
@export var track_search_forward: float = 20.0
@export var track_search_step: float = 0.5
## Distance ahead to scan for the tightest UPCOMING curvature, so braking
## starts before the corner instead of only reacting once already in it.
@export var curvature_preview: float = 12.0
@export var curvature_preview_samples: int = 6
## Shrinks the steering look-ahead point in tight turns so the car tracks
## the true arc instead of cutting the corner wide. NOTE: measured to be
## very sensitive -- too strong a gain makes steering twitchy/oscillatory
## and made things worse; keep this low. 0 disables it (fixed look_ahead).
@export var lookahead_min: float = 3.0
@export var lookahead_curvature_gain: float = 0.0
## Extra emergency braking once the car strays this many meters off the
## centerline, regardless of curvature, as a last-resort safety margin
## before a wheel can reach the physical edge of the road.
@export var safety_margin: float = 1.1
## Distance ahead to check for a crest (elevation rises then falls). A crest
## can launch the car briefly airborne even when the slope itself isn't
## steep, and while airborne steering has no effect -- so it needs its own,
## more conservative speed cap independent of the general slope/curvature checks.
@export var crest_preview: float = 10.0
@export var crest_speed_cap: float = 6.0

## Tracks the car's progress along the curve between ticks. Curve3D's own
## get_closest_offset() does a GLOBAL nearest-point search: on a track that
## loops back near itself in 3D space, a car that's only slightly off-line
## can have its "closest point" jump to an unrelated, distant lap segment.
## That bad offset then feeds the look-ahead target, steering further off
## course, which makes the next offset guess even worse -- a runaway
## feedback loop that was driving the car straight off the track. Searching
## only near where we last knew we were keeps localization continuous.
var _known_offset: float = -1.0


func _tick(_delta: float) -> int:
	var path: Path3D = _get_bb_var("path") as Path3D
	var car: VehicleBody3D = _get_bb_var("car") as VehicleBody3D

	if not path or not car:
		return BTTask.FAILURE

	_drive(car, path)
	return BTTask.RUNNING


func _drive(car: VehicleBody3D, path: Path3D) -> void:
	var curve: Curve3D = path.curve
	if not curve or curve.point_count < 2:
		return

	var total_length: float = curve.get_baked_length()

	# Find current position along the curve (continuous localization).
	var car_global: Vector3 = car.global_position
	var car_local: Vector3 = path.global_transform.affine_inverse() * car_global
	var current_offset: float = _localize(curve, car_local, total_length)

	# --- Curvature: immediate (for steering) and previewed-ahead (for braking) ---
	var dir_current := _sample_direction(curve, current_offset, total_length)
	var dir_near_ahead := _sample_direction(curve, current_offset + look_ahead * 0.5, total_length)
	var immediate_curvature: float = absf(dir_current.angle_to(dir_near_ahead))
	var upcoming_curvature: float = _max_curvature_ahead(curve, current_offset, total_length)
	var curvature: float = maxf(immediate_curvature, upcoming_curvature)

	# --- Steering ---
	# Shrink the pursuit look-ahead in tight turns so the aim point tracks
	# the true arc of the corner instead of cutting across it wide (a fixed,
	# long look-ahead aims past the apex and drifts the car toward the
	# outside edge of the turn).
	var adaptive_look_ahead: float = maxf(
			look_ahead / (1.0 + lookahead_curvature_gain * immediate_curvature), lookahead_min)
	var target_offset: float = minf(current_offset + adaptive_look_ahead, total_length)

	var target_local: Vector3 = curve.sample_baked(target_offset)
	var target_global: Vector3 = path.global_transform * target_local

	# Cross-track correction: pure pursuit alone (aiming only at a point
	# further down the centerline) converges too slowly and lets the car
	# settle into hugging one edge. Pull the aim point back toward the
	# centerline by a fraction of the car's current sideways offset.
	var on_track_local: Vector3 = curve.sample_baked(current_offset)
	var on_track_global: Vector3 = path.global_transform * on_track_local
	var lateral_error_vec: Vector3 = car_global - on_track_global
	lateral_error_vec.y = 0.0
	var lateral_error: float = lateral_error_vec.length()
	if cross_track_gain > 0.0:
		target_global -= lateral_error_vec * cross_track_gain

	# Transform target to car's local space.
	var car_transform: Transform3D = car.global_transform
	var local_target: Vector3 = car_transform.affine_inverse() * target_global

	# Compute steering angle: atan2 of the local X (right) and Z (forward).
	var steer_angle: float = atan2(local_target.x, local_target.z)
	steer_angle = clampf(steer_angle, -max_steer, max_steer)
	car.steering = steer_angle

	# --- Throttle ---
	var current_speed: float = car.linear_velocity.length()

	# Target speed: lower on tight turns (including ones just ahead), higher
	# on straights.
	var target_speed: float = max_speed
	if curvature > 0.3:
		target_speed = lerpf(max_speed, min_speed, clampf((curvature - 0.3) * braking_factor, 0.0, 1.0))

	# Slow down for steep climbs/descents (ramps) so the car doesn't launch
	# off crests or lose traction on landings.
	var p_prev: Vector3 = curve.sample_baked(maxf(current_offset - 1.0, 0.0))
	var p_next: Vector3 = curve.sample_baked(minf(current_offset + 1.0, total_length))
	var run: float = Vector2(p_next.x - p_prev.x, p_next.z - p_prev.z).length()
	var slope: float = absf(p_next.y - p_prev.y) / maxf(run, 0.001)
	if slope > slope_speed_threshold:
		var slope_target: float = lerpf(max_speed, min_speed,
				clampf((slope - slope_speed_threshold) * slope_braking_factor, 0.0, 1.0))
		target_speed = minf(target_speed, slope_target)

	# Crest ahead (climbing then descending): cap speed hard, independent of
	# how steep the slope actually is, since going over a crest too fast
	# launches the car airborne and steering does nothing while it's in the air.
	if _has_crest_ahead(curve, current_offset, total_length):
		target_speed = minf(target_speed, crest_speed_cap)

	# Last-resort safety net: if we've already strayed close to the track
	# edge, brake hard regardless of curvature so a wheel doesn't clip over
	# the side before the steering correction catches up.
	if lateral_error > safety_margin:
		target_speed = minf(target_speed, min_speed)

	# Apply throttle or brake. Mirrors the player's own low-speed torque
	# boost (vehicle.gd) so the AI's acceleration curve matches the human's
	# exactly, using the same engine_power ceiling.
	if current_speed < target_speed:
		if current_speed < 5.0 and not is_zero_approx(current_speed):
			car.engine_force = clampf(engine_power * 5.0 / current_speed, 0.0, 100.0)
		else:
			car.engine_force = engine_power
		car.brake = 0.0
	else:
		car.engine_force = 0.0
		car.brake = clampf((current_speed - target_speed) * 0.5, 0.0, 5.0)


## Finds the car's offset along the curve. On the very first tick (or if we
## somehow lose track entirely) falls back to a full-curve search to get an
## initial fix; after that, only searches a bounded window around the last
## known offset so a self-crossing track can't cause a bogus long-range jump.
func _localize(curve: Curve3D, car_local: Vector3, total_length: float) -> float:
	if _known_offset < 0.0:
		_known_offset = curve.get_closest_offset(car_local)
		return _known_offset

	var lo: float = maxf(_known_offset - track_search_back, 0.0)
	var hi: float = minf(_known_offset + track_search_forward, total_length)

	var best_offset: float = _known_offset
	var best_dist_sq: float = INF
	var offset: float = lo
	while offset <= hi:
		var dist_sq: float = curve.sample_baked(offset).distance_squared_to(car_local)
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_offset = offset
		offset += track_search_step

	_known_offset = best_offset
	return best_offset


## Scans a window ahead of the car and returns the sharpest curvature found,
## so tight corners start slowing the car down before it's already inside
## them (a single sample at a fixed look-ahead can miss a bend that's closer
## or sharper than that one point).
func _max_curvature_ahead(curve: Curve3D, start_offset: float, total_length: float) -> float:
	var max_c := 0.0
	var samples: int = maxi(curvature_preview_samples, 1)
	for i in range(samples):
		var t: float = float(i) / float(maxi(samples - 1, 1))
		var offset: float = minf(start_offset + curvature_preview * t, total_length)
		var d1 := _sample_direction(curve, offset - 1.0, total_length)
		var d2 := _sample_direction(curve, offset + 1.0, total_length)
		max_c = maxf(max_c, absf(d1.angle_to(d2)))
	return max_c


## True if the path climbs and then descends within the preview window
## ahead (a crest/hilltop/jump), regardless of how steep either side is.
func _has_crest_ahead(curve: Curve3D, start_offset: float, total_length: float) -> bool:
	var h0: float = curve.sample_baked(start_offset).y
	var h_mid: float = curve.sample_baked(minf(start_offset + crest_preview * 0.5, total_length)).y
	var h1: float = curve.sample_baked(minf(start_offset + crest_preview, total_length)).y
	return h_mid > h0 and h_mid > h1


func _sample_direction(curve: Curve3D, offset: float, total_length: float) -> Vector3:
	# Sample two nearby points to get the direction at an offset.
	var p1 := curve.sample_baked(clampf(offset - 0.5, 0.0, total_length))
	var p2 := curve.sample_baked(clampf(offset + 0.5, 0.0, total_length))
	var diff := p2 - p1
	if diff.length_squared() < 0.0001:
		return Vector3.FORWARD
	return diff.normalized()


func _get_bb_var(var_name: String) -> Variant:
	var bb := get_blackboard()
	if bb and bb.has_var(var_name):
		return bb.get_var(var_name)
	return null
