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
## Give up refining after this many seeded attempts and return the last one.
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
	var n := curve.point_count
	for i in n - 1:
		var a1: Vector3 = curve.get_point_position(i)
		var a2: Vector3 = curve.get_point_position(i + 1)
		for j in range(i + 2, n - 1):
			var b1: Vector3 = curve.get_point_position(j)
			var b2: Vector3 = curve.get_point_position(j + 1)
			if _segment_distance(a1, a2, b1, b2) < MIN_CLEARANCE:
				return false
	return true


## Closest distance between two 3D segments, sampled (cheap and accurate
## enough at MIN_CLEARANCE / SEGMENT_LENGTH scale -- no need for an exact
## closed-form segment-segment distance here).
static func _segment_distance(p1: Vector3, p2: Vector3, p3: Vector3, p4: Vector3) -> float:
	const SAMPLES := 4
	var closest := INF
	for i in SAMPLES + 1:
		var a: Vector3 = p1.lerp(p2, float(i) / SAMPLES)
		for j in SAMPLES + 1:
			var b: Vector3 = p3.lerp(p4, float(j) / SAMPLES)
			closest = minf(closest, a.distance_to(b))
	return closest
