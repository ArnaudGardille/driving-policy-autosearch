extends SceneTree
## On-demand visual diagnostic tool: runs ONE vehicle with real rendering and
## saves screenshots at key moments (start, periodic checkpoints, agent-pushed
## debug events, the fall moment, the finish moment). Separate from
## run_eval.gd on purpose -- the main scoring loop stays headless/fast and
## runs hundreds of times per session; this is for when a specific vehicle's
## failure mode isn't clear from the aggregate numbers alone and it's worth
## actually looking at what happened.
##
## REQUIRES REAL RENDERING -- do NOT run this with --headless (its "dummy"
## rendering driver never produces actual pixels, so every screenshot would
## silently come back empty). Needs a display server (X11/Wayland) and a
## working rendering driver:
##
##   godot --display-driver x11 --rendering-driver vulkan --path <repo> \
##       --script res://tests/capture_run.gd -- \
##       --vehicle=tow_truck --dir=runs/<hash>/tow_truck_capture \
##       [--seconds=65] [--overrides={"cross_track_gain":0.75}]
##       [--interval=15] [--max-shots=12] [--window-size=640x360]
##
## A window will briefly appear on screen for the duration of the run (this
## machine has an active desktop session; there is no true headless-with-
## rendering mode available here -- see PROGRAM.md for why). --window-size
## also controls the screenshot resolution; keep it modest to keep PNGs
## small if you're going to commit them.
##
## Prints the same per-vehicle result Dictionary run_eval.gd would produce
## for this vehicle (score, fair, trace, events, etc.) as the LAST line of
## stdout, PLUS a "screenshots" list of saved PNG paths, and also writes
## that same JSON to <dir>/manifest.json so the screenshot paths don't have
## to be parsed back out of stdout.

const VEHICLE_SCENES := {
	"car_base": "res://vehicles/car_base.tscn",
	"trailer_truck": "res://vehicles/trailer_truck.tscn",
	"tow_truck": "res://vehicles/tow_truck.tscn",
}

const DEFAULT_RACING_SECONDS := 65.0
const DEFAULT_INTERVAL_S := 15.0
const DEFAULT_MAX_SHOTS := 12


func _init() -> void:
	var args := _parse_args()

	var vehicle_key: String = String(args.get("vehicle", "car_base"))
	if not VEHICLE_SCENES.has(vehicle_key):
		push_error("Unknown vehicle '%s'. Valid: %s" % [vehicle_key, ", ".join(VEHICLE_SCENES.keys())])
		quit(1)
		return

	var dir: String = String(args.get("dir", ""))
	if dir == "":
		push_error("--dir=<output directory> is required (where screenshots + manifest.json go).")
		quit(1)
		return

	var racing_seconds: float = DEFAULT_RACING_SECONDS
	if args.has("seconds"):
		racing_seconds = String(args["seconds"]).to_float()

	var overrides := {}
	if args.has("overrides"):
		var parsed: Variant = JSON.parse_string(String(args["overrides"]))
		if parsed is Dictionary:
			overrides = parsed
		else:
			push_error("--overrides must be a JSON object, got: %s" % args["overrides"])
			quit(1)
			return

	var interval_s: float = DEFAULT_INTERVAL_S
	if args.has("interval"):
		interval_s = String(args["interval"]).to_float()

	var max_shots: int = DEFAULT_MAX_SHOTS
	if args.has("max-shots"):
		max_shots = String(args["max-shots"]).to_int()

	var capture := {
		"enabled": true,
		"dir": ProjectSettings.globalize_path(dir) if dir.begins_with("res://") else dir,
		"interval_s": interval_s,
		"max_shots": max_shots,
	}

	var result: Dictionary = await AIBenchmark.run(
			self, racing_seconds, overrides, VEHICLE_SCENES[vehicle_key], capture)

	if result.get("screenshots", []).is_empty():
		push_warning("No screenshots were saved. Did you forget to drop --headless " +
				"and pass --display-driver x11 --rendering-driver vulkan (or similar)?")

	var dir_abs: String = capture["dir"]
	DirAccess.make_dir_recursive_absolute(dir_abs)
	var manifest_path: String = dir_abs.path_join("manifest.json")
	var f := FileAccess.open(manifest_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(result, "  "))
		f.close()

	print(JSON.stringify(result))
	quit(0 if result.get("fair", false) else 1)


func _parse_args() -> Dictionary:
	var result := {}
	for raw: String in OS.get_cmdline_user_args():
		var s := raw
		if s.begins_with("--"):
			s = s.substr(2)
		var eq := s.find("=")
		if eq == -1:
			result[s] = true
		else:
			result[s.substr(0, eq)] = s.substr(eq + 1)
	return result
