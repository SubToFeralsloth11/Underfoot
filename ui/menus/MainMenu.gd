extends Control
## Title screen: campaign chapters, sandbox, endless yard, load, field guide, settings.

var _ants: Array = []  # [pos, heading, speed]
var _atlas: Texture2D


func _ready() -> void:
	theme = UITheme.theme()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	Settings.apply_video()
	Audio.start_menu_audio()
	_atlas = ArtGen.ant_atlas()
	# Release QA: `-- --autostart=sandbox --speed=4 --soak-seconds=600` starts a game directly.
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--autostart="):
			var opts := {"seed": 1234, "workers": 200, "soldiers": 30, "scouts": 15, "nurses": 20}
			for b in OS.get_cmdline_user_args():
				if b.begins_with("--speed="):
					Settings.default_speed = float(b.get_slice("=", 1))
				if b.begins_with("--soak-seconds="):
					Game.soak_seconds = float(b.get_slice("=", 1))
			Game.new_game.call_deferred(a.get_slice("=", 1), opts)
			return
	for i in 60:
		_ants.append([Vector2(randf() * 1280, randf() * 720), randf() * TAU, randf_range(30, 70)])
	var v := UITheme.vbox(10)
	v.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	v.position = Vector2(80, -260)
	add_child(v)
	var title := UITheme.label("UNDERFOOT", 72, UITheme.AMBER)
	title.add_theme_color_override("font_outline_color", Color("#1e1610"))
	title.add_theme_constant_override("outline_size", 10)
	v.add_child(title)
	v.add_child(UITheme.label("One ant. One backyard. One day, the whole house.", 18, UITheme.TEXT))
	v.add_child(Control.new())
	for item in [["Campaign", _campaign], ["Sandbox", _sandbox], ["Endless Yard", _endless], ["Load game", _load], ["Field Guide", func(): FieldGuide.open(self)], ["Settings", func(): SettingsMenu.open(self)], ["Quit", func(): get_tree().quit()]]:
		var b := UITheme.button(item[0], item[1])
		b.custom_minimum_size = Vector2(260, 42)
		b.add_theme_font_size_override("font_size", 20)
		v.add_child(b)
	var ver := UITheme.label("v%s" % ProjectSettings.get_setting("application/config/version", "1.0.0"), 12, UITheme.MUTED)
	ver.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.position = Vector2(-80, -30)
	add_child(ver)


func _process(delta: float) -> void:
	var sz := size
	for a in _ants:
		a[1] += randf_range(-1.5, 1.5) * delta
		a[0] += Vector2(cos(a[1]), sin(a[1])) * a[2] * delta
		if a[0].x < -20: a[0].x = sz.x + 20
		if a[0].x > sz.x + 20: a[0].x = -20
		if a[0].y < -20: a[0].y = sz.y + 20
		if a[0].y > sz.y + 20: a[0].y = -20
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#3d2a1a"))
	for k in 30:
		var y := size.y * (0.55 + k * 0.02)
		draw_rect(Rect2(0, y, size.x, size.y * 0.02), Color("#3d2a1a").darkened(0.03 * k))
	draw_rect(Rect2(0, 0, size.x, size.y * 0.55), Color("#4f7a2c").darkened(0.35))
	var frame := int(Time.get_ticks_msec() / 100) % 2
	for a in _ants:
		draw_set_transform(a[0], a[1], Vector2(1.6, 1.6))
		draw_texture_rect_region(_atlas, Rect2(-8, -8, 16, 16), Rect2(frame * 16, 0, 16, 16), Color("#1a0f08"))
	draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)


func _campaign() -> void:
	var m := UITheme.modal(self, "Campaign", Vector2(640, 460))
	var v: VBoxContainer = m[1]
	for i in range(1, 6):
		var id := "chapter_%d" % i
		if OS.has_feature("demo") and i > 2:
			v.add_child(UITheme.label("%d. Full game only" % i, 15, UITheme.MUTED))
			continue
		var ch: Dictionary = Data.campaign.get(id, {})
		if ch.is_empty():
			continue
		var unlocked := Profile.chapter_unlocked(id)
		var done := Profile.chapters_done.has(id)
		var b := UITheme.button("%d. %s%s" % [i, ch.get("title", id), "   (complete)" if done else ""], func(): Game.new_game("campaign", {"chapter": id, "difficulty": Settings.difficulty}))
		b.disabled = not unlocked
		b.custom_minimum_size = Vector2(600, 48)
		b.tooltip_text = " ".join(PackedStringArray(ch.get("intro", [])))
		v.add_child(b)
	v.add_child(UITheme.label("Difficulty: %s (change in Settings)" % Settings.difficulty.capitalize(), 13, UITheme.MUTED))


func _sandbox() -> void:
	var m := UITheme.modal(self, "Sandbox", Vector2(560, 560))
	var v: VBoxContainer = m[1]
	var opts := {"workers": 40, "soldiers": 8, "scouts": 6, "nurses": 6, "trait_points": 10, "seed": randi() % 100000, "flags": {"rival": true, "house": true, "creatures": true, "weather": true, "seasons": true}, "difficulty": Settings.difficulty}
	for k in ["workers", "soldiers", "scouts", "nurses", "trait_points"]:
		var s := HSlider.new()
		s.min_value = 0
		s.max_value = 400 if k == "workers" else 80
		s.value = opts[k]
		s.custom_minimum_size.x = 260
		var l := UITheme.label("%s: %d" % [k.capitalize(), opts[k]])
		l.custom_minimum_size.x = 200
		s.value_changed.connect(func(val):
			opts[k] = int(val)
			l.text = "%s: %d" % [k.capitalize(), int(val)])
		var h := UITheme.hbox()
		h.add_child(l)
		h.add_child(s)
		v.add_child(h)
	for f in ["rival", "house", "creatures", "weather", "seasons"]:
		var c := CheckBox.new()
		c.text = {"rival": "Rival colony", "house": "The house", "creatures": "Threats & critters", "weather": "Weather & mower", "seasons": "Seasons (winter closes the surface)"}[f]
		c.button_pressed = true
		c.toggled.connect(func(on): opts["flags"][f] = on)
		v.add_child(c)
	var diff := OptionButton.new()
	for d in ["easy", "normal", "hard"]:
		diff.add_item("Threats: " + d)
	diff.selected = ["easy", "normal", "hard"].find(Settings.difficulty)
	diff.item_selected.connect(func(i): opts["difficulty"] = ["easy", "normal", "hard"][i])
	v.add_child(diff)
	var yard := OptionButton.new()
	for y in ["yard_01", "yard_02", "house_01"]:
		yard.add_item(Data.campaign.get(y, {}).get("name", y))
	yard.item_selected.connect(func(i): opts["yard"] = ["yard_01", "yard_02", "house_01"][i])
	v.add_child(yard)
	v.add_child(UITheme.button("Start sandbox", func(): Game.new_game("sandbox", opts)))


func _endless() -> void:
	var m := UITheme.modal(self, "Endless Yard", Vector2(520, 480))
	var v: VBoxContainer = m[1]
	var info := UITheme.label("A procedurally generated yard. Every year is harder. How long can your colony last?", 14, UITheme.MUTED)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size.x = 480
	v.add_child(info)
	var h := UITheme.hbox()
	h.add_child(UITheme.label("Seed"))
	var seed_edit := LineEdit.new()
	seed_edit.text = str(randi() % 1000000)
	seed_edit.custom_minimum_size.x = 160
	h.add_child(seed_edit)
	v.add_child(h)
	v.add_child(UITheme.button("Start", func(): Game.new_game("endless", {"seed": int(seed_edit.text), "difficulty": Settings.difficulty})))
	v.add_child(UITheme.label("Best runs", 18, UITheme.AMBER))
	var lb := Game.leaderboard()
	if lb.is_empty():
		v.add_child(UITheme.label("No runs yet.", 13, UITheme.MUTED))
	for e in lb:
		v.add_child(UITheme.label("%d years   seed %d   %d ants   %s" % [int(e["years"]), int(e["seed"]), int(e.get("population", 0)), e.get("date", "")], 14))


func _load() -> void:
	var m := UITheme.modal(self, "Load game", Vector2(520, 340))
	var v: VBoxContainer = m[1]
	for slot in ["auto", "quick", "1", "2", "3"]:
		var meta := Save.slot_meta(slot)
		var b := UITheme.button("%s: %s" % [slot.capitalize(), ("%s  (%s, %d ants)" % [meta.get("label", ""), meta.get("mode", ""), int(meta.get("population", 0))]) if not meta.is_empty() else "empty"], func(): Save.load_game(slot))
		b.disabled = meta.is_empty()
		v.add_child(b)
