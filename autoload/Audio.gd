extends Node
## Buses, pooled SFX, layered ambience and dynamic music.
## Music: per layer (nest/surface/house) a bed + 3 intensity stems, all 32 s loops
## started together so they stay in sync; intensity follows world danger (alarm scent, fights).

const BUSES := ["Music", "SFX", "Ambient"]
const LAYERS := ["nest", "surface", "house"]
const AMBIENT := ["rain_loop", "wind_loop", "creak_loop", "birds_loop", "house_hum_loop", "mower_loop", "sprinkler_loop", "purr_loop"]
const POOL := 12

var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_next := 0
var _sfx_last: Dictionary = {}
var _music: Dictionary = {}  # "bed_nest" -> player
var _amb: Dictionary = {}
var _menu_player: AudioStreamPlayer
var _streams: Dictionary = {}
var layer := "nest"
var intensity := 0.0
var in_game := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for b in BUSES:
		if AudioServer.get_bus_index(b) < 0:
			AudioServer.add_bus()
			var i := AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, b)
			AudioServer.set_bus_send(i, "Master")
			if b == "Music":
				var lim := AudioEffectHardLimiter.new()
				lim.ceiling_db = -1.0
				AudioServer.add_bus_effect(i, lim)
	Settings.apply_audio()
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_sfx_players.append(p)
	for l in LAYERS:
		for stem in ["bed", "intense1", "intense2", "intense3"]:
			var key := "%s_%s" % [stem, l]
			var mp := _make_loop("res://audio/music/%s.ogg" % key, "Music")
			if mp:
				_music[key] = mp
	for a in AMBIENT:
		var ap := _make_loop("res://audio/sfx/%s.ogg" % a, "Ambient")
		if ap:
			_amb[a] = ap
	_menu_player = _make_loop("res://audio/music/menu.ogg", "Music")
	Events.sfx.connect(func(n, _p, _s): play(n))
	Events.view_changed.connect(func(v): layer = v)
	Events.collapse.connect(func(_s, _p, _c): play("collapse"))
	Events.ant_hatched.connect(func(_c): play("hatch"))
	Events.trail_busy.connect(func(_p): play("chain"))
	Events.alert.connect(func(_k, _t, _p, _s): play("alert"))
	Events.telegraph.connect(func(_k, _p, _s, _sec): play("telegraph"))
	Events.trait_unlocked.connect(func(_t): play("unlock"))
	Events.toast.connect(func(_t): play("toast"))
	Events.cell_dug.connect(func(_s, _p): play("dig_%d" % (randi() % 3 + 1)))


func _stream(path: String) -> AudioStream:
	if _streams.has(path):
		return _streams[path]
	var s: AudioStream = null
	if ResourceLoader.exists(path):
		s = load(path)
	elif FileAccess.file_exists(path):
		s = AudioStreamOggVorbis.load_from_file(path)
	if s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = path.contains("_loop") or path.contains("/music/")
	_streams[path] = s
	return s


func _make_loop(path: String, bus: String) -> AudioStreamPlayer:
	var s := _stream(path)
	if s == null:
		return null
	var p := AudioStreamPlayer.new()
	p.stream = s
	p.bus = bus
	p.volume_db = -80.0
	add_child(p)
	return p


func play(name: String, volume_db: float = 0.0) -> void:
	var now := Time.get_ticks_msec()
	if now - int(_sfx_last.get(name, -1000)) < 70:
		return
	_sfx_last[name] = now
	var s := _stream("res://audio/sfx/%s.ogg" % name)
	if s == null:
		return
	var p := _sfx_players[_sfx_next]
	_sfx_next = (_sfx_next + 1) % POOL
	p.stream = s
	p.volume_db = volume_db
	p.pitch_scale = randf_range(0.94, 1.06)
	p.play()


func start_game_audio() -> void:
	in_game = true
	if _menu_player:
		_menu_player.stop()
	for p in _music.values():
		p.play()
	for p in _amb.values():
		p.play()


func start_menu_audio() -> void:
	in_game = false
	for p in _music.values():
		p.stop()
	for p in _amb.values():
		p.stop()
	if _menu_player and not _menu_player.playing:
		_menu_player.volume_db = -6.0
		_menu_player.play()


func _process(delta: float) -> void:
	if not in_game:
		return
	var w = Game.world
	var target := 0.0
	var raining := false
	var mower := false
	var sprinkler := false
	var cat_sleep := false
	if w != null:
		target = w.danger()
		raining = w.weather.rain > 0.0
		mower = w.weather.mower_active
		sprinkler = w.weather.sprinkler_active
		cat_sleep = layer == "house" and w.house_ai != null and w.house_ai.cat_sleeping
	intensity = move_toward(intensity, target, delta * 0.5)
	for key in _music.keys():
		var parts: PackedStringArray = key.split("_")
		var stem: String = parts[0]
		var l: String = parts[1]
		var vol := -80.0
		if l == layer:
			match stem:
				"bed": vol = -9.0
				"intense1": vol = _stem_db(intensity, 0.0)
				"intense2": vol = _stem_db(intensity, 1.0)
				"intense3": vol = _stem_db(intensity, 2.0)
		var p: AudioStreamPlayer = _music[key]
		p.volume_db = move_toward(p.volume_db, vol, delta * 40.0)
	_amb_to("rain_loop", -6.0 if raining and layer != "house" else -80.0, delta)
	_amb_to("wind_loop", -14.0 if layer == "surface" else -80.0, delta)
	_amb_to("birds_loop", -10.0 if layer == "surface" and not Clock.is_night() and not raining else -80.0, delta)
	_amb_to("creak_loop", -8.0 if layer == "nest" else -80.0, delta)
	_amb_to("house_hum_loop", -12.0 if layer == "house" else -80.0, delta)
	_amb_to("mower_loop", -4.0 if mower and layer == "surface" else -80.0, delta)
	_amb_to("sprinkler_loop", -6.0 if sprinkler and layer == "surface" else -80.0, delta)
	_amb_to("purr_loop", -10.0 if cat_sleep else -80.0, delta)


func _stem_db(level: float, threshold: float) -> float:
	var x := clampf(level - threshold, 0.0, 1.0)
	return -80.0 if x <= 0.01 else linear_to_db(x) - 10.0


func _amb_to(name: String, db: float, delta: float) -> void:
	if _amb.has(name):
		var p: AudioStreamPlayer = _amb[name]
		p.volume_db = move_toward(p.volume_db, db, delta * 30.0)
