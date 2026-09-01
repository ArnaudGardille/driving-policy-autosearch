extends BTAction
## TIER B: drives a VehicleBody3D using ONLY vehicle-relative sensing --
## whisker raycasts against the track surface plus onboard proprioception
## (see ai/onboard_sensing.gd). Deliberately does NOT read the Path3D curve:
## race_manager.gd still sets the "path" blackboard var (that file is
## frozen, out of scope to change), this script just never looks at it. See
## ai/README_RESEARCH.md's "Known caveat" section -- Tier A's curve access
## is privileged information a human driver never gets; this is the
## experiment that asks how far a reactive, sensor-only policy can get on
## the SAME car, SAME track, SAME control surface.
##
## Uses the SAME car (engine force, acceleration curve) as the human player
## -- all of the driving skill lives in how this task interprets whisker
## readings and chooses steering/speed, not in any car or track advantage.

## Base engine force applied when accelerating. Matches the player's default
## engine_force_value (vehicle.gd) so the AI has no power advantage.
@export var engine_power: float = 40.0
## Maximum steering angle in radians.
@export var max_steer: float = 0.4
## Minimum speed to maintain (won't slow below this).
@export var min_speed: float = 5.0
## Maximum target speed.
@export var max_speed: float = 25.0

## --- Whisker sensor rig geometry (see ai/onboard_sensing.gd:whisker_scan)
## Kept tunable here (unlike the fixed angle fan) since range/mount
## height/pitch are the knobs most likely worth sweeping.
@export var whisker_max_range: float = 12.0
@export var whisker_pitch_deg: float = 30.0
@export var whisker_height_offset: float = 1.0
@export var whisker_forward_offset: float = 1.5

## --- Edge probe geometry: two near-perpendicular downward rays (angle
## +-90 relative to forward -- see OnboardSensing.whisker_scan) at close to
## the car's CURRENT position, not looking ahead like the whiskers above.
## Added after the first Tier B candidate (aggregate_score 0.041) showed
## why forward-only whiskers aren't enough: the physical road (~1.85-2m
## half-width) is narrower than the scoring tolerance TRACK_WIDTH=4.0, so
## the car drifts off the real pavement before the forward whisker fan
## (aimed at future path, not current position) reacts, and once off, no
## whisker finds pavement to correct back toward. A steep pitch keeps their
## ground reach short on purpose (this is a "how close am I to the edge
## RIGHT NOW" check, not a lookahead one).
@export var edge_probe_pitch_deg: float = 60.0
@export var edge_probe_max_range: float = 6.0
@export var edge_probe_forward_offset: float = 0.3
@export var edge_probe_height_offset: float = 1.0

## How strongly to turn toward the whisker-confirmed "pavement found here"
## direction: degrees of steer per degree of confirmation-weighted whisker
## angle, before clamping to max_steer.
@export var steer_gain: float = 1.5
## How strongly the RIGHT-minus-LEFT edge probe distance difference (in
## meters) pulls steering back toward center, in degrees of correction per
## meter of asymmetry. This is Tier B's analogue of Tier A's
## cross_track_gain -- direct, immediate recentering, distinct from (and
## added on top of) the forward whiskers' future-path-following steer_gain.
@export var lateral_gain_deg_per_meter: float = 8.0
## If EITHER edge probe reads above (edge_probe_max_range minus this), treat
## it as "no pavement found nearby on that side, already close to/past the
## edge" and brake hard regardless of heading -- same role as Tier A's
## safety_margin.
@export var edge_safety_margin: float = 3.0
## Below this fraction of the maximum possible whisker confirmation-weight
## sum (see heading_steer's weight_sum -- every forward whisker confirming
## pavement at distance 0 would be 1.0), start braking proportionally.
## Added after a visual capture (tests/capture_run.gd) showed trailer_truck
## rolling over / getting wedged navigating a tight hairpin loop at high
## speed (~97-106m in): most forward whiskers miss pavement approaching a
## sharp turn (the road curves away from where they're aimed), so a LOW
## confirmation sum is a real, usable "tight corner ahead" signal -- an
## earlier version dismissed the forward whiskers as braking-uninformative,
## which held for gentle curves but not this specific hairpin.
@export var whisker_confirmation_brake_threshold: float = 0.85
## Slope ratio (from onboard_sensing.slope_probe, heading-only) above which
## the AI treats the road ahead as a descent and slows for it.
@export var slope_speed_threshold: float = 0.25
## How sharply speed drops on steep descents (higher = brakes harder).
@export var slope_braking_factor: float = 2.5
## Distance ahead (along the car's own heading) to check for a crest.
@export var crest_preview: float = 10.0
@export var crest_speed_cap: float = 6.0
## If actual speed stays below this (m/s) while the AI is actively trying to
## accelerate, for longer than stuck_time_threshold, trigger a recovery
## maneuver. Same rationale as Tier A: something off the AI's radar (e.g. a
## trailer snagged on track geometry) is physically blocking progress, and
## no amount of sensing predicts that in advance.
@export var stuck_speed_threshold: float = 0.8
@export var stuck_time_threshold: float = 1.5
## How long (seconds) a recovery maneuver reverses for before trying forward
## again.
@export var recovery_reverse_time: float = 1.2

## Counts down while a recovery (reverse) maneuver is in progress; >0 means
## "currently recovering". Same mechanism as Tier A -- generic, based only
## on linear_velocity, no curve dependency, so it carries over unchanged.
var _stuck_timer: float = 0.0
var _recovery_timer: float = 0.0


func _tick(delta: float) -> int:
	var car: VehicleBody3D = _get_bb_var("car") as VehicleBody3D
	if not car:
		return BTTask.FAILURE

	_drive(car, delta)
	return BTTask.RUNNING


func _drive(car: VehicleBody3D, delta: float) -> void:
	var space_state: PhysicsDirectSpaceState3D = car.get_world_3d().direct_space_state
	# Computed once per tick and threaded through every sensing call below --
	# the physics-body set under a vehicle never changes mid-race, so redoing
	# this recursive scene-tree walk per call (whisker_scan x2, slope_probe,
	# crest_ahead) was pure waste, worse for tow_truck's chain-linked trailer.
	var exclude: Array[RID] = OnboardSensing.collect_body_rids(car)

	var whisker_config: Dictionary = {
		"max_range": whisker_max_range,
		"pitch_deg": whisker_pitch_deg,
		"height_offset": whisker_height_offset,
		"forward_offset": whisker_forward_offset,
	}
	var distances: Array[float] = OnboardSensing.whisker_scan(space_state, car, whisker_config, exclude)
	var angles_deg: Array[float] = OnboardSensing.DEFAULT_ANGLES_DEG

	# --- Heading: SHORT whisker distance means the downward ray found solid
	# pavement close by in that direction; LONG distance (up to max_range)
	# means it found no ground within reach -- that direction runs off the
	# edge or into a gap (see onboard_sensing.gd's whisker_scan doc). Weight
	# each angle by how strongly it CONFIRMS pavement (max_range - distance,
	# so a short/close hit gets a high weight and a miss gets ~zero) and
	# steer toward the confirmation-weighted centroid -- pulled toward
	# directions with solid ground ahead, away from directions that miss.
	# Bug history: an earlier version weighted by raw distance instead
	# (steering TOWARD the longest/most-open-looking reading), which is
	# backwards given the semantics above -- it actively steered the car
	# off the road every time (aggregate_score 0.041, see ai/COMPARISON.md).
	# Confirmed via debug_events telemetry: L=6.00 (max_range, i.e. missed)
	# read as "more open than R=1.35" (on pavement) and pulled steering
	# further toward the miss.
	var weighted_angle_sum: float = 0.0
	var weight_sum: float = 0.0
	for i in range(distances.size()):
		var confirmation: float = maxf(whisker_max_range - distances[i], 0.0)
		weighted_angle_sum += confirmation * angles_deg[i]
		weight_sum += confirmation
	var heading_angle_deg: float = weighted_angle_sum / maxf(weight_sum, 0.001)
	var heading_steer: float = deg_to_rad(heading_angle_deg) * steer_gain

	# --- Edge probes: LEFT (+90) and RIGHT (-90) distance to pavement at
	# the car's CURRENT position -- see the class doc above for why this is
	# needed in addition to the forward whiskers. Same short=pavement/
	# long=edge semantics as above: right_distance GROWING relative to
	# left_distance means the RIGHT side is running out of confirmed
	# pavement, which should steer LEFT (positive correction) -- hence
	# (right - left), matching whisker_scan's established convention that
	# positive angle/steer = left (see onboard_sensing.gd's class doc).
	var edge_config: Dictionary = {
		"angles_deg": [90.0, -90.0],
		"forward_offset": edge_probe_forward_offset,
		"height_offset": edge_probe_height_offset,
		"pitch_deg": edge_probe_pitch_deg,
		"max_range": edge_probe_max_range,
	}
	var edge_distances: Array[float] = OnboardSensing.whisker_scan(space_state, car, edge_config, exclude)
	var left_distance: float = edge_distances[0]
	var right_distance: float = edge_distances[1]
	var lateral_steer: float = deg_to_rad((right_distance - left_distance) * lateral_gain_deg_per_meter)

	var steer_angle: float = clampf(heading_steer + lateral_steer, -max_steer, max_steer)

	# --- Recovery: if wedged (see stuck detection below), reverse out with
	# opposite steering instead of grinding the throttle in place. Same
	# control surface a human stuck in a ditch would use.
	if _recovery_timer > 0.0:
		_recovery_timer -= delta
		car.steering = clampf(-steer_angle, -max_steer, max_steer)
		car.engine_force = -engine_power
		car.brake = 0.0
		return

	car.steering = steer_angle

	# --- Throttle ---
	var current_speed: float = car.linear_velocity.length()

	# Target speed: cruise at max_speed by default, then brake proportionally
	# as the forward whiskers' total pavement-confirmation weight drops
	# below whisker_confirmation_brake_threshold -- most whiskers miss when
	# the road ahead curves away sharply (a tight turn/hairpin), so a low
	# confirmation fraction is a real "slow down, tight corner ahead"
	# signal (see whisker_confirmation_brake_threshold's doc for the
	# rollover this was added to fix).
	var target_speed: float = max_speed
	var confirmation_fraction: float = clampf(
			weight_sum / (angles_deg.size() * whisker_max_range), 0.0, 1.0)
	if confirmation_fraction < whisker_confirmation_brake_threshold:
		target_speed = minf(target_speed, lerpf(min_speed, max_speed,
				confirmation_fraction / whisker_confirmation_brake_threshold))

	# Slow down for steep DESCENTS (ramps), same rationale as Tier A: climbs
	# are deliberately NOT braked for since they need momentum to crest, not
	# less of it.
	var slope: float = maxf(OnboardSensing.slope_probe(space_state, car, 6.0, exclude), 0.0)
	if slope > slope_speed_threshold:
		var slope_target: float = lerpf(max_speed, min_speed,
				clampf((slope - slope_speed_threshold) * slope_braking_factor, 0.0, 1.0))
		target_speed = minf(target_speed, slope_target)

	# Crest ahead (climbing then descending): cap speed hard regardless of
	# slope steepness, since cresting too fast launches the car airborne and
	# steering does nothing while it's in the air.
	if OnboardSensing.crest_ahead(space_state, car, crest_preview, exclude):
		target_speed = minf(target_speed, crest_speed_cap)

	# Last-resort safety net: either edge probe reading close to
	# edge_probe_max_range means it found no pavement nearby on that side
	# -- a wheel is close to (or already past) the physical edge -- brake
	# hard regardless of heading, same role as Tier A's safety_margin
	# (there driven by lateral_error vs the curve; here driven by the edge
	# probes since this tier has no curve).
	if maxf(left_distance, right_distance) > edge_probe_max_range - edge_safety_margin:
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

	# Stuck detection: actively trying to accelerate but barely moving, for
	# too long, means something off the AI's radar is physically blocking
	# forward progress. Trigger a recovery maneuver rather than grinding the
	# throttle uselessly for the rest of the race.
	if car.engine_force > 0.0 and current_speed < stuck_speed_threshold:
		_stuck_timer += delta
		if _stuck_timer > stuck_time_threshold:
			_recovery_timer = recovery_reverse_time
			_stuck_timer = 0.0
	else:
		_stuck_timer = 0.0


func _get_bb_var(var_name: String) -> Variant:
	var bb := get_blackboard()
	if bb and bb.has_var(var_name):
		return bb.get_var(var_name)
	return null
