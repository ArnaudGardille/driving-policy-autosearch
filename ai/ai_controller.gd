extends Node3D
## AI driver that follows a Path3D curve. Drives a VehicleBody3D with steering
## and throttle control. Attach to a node, then call setup(car, path).

## How far ahead (meters) the AI looks to steer towards.
@export var look_ahead: float = 8.0
## Base engine force applied when accelerating.
@export var engine_power: float = 35.0
## Maximum steering angle in radians.
@export var max_steer: float = 0.4
## Minimum speed to maintain.
@export var min_speed: float = 5.0
## Maximum target speed.
@export var max_speed: float = 25.0
## How sharply speed drops on turns.
@export var braking_factor: float = 3.0

var _car: VehicleBody3D
var _path: Path3D


func setup(p_car: VehicleBody3D, p_path: Path3D) -> void:
	_car = p_car
	_path = p_path


func _physics_process(_delta: float) -> void:
	if not _car or not _path:
		return
	if _car.freeze:
		return

	var curve: Curve3D = _path.curve
	if not curve or curve.point_count < 2:
		return

	# Find current position along the curve.
	var car_global: Vector3 = _car.global_position
	var car_local: Vector3 = _path.global_transform.affine_inverse() * car_global
	var current_offset: float = curve.get_closest_offset(car_local)
	var total_length: float = curve.get_baked_length()

	# --- Steering ---
	var target_offset: float = current_offset + look_ahead
	if target_offset > total_length:
		target_offset = total_length

	var target_local: Vector3 = curve.sample_baked(target_offset)
	var target_global: Vector3 = _path.global_transform * target_local

	# Transform target to car's local space.
	var car_transform: Transform3D = _car.global_transform
	var local_target: Vector3 = car_transform.affine_inverse() * target_global

	var steer_angle: float = atan2(local_target.x, local_target.z)
	steer_angle = clampf(steer_angle, -max_steer, max_steer)
	_car.steering = steer_angle

	# --- Throttle ---
	var current_speed: float = _car.linear_velocity.length()

	var dir_current := _sample_direction(curve, current_offset)
	var dir_ahead := _sample_direction(curve, current_offset + look_ahead * 0.5)
	var curvature: float = absf(dir_current.angle_to(dir_ahead))

	var target_speed: float = max_speed
	if curvature > 0.3:
		target_speed = lerpf(max_speed, min_speed, clampf((curvature - 0.3) * braking_factor, 0.0, 1.0))

	if current_speed < target_speed:
		_car.engine_force = engine_power
		_car.brake = 0.0
	else:
		_car.engine_force = 0.0
		_car.brake = clampf((current_speed - target_speed) * 0.5, 0.0, 5.0)


func _sample_direction(curve: Curve3D, offset: float) -> Vector3:
	var p1 := curve.sample_baked(maxf(offset - 0.5, 0.0))
	var p2 := curve.sample_baked(minf(offset + 0.5, curve.get_baked_length()))
	var diff := p2 - p1
	if diff.length_squared() < 0.0001:
		return Vector3.FORWARD
	return diff.normalized()
