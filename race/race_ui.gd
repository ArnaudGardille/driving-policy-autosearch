extends CanvasLayer

## Reference to the race manager, set via setup().
var _manager: Node

## UI node references.
@onready var _countdown_panel: PanelContainer = %CountdownPanel
@onready var _countdown_label: Label = %CountdownLabel
@onready var _racing_panel: Control = %RacingPanel
@onready var _timer_label: Label = %TimerLabel
@onready var _distance_label: Label = %DistanceLabel
@onready var _off_track_label: Label = %OffTrackLabel
@onready var _results_panel: PanelContainer = %ResultsPanel
@onready var _results_title: Label = %ResultsTitle
@onready var _results_distance: Label = %ResultsDistance
@onready var _results_best: Label = %ResultsBest
@onready var _results_new_best: Label = %ResultsNewBest
@onready var _results_time: Label = %ResultsTime
@onready var _results_best_time: Label = %ResultsBestTime
@onready var _results_new_best_time: Label = %ResultsNewBestTime
@onready var _results_score: Label = %ResultsScore
@onready var _results_best_score: Label = %ResultsBestScore
@onready var _results_new_best_score: Label = %ResultsNewBestScore
@onready var _restart_button: Button = %RestartButton
@onready var _menu_button: Button = %MenuButton


func setup(manager: Node) -> void:
	_manager = manager
	_restart_button.pressed.connect(_on_restart_pressed)
	_menu_button.pressed.connect(_on_menu_pressed)
	hide_all()


func hide_all() -> void:
	_countdown_panel.hide()
	_racing_panel.hide()
	_results_panel.hide()
	_off_track_label.hide()
	_results_time.hide()
	_results_best_time.hide()
	_results_new_best_time.hide()
	_results_score.hide()
	_results_best_score.hide()
	_results_new_best_score.hide()


func show_countdown_phase() -> void:
	hide_all()
	_countdown_panel.show()


func show_countdown(text: String) -> void:
	_countdown_label.text = text
	# Animate: scale up then settle.
	var tween := create_tween()
	_countdown_label.scale = Vector2(0.5, 0.5)
	_countdown_label.modulate = Color.WHITE
	tween.tween_property(_countdown_label, "scale", Vector2(1.2, 1.2), 0.15)
	tween.tween_property(_countdown_label, "scale", Vector2(1.0, 1.0), 0.35)
	if text == "GO!":
		_countdown_label.modulate = Color.GREEN_YELLOW
		# Hide countdown after a moment.
		tween.tween_interval(0.8)
		tween.tween_callback(func() -> void: _countdown_panel.hide())


func show_racing_phase() -> void:
	hide_all()
	_racing_panel.show()
	_timer_label.text = "1:00"
	_distance_label.text = "Distance: 0 m"


func update_timer(remaining: float) -> void:
	var minutes := int(remaining) / 60.0
	var seconds := int(remaining) % 60
	_timer_label.text = "%d:%02d" % [minutes, seconds]

	if remaining <= 10.0:
		_timer_label.add_theme_color_override(&"font_color", Color.RED)
		# Pulse effect in the last 10 seconds.
		_timer_label.scale = Vector2(1.0 + sin(remaining * 8.0) * 0.1, 1.0 + sin(remaining * 8.0) * 0.1)
	else:
		_timer_label.add_theme_color_override(&"font_color", Color.WHITE)
		_timer_label.scale = Vector2.ONE


func update_distance(distance: float) -> void:
	_distance_label.text = "Distance: %d m" % int(distance)


func show_off_track_warning(p_visible: bool, critical: bool) -> void:
	_off_track_label.visible = p_visible
	if p_visible and critical:
		_off_track_label.add_theme_color_override(&"font_color", Color.RED)
		_off_track_label.text = "⚠ RETURN TO TRACK! ⚠"
	else:
		_off_track_label.add_theme_color_override(&"font_color", Color.ORANGE)
		_off_track_label.text = "⚠ Stay on track!"


func show_results(distance: float, best: float, is_new_best: bool, reason: String,
		race_time: float = 0.0, best_time: float = INF, is_new_best_time: bool = false,
		score: float = 0.0, best_score: float = 0.0, is_new_best_score: bool = false) -> void:
	hide_all()
	_results_panel.show()

	match reason:
		"won":
			_results_title.text = "YOU WON!"
			_results_title.add_theme_color_override(&"font_color", Color.GREEN_YELLOW)
		"time_up":
			_results_title.text = "TIME'S UP!"
			_results_title.add_theme_color_override(&"font_color", Color.WHITE)
		"off_track":
			_results_title.text = "OFF TRACK!"
			_results_title.add_theme_color_override(&"font_color", Color.RED)
		"fell_off":
			_results_title.text = "CRASHED!"
			_results_title.add_theme_color_override(&"font_color", Color.RED)

	_results_distance.text = "Distance: %d m" % int(distance)
	_results_best.text = "Best: %d m" % int(best)
	_results_new_best.visible = is_new_best

	# Finish time is only meaningful when the track was actually completed.
	var won := reason == "won"
	_results_time.visible = won
	_results_best_time.visible = won
	_results_new_best_time.visible = won and is_new_best_time
	if won:
		_results_time.text = "Time: %s" % _format_time(race_time)
		_results_best_time.text = "Best Time: %s" % _format_time(best_time)

	# Score is meaningful for every attempt (it reflects partial progress
	# too), so it is shown regardless of the outcome.
	_results_score.show()
	_results_best_score.show()
	_results_score.text = "Score: %.3f" % score
	_results_best_score.text = "Best Score: %.3f" % best_score
	_results_new_best_score.visible = is_new_best_score

	# Animate results in.
	_results_panel.modulate = Color(1, 1, 1, 0)
	var tween := create_tween()
	tween.tween_property(_results_panel, "modulate", Color.WHITE, 0.4)


func _format_time(seconds: float) -> String:
	if not is_finite(seconds):
		return "--"
	var minutes: int = floori(seconds / 60.0)
	var secs := fmod(seconds, 60.0)
	return "%d:%05.2f" % [minutes, secs]


func hide_results() -> void:
	_results_panel.hide()


func _on_restart_pressed() -> void:
	if _manager and _manager.has_method(&"restart_race"):
		_manager.restart_race()


func _on_menu_pressed() -> void:
	if _manager and _manager.has_method(&"go_back_to_menu"):
		_manager.go_back_to_menu()
