class_name TrackGenerator
extends RefCounted

## Procedural race-track curve generation, seeded for reproducibility.
##
## Produces a Curve3D whose points can be copied straight into a Path3D
## driving a CSGPolygon3D in Path mode (mode = 2), which handles the actual
## mesh/collision extrusion on its own.

## Distance between consecutive waypoints, in meters.
const SEGMENT_LENGTH := 6.0
## Maximum heading change per waypoint.
const MAX_TURN_RAD := deg_to_rad(22.0)
## Maximum pitch (uphill/downhill) angle reached by the track.
const MAX_PITCH_RAD := deg_to_rad(8.0)
## Non-adjacent segments closer than this (in meters) make the track
## overlap itself -- rejected, since RaceManager's distance tracking
## (Curve3D.get_closest_offset) assumes a single unambiguous closest point.
const MIN_CLEARANCE := 10.0
## Fall back to a straight track if no candidate passes this many attempts.
const MAX_ATTEMPTS := 30


## Generates a valid (non-self-overlapping) track curve for the given seed.
## Retries with attempt-derived sub-seeds on overlap, so the same seed
## always produces the same final result.
static func generate_valid_curve(num_points: int, seed_value: int) -> Curve3D:
	var rng := RandomNumberGenerator.new()
	var curve: Curve3D
	for attempt in MAX_ATTEMPTS:
		rng.seed = hash(Vector2i(seed_value, attempt))
		curve = _generate_curve(num_points, rng)
		if _is_valid(curve):
			return curve
	# Never return a rejected candidate. A straight route always has clearance.
	curve = Curve3D.new()
	for i in maxi(num_points, 2):
		curve.add_point(Vector3(0, 0, i * SEGMENT_LENGTH))
	_smooth_handles(curve)
	return curve


static func _generate_curve(num_points: int, rng: RandomNumberGenerator) -> Curve3D:
	var curve := Curve3D.new()
	var pos := Vector3.ZERO
	var heading := 0.0
	var pitch := 0.0

	for i in num_points:
		curve.add_point(pos)
		heading += rng.randf_range(-MAX_TURN_RAD, MAX_TURN_RAD)
		pitch = clampf(pitch + rng.randf_range(-0.05, 0.05), -MAX_PITCH_RAD, MAX_PITCH_RAD)
		var dir := Vector3(sin(heading), sin(pitch), cos(heading)).normalized()
		pos += dir * SEGMENT_LENGTH

	_smooth_handles(curve)
	return curve


## Catmull-Rom-like tangents (direction towards the neighboring points) so
## the CSG extrusion doesn't kink at every waypoint.
static func _smooth_handles(curve: Curve3D) -> void:
	for i in curve.point_count:
		var prev: Vector3 = curve.get_point_position(maxi(i - 1, 0))
		var next: Vector3 = curve.get_point_position(mini(i + 1, curve.point_count - 1))
		var tangent := (next - prev) * 0.25
		curve.set_point_in(i, -tangent)
		curve.set_point_out(i, tangent)


static func _is_valid(curve: Curve3D) -> bool:
	# Check the actual smoothed route, excluding nearby points along the road.
	var points := curve.get_baked_points()
	var offsets := PackedFloat32Array([0.0])
	for i in range(1, points.size()):
		offsets.append(offsets[-1] + points[i - 1].distance_to(points[i]))
	for i in range(points.size() - 1):
		for j in range(i + 2, points.size() - 1):
			if offsets[j] - offsets[i + 1] < MIN_CLEARANCE * 2.0:
				continue
			var closest := Geometry3D.get_closest_points_between_segments(
					points[i], points[i + 1], points[j], points[j + 1])
			if closest[0].distance_to(closest[1]) < MIN_CLEARANCE:
				return false
	return points.size() >= 2
