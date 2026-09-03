extends RefCounted
class_name OnboardSensing
## Vehicle-relative sensing helpers for the Tier B driving policy: whisker
## raycasts against the track surface, a downward surface probe, and a
## heading-only slope/crest estimate. NONE of this reads the Path3D curve --
## see ai/README_RESEARCH.md's "Known caveat" section for why that matters.
## Static, stateless; called from ai_drive_task.gd's _tick().

## Default whisker fan, in degrees relative to the car's own forward
## direction (0 = straight ahead). Kept as a plain constant rather than an
## exported tunable: it's sensor-rig geometry, not a driving-behavior knob.
const DEFAULT_ANGLES_DEG: Array[float] = [-45.0, -25.0, -10.0, 0.0, 10.0, 25.0, 45.0]


## One angled-downward raycast per entry of `angles_deg`, fanned out around
## the car's own forward direction (car's +Z, per vehicle.gd's turbo thrust
## `constant_force = global_transform.basis.z * 400.0`). Rotated around the
## car's own up axis (not world-up), so the fan tracks vehicle tilt on
## slopes/banking, like a real bumper-mounted sensor rig would.
##
## There are no edge/guardrail colliders on this track -- only the road
## surface itself (town/model/racetrack_csg.tscn's CSGPolygon3D collision).
## So "distance to edge" is inferred indirectly: on open pavement a whisker
## hits the road at a short, fairly predictable distance; near the edge of
## the slab the hit point falls away, or the ray clears the edge and hits
## nothing within max_range. Both cases collapse to `max_range` (a miss is
## maximal edge risk, same as a very-far hit), so callers get one plain
## float per direction.
## `exclude`: RIDs to skip (the car's own chassis/wheels/trailer). Callers
## making several sensing calls per physics tick on the same car (see
## ai_drive_task.gd's _drive()) should compute this ONCE via
## collect_body_rids() and pass it through -- the physics-body set under a
## vehicle never changes mid-race, so a fresh recursive scene-tree walk on
## every whisker_scan()/slope_probe()/crest_ahead() call (up to 4x/tick,
## worse for tow_truck's chain-linked trailer) is pure waste. Left optional
## and self-computing when omitted so each function still works standalone.
## `debug_out`, if a non-null Array is passed, gets one {origin, end, hit}
## Dictionary appended per ray (world-space points; `hit` true = pavement
## found, false = the ray reached max_range without a hit) -- purely for the
## in-game sensor visualization (see ai_drive_task.gd's show_sensor_debug),
## no effect on the returned distances or any driving/scoring behavior.
static func whisker_scan(space_state: PhysicsDirectSpaceState3D, car: VehicleBody3D, config: Dictionary = {}, exclude: Array[RID] = [], debug_out: Array = []) -> Array[float]:
	var angles_deg: Array = config.get("angles_deg", DEFAULT_ANGLES_DEG)
	var forward_offset: float = config.get("forward_offset", 1.5)
	var height_offset: float = config.get("height_offset", 1.0)
	var pitch_deg: float = config.get("pitch_deg", 30.0)
	var max_range: float = config.get("max_range", 12.0)

	var car_xform: Transform3D = car.global_transform
	var forward_dir: Vector3 = car_xform.basis.z.normalized()
	var up_dir: Vector3 = car_xform.basis.y.normalized()
	var origin: Vector3 = car_xform.origin + up_dir * height_offset + forward_dir * forward_offset
	var pitch_rad: float = deg_to_rad(pitch_deg)
	if exclude.is_empty():
		exclude = collect_body_rids(car)

	var distances: Array[float] = []
	for angle_deg: float in angles_deg:
		var horizontal_dir: Vector3 = forward_dir.rotated(up_dir, deg_to_rad(angle_deg)).normalized()
		var ray_dir: Vector3 = (horizontal_dir * cos(pitch_rad) - up_dir * sin(pitch_rad)).normalized()
		var to: Vector3 = origin + ray_dir * max_range
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(origin, to, 0xFFFFFFFF, exclude)
		var result: Dictionary = space_state.intersect_ray(query)
		var hit: bool = not result.is_empty()
		if hit:
			distances.append(origin.distance_to(result.position))
		else:
			distances.append(max_range)
		if debug_out != null:
			debug_out.append({
				"origin": origin,
				"end": result.position if hit else to,
				"hit": hit,
			})
	return distances


## Straight-down probe at an arbitrary point -- same RAYCAST technique as
## race_manager.gd's _find_surface_y() (a private instance method there, not
## reusable from here), reimplemented locally. Gives the real physical
## surface Y, which can differ from a naive "car.global_position.y".
##
## Deliberately does NOT reuse _find_surface_y()'s sanity-margin guard
## (reject a hit too far from the query point's own Y -- e.g. the scene's
## distant safety-net CollisionFloor at y=-10, well below the real track).
## Tried it (a fixed 6.0m margin) and reverted: this tier's probes are
## offset up to crest_preview/probe_ahead (10m/6m) along the car's own
## HEADING, not the track's true curve (no curve access, by design) --
## approaching a bend even slightly off-heading, a real ahead-point can
## legitimately land far enough off-track, in elevation, for a same-margin
## guard to reject the genuine reading and fall back to `point.y` (built
## from the car's current Y, a much worse estimate of ground height several
## meters ahead on a slope) instead. Confirmed by measurement: enabling the
## guard collapsed car_base's score from ~0.795/291m to ~0.185/68m,
## regressing far more than the CollisionFloor false-positive it was meant
## to prevent has ever actually been observed to cause in this tier's
## tuning history (see ai/COMPARISON.md). Accepted as a known risk instead.
static func probe_surface_y(space_state: PhysicsDirectSpaceState3D, point: Vector3, exclude: Array[RID] = []) -> float:
	var from: Vector3 = point + Vector3.UP * 20.0
	var to: Vector3 = point + Vector3.DOWN * 20.0
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF, exclude)
	var result: Dictionary = space_state.intersect_ray(query)
	if not result.is_empty():
		return result.position.y
	return point.y


## Slope estimate along the car's OWN heading (not the track's true curve,
## which this tier cannot see): probes the surface Y at the car's position
## and again `probe_ahead` meters further along its current forward
## direction. Positive = descending ahead, matching Tier A's
## `ai_drive_task.gd` sign convention for `slope`. Weaker than Tier A's
## curve-based lookahead -- if the car is aimed off the true road direction,
## this probe is aimed off too.
static func slope_probe(space_state: PhysicsDirectSpaceState3D, car: VehicleBody3D, probe_ahead: float = 6.0, exclude: Array[RID] = []) -> float:
	var car_xform: Transform3D = car.global_transform
	var forward_dir: Vector3 = car_xform.basis.z.normalized()
	if exclude.is_empty():
		exclude = collect_body_rids(car)
	var here_y: float = probe_surface_y(space_state, car_xform.origin, exclude)
	var ahead_point: Vector3 = car_xform.origin + forward_dir * probe_ahead
	var ahead_y: float = probe_surface_y(space_state, ahead_point, exclude)
	return (here_y - ahead_y) / maxf(probe_ahead, 0.001)


## True if the car's own heading climbs then descends within `crest_ahead`
## meters (a crest/hilltop/jump) -- same shape-check as Tier A's
## `_has_crest_ahead`, just probed along the car's heading instead of the
## curve.
static func crest_ahead(space_state: PhysicsDirectSpaceState3D, car: VehicleBody3D, crest_preview: float = 10.0, exclude: Array[RID] = []) -> bool:
	var car_xform: Transform3D = car.global_transform
	var forward_dir: Vector3 = car_xform.basis.z.normalized()
	if exclude.is_empty():
		exclude = collect_body_rids(car)
	var h0: float = probe_surface_y(space_state, car_xform.origin, exclude)
	var h_mid: float = probe_surface_y(space_state, car_xform.origin + forward_dir * (crest_preview * 0.5), exclude)
	var h1: float = probe_surface_y(space_state, car_xform.origin + forward_dir * crest_preview, exclude)
	return h_mid > h0 and h_mid > h1


## Collects the RIDs of every physics body under the car's own scene root
## (CarBase), so whisker/probe raycasts never self-hit the car's own
## chassis/wheels or -- for trailer_truck/tow_truck -- the towed
## trailer/chain bodies linked by joints a few meters behind. Public (no
## leading underscore) so callers making several sensing calls per tick can
## compute this once and pass it to each -- see whisker_scan()'s doc.
static func collect_body_rids(car: VehicleBody3D) -> Array[RID]:
	var root: Node = car.get_parent() if car.get_parent() else car
	var rids: Array[RID] = []
	_collect_body_rids_recursive(root, rids)
	return rids


static func _collect_body_rids_recursive(node: Node, rids: Array[RID]) -> void:
	if node is PhysicsBody3D:
		rids.append((node as PhysicsBody3D).get_rid())
	for child in node.get_children():
		_collect_body_rids_recursive(child, rids)
