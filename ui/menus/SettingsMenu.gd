class_name SettingsMenu
extends RefCounted
## Settings: video, accessibility, sim speed, audio buses and key rebinding.


static func open(parent: Control) -> Control:
	var m := UITheme.modal(parent, "Settings", Vector2(760, 620))
	var root: Control = m[0]
	var v: VBoxContainer = m[1]
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(740, 540)
	v.add_child(tabs)
	# --- Video
	var video := UITheme.vbox(8)
	video.name = "Video"
	tabs.add_child(video)
	var res := OptionButton.new()
	for r in Settings.RESOLUTIONS:
		res.add_item("%d x %d" % [r.x, r.y])
	res.selected = maxi(Settings.RESOLUTIONS.find(Settings.resolution), 0)
	res.item_selected.connect(func(i):
		Settings.resolution = Settings.RESOLUTIONS[i]
		Settings.apply_video()
		Settings.save_settings())
	video.add_child(_row("Resolution", res))
	var fs := CheckBox.new()
	fs.button_pressed = Settings.fullscreen
	fs.toggled.connect(func(on):
		Settings.fullscreen = on
		Settings.apply_video()
		Settings.save_settings())
	video.add_child(_row("Fullscreen", fs))
	var ui := HSlider.new()
	ui.min_value = 0.75
	ui.max_value = 2.0
	ui.step = 0.05
	ui.value = Settings.ui_scale
	ui.custom_minimum_size.x = 260
	ui.value_changed.connect(func(val):
		Settings.ui_scale = val
		Settings.apply_video()
		Settings.save_settings())
	video.add_child(_row("UI scale", ui))
	var pal := OptionButton.new()
	pal.add_item("Default scent colours")
	pal.add_item("Colour-blind safe (Okabe-Ito)")
	pal.selected = 1 if Settings.palette == "colorblind" else 0
	pal.item_selected.connect(func(i):
		Settings.palette = "colorblind" if i == 1 else "default"
		Settings.save_settings())
	video.add_child(_row("Scent palette", pal))
	# --- Game
	var game := UITheme.vbox(8)
	game.name = "Game"
	tabs.add_child(game)
	var spd := OptionButton.new()
	for s in ["1x", "2x", "4x"]:
		spd.add_item(s)
	spd.selected = maxi([1.0, 2.0, 4.0].find(Settings.default_speed), 0)
	spd.item_selected.connect(func(i):
		Settings.default_speed = [1.0, 2.0, 4.0][i]
		Settings.save_settings())
	game.add_child(_row("Default sim speed", spd))
	var diff := OptionButton.new()
	for d in ["easy", "normal", "hard"]:
		diff.add_item(d.capitalize())
	diff.selected = maxi(["easy", "normal", "hard"].find(Settings.difficulty), 0)
	diff.item_selected.connect(func(i):
		Settings.difficulty = ["easy", "normal", "hard"][i]
		Settings.save_settings())
	game.add_child(_row("Difficulty (new games)", diff))
	game.add_child(UITheme.button("Show tutorial hints again", func():
		Profile.reset_hints()
		Events.toast.emit("Hints reset.")))
	# --- Audio
	var audio := UITheme.vbox(8)
	audio.name = "Audio"
	tabs.add_child(audio)
	for bus in Settings.volumes.keys():
		var s := HSlider.new()
		s.min_value = 0.0
		s.max_value = 1.0
		s.step = 0.01
		s.value = Settings.volumes[bus]
		s.custom_minimum_size.x = 300
		s.value_changed.connect(func(val):
			Settings.volumes[bus] = val
			Settings.apply_audio()
			Settings.save_settings())
		audio.add_child(_row(bus, s))
	# --- Keys
	var keys_scroll := ScrollContainer.new()
	keys_scroll.name = "Keys"
	tabs.add_child(keys_scroll)
	var kv := GridContainer.new()
	kv.columns = 2
	keys_scroll.add_child(kv)
	for action in Settings.DEFAULT_KEYS.keys():
		kv.add_child(UITheme.label(action.replace("_", " ").capitalize(), 14))
		var b := Button.new()
		b.text = Settings.key_name(action)
		b.custom_minimum_size.x = 160
		b.focus_mode = Control.FOCUS_ALL
		b.pressed.connect(func():
			b.text = "press a key..."
			b.grab_focus()
			b.set_meta("listening", true))
		b.gui_input.connect(func(e):
			if b.get_meta("listening", false) and e is InputEventKey and e.pressed:
				Settings.rebind(action, e.physical_keycode)
				b.text = Settings.key_name(action)
				b.set_meta("listening", false)
				b.accept_event())
		kv.add_child(b)
	return root


static func _row(label_text: String, control: Control) -> HBoxContainer:
	var h := UITheme.hbox(12)
	var l := UITheme.label(label_text)
	l.custom_minimum_size.x = 220
	h.add_child(l)
	h.add_child(control)
	return h
