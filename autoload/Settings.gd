extends Node
## Player settings + input map. Persisted to user://settings.cfg.

const PATH := "user://settings.cfg"

const DEFAULT_KEYS := {
	"toggle_view": KEY_TAB,
	"overlay_scent": KEY_P,
	"overlay_air": KEY_1,
	"overlay_water": KEY_2,
	"overlay_heat": KEY_3,
	"overlay_mould": KEY_4,
	"follow": KEY_F,
	"pause": KEY_SPACE,
	"speed_up": KEY_BRACKETRIGHT,
	"speed_down": KEY_BRACKETLEFT,
	"evolution": KEY_E,
	"guide": KEY_G,
	"castes": KEY_C,
	"menu": KEY_ESCAPE,
	"next_nest": KEY_N,
	"tool_select": KEY_Q,
	"tool_dig": KEY_W,
	"tool_chamber": KEY_R,
	"tool_trail": KEY_T,
	"tool_erase": KEY_Y,
	"tool_avoid": KEY_H,
	"tool_build": KEY_B,
	"tool_rally": KEY_K,
	"pan_left": KEY_LEFT,
	"pan_right": KEY_RIGHT,
	"pan_up": KEY_UP,
	"pan_down": KEY_DOWN,
	"quicksave": KEY_F5,
	"quickload": KEY_F9,
}

const RESOLUTIONS := [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440)]

var resolution := Vector2i(1280, 720)
var fullscreen := false
var ui_scale := 1.0
var palette := "default"  # default | colorblind
var default_speed := 1.0
var volumes := {"Master": 0.8, "Music": 0.6, "SFX": 0.8, "Ambient": 0.6}
var keys: Dictionary = {}
var difficulty := "normal"

signal changed


func _ready() -> void:
	keys = DEFAULT_KEYS.duplicate()
	load_settings()
	apply_input()


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	resolution = cfg.get_value("video", "resolution", resolution)
	fullscreen = cfg.get_value("video", "fullscreen", fullscreen)
	ui_scale = cfg.get_value("video", "ui_scale", ui_scale)
	palette = cfg.get_value("video", "palette", palette)
	default_speed = cfg.get_value("game", "speed", default_speed)
	difficulty = cfg.get_value("game", "difficulty", difficulty)
	for bus in volumes.keys():
		volumes[bus] = cfg.get_value("audio", bus, volumes[bus])
	for action in DEFAULT_KEYS.keys():
		keys[action] = cfg.get_value("keys", action, keys[action])


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("video", "resolution", resolution)
	cfg.set_value("video", "fullscreen", fullscreen)
	cfg.set_value("video", "ui_scale", ui_scale)
	cfg.set_value("video", "palette", palette)
	cfg.set_value("game", "speed", default_speed)
	cfg.set_value("game", "difficulty", difficulty)
	for bus in volumes.keys():
		cfg.set_value("audio", bus, volumes[bus])
	for action in keys.keys():
		cfg.set_value("keys", action, keys[action])
	cfg.save(PATH)


func apply_input() -> void:
	for action in keys.keys():
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		var ev := InputEventKey.new()
		ev.physical_keycode = keys[action]
		InputMap.action_add_event(action, ev)


func rebind(action: String, keycode: int) -> void:
	keys[action] = keycode
	apply_input()
	save_settings()
	changed.emit()


func key_name(action: String) -> String:
	return OS.get_keycode_string(keys.get(action, 0))


func apply_video() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(resolution)
	get_tree().root.content_scale_factor = ui_scale


func apply_audio() -> void:
	for bus in volumes.keys():
		var idx := AudioServer.get_bus_index(bus)
		if idx >= 0:
			AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(volumes[bus], 0.0001)))


## Scent overlay colours per channel (FOOD, HOME, ALARM, EXPLORE, PLAYER).
func scent_colors() -> Array:
	if palette == "colorblind":
		# Okabe-Ito: distinguishable for protan/deutan/tritan.
		return [Color("#009e73"), Color("#0072b2"), Color("#d55e00"), Color("#cc79a7"), Color("#f0e442")]
	return [Color("#4cd964"), Color("#4a90e2"), Color("#ff3b30"), Color("#b36bff"), Color("#ffd23f")]
