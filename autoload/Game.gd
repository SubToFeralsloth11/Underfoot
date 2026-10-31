extends Node
## Top-level state machine: menu -> playing <-> paused -> over.

enum State { MENU, PLAYING, PAUSED, OVER }

const MAIN_SCENE := "res://Main.tscn"
const MENU_SCENE := "res://ui/menus/MainMenu.tscn"
const LEADERBOARD := "user://leaderboard.json"

var state: State = State.MENU
var world: World = null
var last_options: Dictionary = {}
var result_won := false
var result_reason := ""
## Release soak test: quit after this many real seconds of play (0 = off).
var soak_seconds := 0.0
var _soak_time := 0.0
var _soak_worst_ms := 0.0


func _ready() -> void:
	Events.game_over.connect(_on_game_over)


## mode: campaign | sandbox | endless. opts: chapter, seed, difficulty, sandbox sliders.
func new_game(mode: String, opts: Dictionary = {}) -> void:
	last_options = opts.duplicate()
	last_options["mode"] = mode
	world = World.new()
	world.setup(mode, opts)
	_enter_play()


func load_world(w: World) -> void:
	world = w
	_enter_play()


func _enter_play() -> void:
	state = State.PLAYING
	Clock.speed = Settings.default_speed
	Clock.running = true
	if is_inside_tree() and get_tree().current_scene != null and get_tree().current_scene.scene_file_path == MAIN_SCENE:
		get_tree().reload_current_scene()
	else:
		get_tree().change_scene_to_file(MAIN_SCENE)


func set_paused(p: bool) -> void:
	if state == State.OVER or state == State.MENU:
		return
	state = State.PAUSED if p else State.PLAYING
	Clock.running = not p


func toggle_pause() -> void:
	set_paused(state == State.PLAYING)


func to_menu() -> void:
	Clock.running = false
	state = State.MENU
	world = null
	get_tree().change_scene_to_file(MENU_SCENE)


func restart() -> void:
	new_game(last_options.get("mode", "sandbox"), last_options)


func next_chapter(chapter_id: String) -> void:
	var opts := last_options.duplicate()
	opts["chapter"] = chapter_id
	new_game("campaign", opts)


func _on_game_over(won: bool, reason: String) -> void:
	if state == State.OVER:
		return
	state = State.OVER
	Clock.running = false
	result_won = won
	result_reason = reason
	if world != null and world.mode == "endless":
		record_leaderboard(world.seed, Clock.year() - 1 + (1 if won else 0), world.colony_population())
	Audio.play("victory" if won else "defeat")


func _process(delta: float) -> void:
	if soak_seconds <= 0.0 or world == null:
		return
	_soak_time += delta
	_soak_worst_ms = maxf(_soak_worst_ms, Clock.last_step_ms)
	if _soak_time >= soak_seconds or state == State.OVER:
		print("SOAK done: %.0f s real, %d ticks (%s), ants %d, worst tick %.1f ms, state %s" % [_soak_time, Clock.tick, Clock.label(), world.ants.alive, _soak_worst_ms, State.keys()[state]])
		get_tree().quit(0)


func leaderboard() -> Array:
	if not FileAccess.file_exists(LEADERBOARD):
		return []
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(LEADERBOARD))
	return v if v is Array else []


func record_leaderboard(seed_value: int, years: int, population: int) -> void:
	var lb := leaderboard()
	lb.append({"seed": seed_value, "years": years, "population": population, "date": Time.get_date_string_from_system()})
	lb.sort_custom(func(a, b): return a["years"] > b["years"] or (a["years"] == b["years"] and a["population"] > b["population"]))
	lb = lb.slice(0, 10)
	var f := FileAccess.open(LEADERBOARD, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(lb, "  "))
