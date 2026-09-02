extends BTAction
## Tier C Phase 2: closed-loop vision driving policy. Unlike Tier A/B, this
## task reads NOTHING from the blackboard except "car" -- no Path3D curve,
## no onboard raycasts/proprioception sensing, only whatever the mounted
## camera sees. Every decision comes from a real-time query to the external
## inference server (../truck-town-vision-training/infer_server.py, loading
## the checkpoint trained by train.py on the Phase 1 dataset) over
## VisionInferenceClient (ai/vision/vision_inference_client.gd).
##
## Camera setup (position/rotation/FOV) is deliberately identical to
## ai/vision/record_dataset.gd's recording camera -- the model was trained
## on frames from exactly that viewpoint, so driving from a different one
## would be an unannounced train/inference distribution shift.
##
## Decision cadence: queries the server every decision_interval_s seconds
## of simulated time, then HOLDS that action on every physics tick in
## between (same "hold the last decision" pattern a fixed-rate controller
## uses) rather than querying every physics tick -- matches this being a
## deliberately coarser-than-60Hz policy, and bounds the per-tick cost of a
## real render-readback + a network round trip.
##
## No stuck/recovery logic (unlike Tier A/B) -- this is the first working
## closed-loop version, scoped to "does the vision policy drive at all",
## not yet feature-matched with the sensor tiers. See ai/vision/README.md.

## Must match record_dataset.gd's CAMERA_* constants -- see this file's
## class doc above for why. Duplicated rather than shared because the two
## files have no common parent to hang a shared constant off without
## introducing a new dependency between an offline capture tool and a
## closed-loop driver; kept in sync by this comment on both sides.
const CAMERA_LOCAL_POSITION := Vector3(0.0, 1.1, 0.6)
const CAMERA_LOCAL_ROTATION_DEG := Vector3(0.0, 180.0, 0.0)
const CAMERA_FOV := 80.0

@export var inference_host: String = "127.0.0.1"
@export var inference_port: int = 8765
@export var decision_interval_s: float = 0.1

var _client: VisionInferenceClient
var _camera: Camera3D
var _decision_timer: float = 0.0
var _last_action: Vector2 = Vector2.ZERO # (steer_rad, engine_force)
var _connect_attempted: bool = false


func _tick(delta: float) -> int:
	var bb := get_blackboard()
	var car: VehicleBody3D = (bb.get_var("car") if bb and bb.has_var("car") else null) as VehicleBody3D
	if not car:
		return BTTask.FAILURE

	_ensure_camera(car)
	_ensure_client()

	_decision_timer += delta
	if _decision_timer >= decision_interval_s:
		_decision_timer = 0.0
		_update_action()

	car.steering = clampf(_last_action.x, -car.STEER_LIMIT, car.STEER_LIMIT)
	car.engine_force = clampf(_last_action.y, -100.0, 100.0)
	car.brake = 0.0 # Phase 1's dataset never captured brake actions -- the model has no brake output to apply. See ai/vision/README.md.

	return BTTask.RUNNING


func _ensure_camera(car: VehicleBody3D) -> void:
	if is_instance_valid(_camera):
		return
	_camera = Camera3D.new()
	_camera.fov = CAMERA_FOV
	_camera.position = CAMERA_LOCAL_POSITION
	_camera.rotation_degrees = CAMERA_LOCAL_ROTATION_DEG
	car.add_child(_camera)
	_camera.make_current()


func _ensure_client() -> void:
	if _connect_attempted:
		return
	_connect_attempted = true
	_client = VisionInferenceClient.new()
	_client.connect_to_server(inference_host, inference_port)


## Captures whatever the current camera sees (the mounted vision camera,
## once _ensure_camera has run and make_current() has taken effect -- may
## briefly still be the default chase cam on the very first call, one
## decision tick's worth of mismatched frame is a negligible cost), sends
## it to the inference server, and updates _last_action on success. On any
## failure (server not up, timeout, dropped connection), silently keeps
## the previous _last_action -- fail-soft, matches this being a real-time
## control loop where a single missed decision should not stop the car
## rather than a batch job where a failure should abort loudly.
func _update_action() -> void:
	if not is_instance_valid(_client) or not _client.is_connected_to_server():
		return

	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return
	var viewport_texture: ViewportTexture = tree.root.get_texture()
	if not viewport_texture:
		return
	var img: Image = viewport_texture.get_image()
	if not img:
		return
	img.convert(Image.FORMAT_RGB8)

	var result: Variant = _client.predict(img.get_width(), img.get_height(), img.get_data())
	if result is Vector2:
		_last_action = result
