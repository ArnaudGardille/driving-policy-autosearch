extends SceneTree
## Headless, scriptable entrypoint for scoring a driving policy candidate
## from OUTSIDE the editor -- the integration point for an external tuning
## or research loop (e.g. an autoresearch-style agent) that needs a single
## number back without opening Godot.
##
## Invoke with the real Godot binary from the command line, e.g.:
##
##   godot --headless --path <repo> --script res://tests/run_eval.gd -- \
##       --seconds=65 --vehicles=car_base,trailer_truck,tow_truck \
##       --overrides={"cross_track_gain":0.75}
##
## All flags are optional:
##   --seconds=N       racing time budget per vehicle (default 65, a few
##                      seconds past RACE_DURATION so a genuine finish near
##                      the wire isn't cut off by the benchmark itself)
##   --vehicles=a,b,c   which cars to evaluate (default: all three). Keys:
##                      car_base, trailer_truck, tow_truck
##   --overrides=JSON   JSON object of AIDriveTask exported properties to
##                      override, e.g. for a parameter sweep
##
## Prints one line of JSON as the LAST line of stdout (Godot itself prints a
## version banner before the script runs, so callers should parse the last
## non-empty stdout line, not the first) and exits 0 on success, non-zero if
## anything failed (bad args, an unknown vehicle, a script error) -- a
## non-zero exit means "do not accept this candidate", independent of
## whatever score value may or may not be present in the output.
##
## The reported "aggregate_score" is the MINIMUM score across the requested
## vehicles, not the mean: this project's fairness rule is "same car as the
## human", and a human can pick any of the three, so a policy that only
## drives well in its favorite car is not a better policy and must not be
## able to hide that behind an average.

const VEHICLE_SCENES := {
	"car_base": "res://vehicles/car_base.tscn",
	"trailer_truck": "res://vehicles/trailer_truck.tscn",
	"tow_truck": "res://vehicles/tow_truck.tscn",
}

const DEFAULT_RACING_SECONDS := 65.0


func _init() -> void:
	var args := _parse_args()
	var ok := true

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
			ok = false

	var vehicle_keys: Array = VEHICLE_SCENES.keys()
	if args.has("vehicles"):
		vehicle_keys = String(args["vehicles"]).split(",", false)

	var per_vehicle := {}
	var scores: Array[float] = []

	for key: String in vehicle_keys:
		if not VEHICLE_SCENES.has(key):
			push_error("Unknown vehicle '%s'. Valid: %s" % [key, ", ".join(VEHICLE_SCENES.keys())])
			ok = false
			continue
		var result: Dictionary = await AIBenchmark.run(
				self, racing_seconds, overrides, VEHICLE_SCENES[key])
		per_vehicle[key] = result
		scores.append(result.get("score", 0.0))
		if not result.get("fair", false):
			# A run that exceeds the human's own steering/engine-force
			# ceiling is not a legitimate result, no matter how good its
			# score looks -- fail the whole eval rather than let an unfair
			# run's score sneak into the aggregate.
			ok = false
			push_error("FAIRNESS VIOLATION on '%s': max_steering_used=%.3f (limit %.3f), max_engine_force_used=%.3f (ceiling %.3f)" % [
				key, result.get("max_steering_used", 0.0), result.get("steer_limit", 0.0),
				result.get("max_engine_force_used", 0.0), result.get("engine_force_ceiling", 0.0)])

	var mean_score := 0.0
	var min_score := 0.0
	if scores.size() > 0:
		min_score = INF
		for s: float in scores:
			mean_score += s
			min_score = minf(min_score, s)
		mean_score /= scores.size()
	else:
		ok = false

	var output := {
		"ok": ok,
		"per_vehicle": per_vehicle,
		"mean_score": mean_score,
		"aggregate_score": min_score,
	}
	print(JSON.stringify(output))
	quit(0 if ok else 1)


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
