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

## --- Trailer-aware steering smoothing: OnboardSensing.collect_body_rids(car)
## already walks the car's own scene root every tick to build the whisker
## raycast exclude list; its SIZE, for free, tells us the shape of this
## vehicle's attached bodies -- car_base has exactly 1 PhysicsBody3D under
## its root, trailer_truck has 2 (body + one rigidly-jointed Trailer),
## tow_truck has 7 (body + 5 chain links + towed Body2). This is
## introspection of the AI's OWN vehicle structure, not the track curve or
## race_manager state, and not hidden from a human, who obviously knows by
## looking whether they're towing a trailer.
## Screenshot diagnosis (runs/diag_trailer_capture/) showed trailer_truck's
## failure at the HugeTire tunnel/hairpin (ai/COMPARISON.md) is a Y FALL,
## consistent with the towed Trailer body swinging wide on the hairpin.
## Slowing trailer_truck down (min_speed floor scale) helped in its best
## run but stayed high-variance across 3 tried scales (results.tsv
## 1c3bcc7/e1cc363/afa09d0) -- the worst case barely moved, suggesting raw
## speed isn't the dominant factor. Trying a different angle instead:
## SMOOTHING steering input (low-pass filtered toward the target each
## tick) specifically for the rigidly-jointed trailer case, on the theory
## that a JERKY steering command (this policy recomputes steer fresh every
## tick from live sensor noise) whips the towed body wide via the joint
## more than a smooth one would, independent of overall speed.
@export var trailer_steer_smoothing: float = 0.3

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
## Angular velocity around the car's up axis (rad/s) above which the car is
## treated as turning/rotating fast enough to brake toward min_speed*0.5 and
## help regain control. See the yaw-rate safety net's inline doc (in
## _drive()) for the screenshot diagnosis that motivated this and why 0.5
## (empirically swept, not Tier A's 1.2) is the calibrated value here.
@export var yaw_rate_threshold: float = 0.5
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
## Previous tick's applied steering angle, used only for trailer_steer_smoothing's
## low-pass filter (rigid-trailer vehicles only -- see its doc).
var _prev_steer: float = 0.0

## Draws this tier's whisker/edge-probe rays in the 3D world every tick, so
## a human watching the race can see what a sensor-only (no track-curve,
## no vision) AI is actually reacting to -- green where a ray finds
## pavement, red where it doesn't (edge/gap). Purely cosmetic: computed from
## debug_out data OnboardSensing.whisker_scan() already gathers while doing
## the real sensing work below, never feeds back into steering/throttle.
## Skipped entirely under --headless (DisplayServer "headless"): the
## research/tuning loop (tests/run_eval.gd, PROGRAM.md) runs many short
## headless races per hour and has no display to show this on anyway.
@export var show_sensor_debug: bool = true
var _debug_mesh: ImmediateMesh = null
var _debug_mesh_instance: MeshInstance3D = null


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
	# See trailer_steer_smoothing's doc: exclude.size() == 2 specifically
	# matches trailer_truck's signature (body + one rigidly-jointed
	# Trailer), NOT tow_truck's (7: body + 5 chain links + towed Body2).
	var is_rigid_trailer: bool = exclude.size() == 2
	# car_base (exclude.size()==1) has no trailer at all -- see
	# yaw_rate_threshold's doc for why the yaw-rate safety net is gated to
	# this instead of applying globally.
	var has_any_trailer: bool = exclude.size() > 1

	var whisker_config: Dictionary = {
		"max_range": whisker_max_range,
		"pitch_deg": whisker_pitch_deg,
		"height_offset": whisker_height_offset,
		"forward_offset": whisker_forward_offset,
	}
	# Only bothers collecting ray geometry (a handful of Vector3s/tick) when
	# there's actually a debug mesh to feed it to -- see _debug_rays_enabled().
	var whisker_debug: Array = []
	var distances: Array[float] = OnboardSensing.whisker_scan(space_state, car, whisker_config, exclude, whisker_debug)
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
	var edge_debug: Array = []
	var edge_distances: Array[float] = OnboardSensing.whisker_scan(space_state, car, edge_config, exclude, edge_debug)
	var left_distance: float = edge_distances[0]
	var right_distance: float = edge_distances[1]
	var lateral_steer: float = deg_to_rad((right_distance - left_distance) * lateral_gain_deg_per_meter)

	if _debug_rays_enabled():
		_draw_debug_rays(car, whisker_debug + edge_debug)

	var raw_steer_angle: float = clampf(heading_steer + lateral_steer, -max_steer, max_steer)
	# Low-pass filter the steering command for rigid-trailer vehicles only
	# (see trailer_steer_smoothing's doc) -- car_base/tow_truck get the raw
	# value unchanged (trailer_steer_smoothing >= 1.0 would be a no-op too,
	# but gating explicitly keeps their behavior bit-identical to before
	# this experiment, same audit-friendly pattern as the min_speed-scale
	# attempts).
	var steer_angle: float = raw_steer_angle
	if is_rigid_trailer:
		steer_angle = lerpf(_prev_steer, raw_steer_angle, trailer_steer_smoothing)
	_prev_steer = steer_angle

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

	# Yaw-rate safety net: brake hard if the car is turning/rotating fast
	# (spinning, not just cornering). Screenshot diagnosis
	# (runs/diag_tow_capture/012_t24s.png) showed tow_truck rotated ~90
	# degrees sideways, wedged across the narrow bridge approaching the
	# HugeTire tunnel -- a spin-out, a different failure mode from the
	# forward wedge every other fix targeted (results.tsv 786fc0a onward),
	# which is why none of them helped. Tier A tried a yaw-rate net before
	# (threshold 1.2 rad/s) and reverted it as miscalibrated for THAT
	# tier's curve-following policy -- ordinary hard cornering there
	# already produced ~2 rad/s. Empirically swept for this tier instead of
	# assuming the same number applies (0.5-3.0 tried, see results.tsv):
	# 0.5 rad/s is where it actually engages usefully here -- this tier's
	# whisker-driven steering apparently doesn't produce Tier A's ~2 rad/s
	# yaw rates even in normal hard turns, so a much lower threshold is
	# both correctly calibrated and safe here.
	# Gated to trailer-equipped vehicles only (has_any_trailer): the first
	# version of this fix (results.tsv 965ad5f, kept) applied globally and
	# WORKED for tow_truck/trailer_truck but regressed car_base (0.795 ->
	# 0.374, becoming the new bottleneck) -- car_base has no trailer at
	# all, so whatever it does at high yaw rate evidently isn't a spin-out
	# needing this net. Testing whether excluding it recovers car_base
	# while keeping the tow_truck/trailer_truck gains.
	var yaw_rate: float = absf(car.angular_velocity.y)
	if has_any_trailer and yaw_rate > yaw_rate_threshold:
		target_speed = minf(target_speed, min_speed * 0.5)

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


## show_sensor_debug is a per-instance tunable (so a research/tuning branch
## could disable it), but there's no point ever drawing under --headless --
## no display exists to show it on, and the tuning loop runs many races/hour
## (see PROGRAM.md) where the extra RenderingServer traffic is pure waste.
func _debug_rays_enabled() -> bool:
	return show_sensor_debug and DisplayServer.get_name() != "headless"


## World-space width of each drawn ray "beam". A single-pixel GL_LINES ray
## (the first version of this) was nearly invisible from the game's chase
## camera -- drawn as a thin flat ribbon instead, extruded sideways from
## each ray so it reads as a solid beam from a typical above-and-behind
## viewing angle.
const _DEBUG_RAY_WIDTH := 0.05

## Lazily creates (once) and redraws (every tick) a single reusable
## ImmediateMesh under `car` showing this tier's whisker/edge-probe rays as
## flat ribbons: green = pavement confirmed, red = ray reached max_range
## without a hit (the "I can't see solid ground that way" signal the driving
## logic above actually reacts to). top_level=true so the mesh's own
## vertices, already computed in world space by OnboardSensing.whisker_scan(),
## don't get double-transformed through the car's rotation.
func _draw_debug_rays(car: VehicleBody3D, rays: Array) -> void:
	if not is_instance_valid(_debug_mesh_instance):
		_debug_mesh = ImmediateMesh.new()
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.vertex_color_use_as_albedo = true
		material.no_depth_test = true
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Most whisker origins sit low/close to the chassis (short forward
		# offset, steep downward pitch -- see whisker_scan's doc), so from
		# the game's above-and-behind chase camera the car body itself would
		# otherwise hide most of each beam. no_depth_test alone only skips
		# the depth TEST, not draw order -- routing through the transparent
		# pass (even at full alpha) plus max render_priority is what
		# actually guarantees this draws on top of the car mesh, the same
		# "always visible" trick used for debug-draw overlays generally.
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.render_priority = 100
		_debug_mesh_instance = MeshInstance3D.new()
		_debug_mesh_instance.name = "SensorDebugRays"
		_debug_mesh_instance.mesh = _debug_mesh
		_debug_mesh_instance.material_override = material
		_debug_mesh_instance.top_level = true
		car.add_child(_debug_mesh_instance)

	_debug_mesh.clear_surfaces()
	if rays.is_empty():
		return
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for ray: Dictionary in rays:
		var origin: Vector3 = ray["origin"]
		var end: Vector3 = ray["end"]
		var dir: Vector3 = (end - origin)
		if dir.length_squared() < 0.0001:
			continue
		dir = dir.normalized()
		# Extrude sideways (roughly horizontal, since every ray here pitches
		# down from near-horizontal rather than straight down) so the ribbon
		# has real screen-space width from the game's above-and-behind
		# chase camera, instead of vanishing to a sub-pixel line.
		var side: Vector3 = dir.cross(Vector3.UP)
		if side.length_squared() < 0.0001:
			side = Vector3.RIGHT
		side = side.normalized() * (_DEBUG_RAY_WIDTH * 0.5)

		var color: Color = Color.LIME_GREEN if ray["hit"] else Color.RED
		var a: Vector3 = origin + side
		var b: Vector3 = origin - side
		var c: Vector3 = end - side
		var d: Vector3 = end + side
		_debug_mesh.surface_set_color(color)
		_debug_mesh.surface_add_vertex(a)
		_debug_mesh.surface_set_color(color)
		_debug_mesh.surface_add_vertex(b)
		_debug_mesh.surface_set_color(color)
		_debug_mesh.surface_add_vertex(c)
		_debug_mesh.surface_set_color(color)
		_debug_mesh.surface_add_vertex(a)
		_debug_mesh.surface_set_color(color)
		_debug_mesh.surface_add_vertex(c)
		_debug_mesh.surface_set_color(color)
		_debug_mesh.surface_add_vertex(d)
	_debug_mesh.surface_end()
