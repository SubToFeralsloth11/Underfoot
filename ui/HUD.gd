class_name HUD
extends Control
## In-game HUD: clock & speed, population, stores, alerts, toolbar, objectives,
## ant inspector, tutorial hints, dialog, minimap and end-of-game panel.

const TOOLS := [
	["select", "Select", "tool_select", "Inspect ants and creatures. Click a rhino beetle to feed it."],
	["dig", "Dig", "tool_dig", "Drag to mark soil for digging. Shift-drag to unmark."],
	["chamber", "Chamber", "tool_chamber", "Drag a rectangle and assign the chamber type chosen on the right."],
	["build", "Build", "tool_build", "Place the structure chosen on the right."],
	["trail", "Trail", "tool_trail", "Paint a scent trail ants strongly prefer."],
	["erase", "Erase", "tool_erase", "Wipe scent."],
	["avoid", "Avoid", "tool_avoid", "Paint alarm scent: foragers steer away, soldiers come running."],
	["rally", "Rally", "tool_rally", "Click to send soldiers there (on a rival nest = raid). Right-click clears."],
	["satellite", "Found nest", "", "Found a satellite nest (needs a charter from a nuptial flight)."],
]

var main  # Main.gd
var top_label: Label
var pop_label: Label
var stores_box: HBoxContainer
var store_bars: Dictionary = {}
var brood_label: Label
var points_label: Label
var esc_label: Label
var speed_buttons: Array = []
var view_buttons: Dictionary = {}
var tool_buttons: Dictionary = {}
var chamber_opt: OptionButton
var build_opt: OptionButton
var objectives_box: VBoxContainer
var objectives_panel: PanelContainer
var alerts_box: VBoxContainer
var inspector: PanelContainer
var inspector_label: RichTextLabel
var inspector_actions: HBoxContainer
var hint_panel: PanelContainer
var hint_label: Label
var dialog_panel: PanelContainer
var dialog_label: RichTextLabel
var dialog_queue: Array = []
var toast_label: Label
var toast_timer := 0.0
var minimap: Minimap
var _refresh := 0.0
var _hint_timer := 0.0
var _hint_queue: Array = []
var overlay_label: Label


func _ready() -> void:
	theme = UITheme.theme()
	_fit_viewport()
	get_viewport().size_changed.connect(_fit_viewport)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_top()
	_build_toolbar()
	_build_side()
	_build_popups()
	Events.alert.connect(_on_alert)
	Events.toast.connect(_on_toast)
	Events.hint.connect(_on_hint)
	Events.dialog.connect(func(s, t): show_dialog(s, t))
	Events.discovered.connect(func(id): _on_toast("Field Guide: discovered %s!" % Data.table("creatures").get(id, {}).get("name", id)))
	Events.objective_completed.connect(func(_id): refresh_objectives())
	Events.ant_hatched.connect(func(c):
		if Game.world and Game.world.colonies[0].hatched <= 1:
			_on_toast("The first %s has hatched!" % c))


func _fit_viewport() -> void:
	# Parent is a CanvasLayer, so anchors don't resolve against the window: size explicitly.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	position = Vector2.ZERO
	size = get_viewport().get_visible_rect().size


func _build_top() -> void:
	var bar := UITheme.panel()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = 44
	add_child(bar)
	var h := UITheme.hbox(10)
	bar.add_child(h)
	top_label = UITheme.label("", 15, UITheme.AMBER)
	top_label.custom_minimum_size.x = 215
	h.add_child(top_label)
	var sp := UITheme.hbox(2)
	h.add_child(sp)
	for i in Clock.SPEEDS.size():
		var txt: String = ["||", "1x", "2x", "4x"][i]
		var b := UITheme.button(txt, func(): Clock.set_speed_index(i), "Speed ([ / ], Space pauses)")
		b.toggle_mode = true
		b.custom_minimum_size.x = 38
		sp.add_child(b)
		speed_buttons.append(b)
	pop_label = UITheme.label("")
	pop_label.custom_minimum_size.x = 90
	pop_label.mouse_filter = Control.MOUSE_FILTER_PASS
	h.add_child(pop_label)
	stores_box = UITheme.hbox(8)
	h.add_child(stores_box)
	for k in ["sugar", "protein", "seeds", "fungus", "water"]:
		var v := UITheme.vbox(0)
		var l := UITheme.label(k.capitalize(), 11, UITheme.MUTED)
		v.add_child(l)
		var pb := ProgressBar.new()
		pb.custom_minimum_size = Vector2(58, 14)
		pb.show_percentage = false
		var fill := UITheme._box({"sugar": Color("#e8c060"), "protein": Color("#d06050"), "seeds": Color("#c8a040"), "fungus": Color("#d8d0e8"), "water": UITheme.WATER}[k], Color.TRANSPARENT, 0, 3)
		pb.add_theme_stylebox_override("fill", fill)
		v.add_child(pb)
		stores_box.add_child(v)
		store_bars[k] = [pb, l]
	brood_label = UITheme.label("")
	h.add_child(brood_label)
	points_label = UITheme.label("", 15, UITheme.LEAF)
	h.add_child(points_label)
	esc_label = UITheme.label("", 15, UITheme.DANGER)
	h.add_child(esc_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(spacer)
	for v in ["nest", "surface", "house"]:
		var b := UITheme.button(v.capitalize(), func(): main.set_view(v), "Switch view (Tab)")
		b.toggle_mode = true
		h.add_child(b)
		view_buttons[v] = b
	var nn := UITheme.button("Next nest", func():
		var ev := InputEventKey.new()
		ev.physical_keycode = Settings.keys["next_nest"]
		ev.pressed = true
		main._on_key(ev), "Cycle your nests (N)")
	nn.name = "NextNest"
	h.add_child(nn)
	h.add_child(UITheme.button("Menu", func(): main.open_pause(), "Esc"))


func _build_toolbar() -> void:
	var bar := UITheme.panel()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -46
	bar.offset_right = -230
	add_child(bar)
	var h := UITheme.hbox(4)
	bar.add_child(h)
	for t in TOOLS:
		var key: String = Settings.key_name(t[2]) if t[2] != "" else ""
		var b := UITheme.button(t[1] + (" (%s)" % key if key != "" else ""), func(): main.set_tool(t[0]), t[3])
		b.toggle_mode = true
		h.add_child(b)
		tool_buttons[t[0]] = b
	chamber_opt = OptionButton.new()
	chamber_opt.focus_mode = Control.FOCUS_NONE
	for k in Data.table("chambers").keys():
		chamber_opt.add_item(Data.table("chambers")[k]["name"])
		chamber_opt.set_item_metadata(chamber_opt.item_count - 1, k)
	chamber_opt.item_selected.connect(func(i): main.chamber_type = chamber_opt.get_item_metadata(i); main.set_tool("chamber"))
	chamber_opt.tooltip_text = "Chamber type"
	h.add_child(chamber_opt)
	build_opt = OptionButton.new()
	build_opt.focus_mode = Control.FOCUS_NONE
	for k in Data.table("builds").keys():
		var d: Dictionary = Data.table("builds")[k]
		var cost := ""
		for ck in d.get("cost", {}).keys():
			if float(d["cost"][ck]) > 0:
				cost += " %d %s" % [int(d["cost"][ck]), ck]
		build_opt.add_item(d["name"] + cost)
		build_opt.set_item_metadata(build_opt.item_count - 1, k)
		build_opt.set_item_tooltip(build_opt.item_count - 1, d.get("desc", ""))
	build_opt.item_selected.connect(func(i): main.build_kind = build_opt.get_item_metadata(i); main.set_tool("build"))
	h.add_child(build_opt)
	h.add_child(VSeparator.new())
	h.add_child(UITheme.button("Scent", func(): main.toggle_overlay("scent"), "Scent overlay (P)"))
	for o in ["air", "water", "heat", "mould"]:
		var idx: int = ["air", "water", "heat", "mould"].find(o) + 1
		h.add_child(UITheme.button(o.capitalize(), func(): main.toggle_overlay(o), "Nest overlay (%d)" % idx))
	h.add_child(VSeparator.new())
	h.add_child(UITheme.button("Castes", func(): main.open_castes(), "C"))
	h.add_child(UITheme.button("Evolve", func(): main.open_evolution(), "E"))
	h.add_child(UITheme.button("Guide", func(): main.open_guide(), "G"))
	h.add_child(UITheme.button("Royals", func(): main.raise_royals(), "Raise 1 winged royal for the spring nuptial flight (60 sugar + 60 protein)"))
	h.add_child(UITheme.button("Move queen", func(): main.relocate_queen(), "Relocate the queen to a satellite nest"))
	overlay_label = UITheme.label("", 13, UITheme.MUTED)
	overlay_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	overlay_label.offset_left = 12
	overlay_label.offset_top = -76
	overlay_label.offset_bottom = -54
	add_child(overlay_label)
	minimap = Minimap.new()
	minimap.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	minimap.offset_left = -224
	minimap.offset_top = -170
	minimap.offset_right = -4
	minimap.offset_bottom = -4
	add_child(minimap)


func _build_side() -> void:
	objectives_panel = UITheme.panel(Vector2(300, 0))
	objectives_panel.position = Vector2(8, 54)
	add_child(objectives_panel)
	objectives_box = UITheme.vbox(3)
	objectives_panel.add_child(objectives_box)
	alerts_box = UITheme.vbox(4)
	alerts_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	alerts_box.offset_left = -370
	alerts_box.offset_right = -8
	alerts_box.offset_top = 54
	alerts_box.custom_minimum_size = Vector2(360, 0)
	alerts_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(alerts_box)
	inspector = UITheme.panel(Vector2(300, 0))
	inspector.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	inspector.grow_vertical = Control.GROW_DIRECTION_BEGIN
	inspector.offset_left = 8
	inspector.offset_top = -56
	inspector.offset_bottom = -56
	inspector.visible = false
	add_child(inspector)
	var iv := UITheme.vbox()
	inspector.add_child(iv)
	inspector_label = RichTextLabel.new()
	inspector_label.bbcode_enabled = true
	inspector_label.fit_content = true
	inspector_label.custom_minimum_size = Vector2(280, 0)
	inspector_label.scroll_active = false
	iv.add_child(inspector_label)
	inspector_actions = UITheme.hbox()
	iv.add_child(inspector_actions)


func _build_popups() -> void:
	hint_panel = UITheme.panel(Vector2(520, 0))
	hint_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	hint_panel.offset_left = -260
	hint_panel.offset_right = 260
	hint_panel.offset_top = 54
	hint_panel.visible = false
	add_child(hint_panel)
	var hv := UITheme.hbox()
	hint_panel.add_child(hv)
	hv.add_child(UITheme.label("TIP", 14, UITheme.LEAF))
	hint_label = UITheme.label("", 15)
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_label.custom_minimum_size = Vector2(420, 0)
	hv.add_child(hint_label)
	hv.add_child(UITheme.button("OK", func(): _hint_timer = 0.0))
	dialog_panel = UITheme.panel(Vector2(640, 0))
	dialog_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	dialog_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	dialog_panel.offset_left = -320
	dialog_panel.offset_right = 320
	dialog_panel.offset_top = -60
	dialog_panel.offset_bottom = -60
	dialog_panel.visible = false
	add_child(dialog_panel)
	var dv := UITheme.vbox()
	dialog_panel.add_child(dv)
	dialog_label = RichTextLabel.new()
	dialog_label.bbcode_enabled = true
	dialog_label.fit_content = true
	dialog_label.custom_minimum_size = Vector2(620, 40)
	dv.add_child(dialog_label)
	var cont := UITheme.button("Continue", func(): _next_dialog())
	cont.size_flags_horizontal = Control.SIZE_SHRINK_END
	dv.add_child(cont)
	toast_label = UITheme.label("", 18, UITheme.AMBER)
	toast_label.set_anchors_preset(Control.PRESET_CENTER)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.offset_left = -400
	toast_label.offset_right = 400
	toast_label.offset_top = 120
	toast_label.custom_minimum_size = Vector2(800, 0)
	toast_label.add_theme_color_override("font_outline_color", Color.BLACK)
	toast_label.add_theme_constant_override("outline_size", 6)
	add_child(toast_label)


# ---------------------------------------------------------------- live updates

func _process(delta: float) -> void:
	if Game.world == null:
		return
	_refresh -= delta
	if _refresh <= 0.0:
		_refresh = 0.25
		refresh()
	toast_timer -= delta
	toast_label.modulate.a = clampf(toast_timer, 0.0, 1.0)
	if hint_panel.visible:
		_hint_timer -= delta
		if _hint_timer <= 0.0:
			hint_panel.visible = false
	if not hint_panel.visible and _hint_queue.size() > 0:
		var id: String = _hint_queue.pop_front()
		hint_label.text = Data.table("hints").get(id, id)
		hint_panel.visible = true
		_hint_timer = 12.0
	for c in alerts_box.get_children():
		var t: float = c.get_meta("t", 0.0) - delta
		c.set_meta("t", t)
		c.modulate.a = clampf(t / 2.0, 0.0, 1.0)
		if t <= 0.0:
			c.queue_free()


func refresh() -> void:
	var w = Game.world
	var col: Colony = w.colonies[0]
	top_label.text = Clock.label() + ("  (night)" if Clock.is_night() else "")
	for i in speed_buttons.size():
		speed_buttons[i].button_pressed = Clock.speed_index() == i if Clock.running or i == 0 else false
	if not Clock.running:
		speed_buttons[0].button_pressed = true
	var parts: PackedStringArray = []
	var total := 0
	for c in w.player_colonies():
		total += c.population()
	for i in col.caste_names.size():
		var n := 0
		for c in w.player_colonies():
			n += c.counts[i]
		if n > 0 and col.caste_names[i] != "queen":
			parts.append("%s %d" % [col.caste_names[i].substr(0, 3).capitalize(), n])
	pop_label.text = "Ants %d" % total
	pop_label.tooltip_text = ", ".join(parts)
	var cap := col.capacity(w.nests[col.nest])
	for k in store_bars.keys():
		var pb: ProgressBar = store_bars[k][0]
		var l: Label = store_bars[k][1]
		var v: float = col.stores.get(k, 0.0)
		pb.max_value = col.water_capacity(w.nests[col.nest]) if k == "water" else cap
		pb.value = v
		l.text = "%s %d" % [k.capitalize(), int(v)]
		pb.tooltip_text = "%d / %d" % [int(v), int(pb.max_value)]
	var b := col.brood_counts()
	brood_label.text = "Brood %d/%d/%d" % [b.x, b.y, b.z]
	brood_label.tooltip_text = "Eggs / larvae / pupae. Royals waiting: %d" % col.royals
	points_label.text = ("Traits %d" % col.trait_points) if w.flags.get("evolution", false) else ""
	if col.charters > 0:
		points_label.text += "  Charters %d" % col.charters
	esc_label.text = ("House alert %d/5" % w.house_ai.level) if w.house_ai and w.house_ai.level > 0 else ""
	view_buttons["house"].visible = w.house != null
	var nnb := find_child("NextNest", true, false)
	if nnb:
		nnb.visible = w.player_colonies().size() > 1
	for v in view_buttons.keys():
		view_buttons[v].button_pressed = main.view == v
	for t in tool_buttons.keys():
		tool_buttons[t].button_pressed = main.tool == t
	var surf_ok: bool = w.flags.get("surface", false)
	for t in ["trail", "erase", "avoid", "rally"]:
		tool_buttons[t].disabled = not surf_ok
	tool_buttons["satellite"].disabled = not w.flags.get("satellites", false)
	overlay_label.text = main.overlay_text()
	refresh_objectives()
	refresh_inspector()


func refresh_objectives() -> void:
	var w = Game.world
	for c in objectives_box.get_children():
		c.queue_free()
	if w.campaign.active():
		objectives_box.add_child(UITheme.label(w.campaign.chapter.get("title", ""), 17, UITheme.AMBER))
		for o in w.campaign.objectives():
			var p: Vector2 = w.campaign.progress(o)
			var done: bool = w.campaign.done.has(o["id"])
			var txt := "%s %s" % ["[x]" if done else "[ ]", o.get("text", o["id"])]
			if not done and p.y > 1:
				txt += "  (%d/%d)" % [mini(int(p.x), int(p.y)), int(p.y)]
			var l := UITheme.label(txt, 14, UITheme.LEAF if done else UITheme.TEXT)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 280
			objectives_box.add_child(l)
	else:
		var mode: String = w.mode.capitalize()
		objectives_box.add_child(UITheme.label(mode + (" - year %d" % Clock.year() if w.mode == "endless" else ""), 16, UITheme.AMBER))
		objectives_box.add_child(UITheme.label(w.surface.yard_name, 13, UITheme.MUTED))
	var ups: Array = w.weather.upcoming()
	for e in ups:
		if e["warned"]:
			objectives_box.add_child(UITheme.label("! %s in %ds" % [String(e["kind"]).capitalize(), int(e["in_seconds"])], 14, UITheme.DANGER))
	if w.rally_active(1):
		objectives_box.add_child(UITheme.label("! Red ant raid in progress", 14, UITheme.DANGER))
	if w.house_ai and w.house_ai.ext_phase in ["warn", "fog", "trace", "dig"]:
		objectives_box.add_child(UITheme.label("EXTERMINATOR: %s (%ds)" % [w.house_ai.ext_phase.to_upper(), int(w.house_ai.ext_timer)], 15, UITheme.DANGER))


func refresh_inspector() -> void:
	var w = Game.world
	for c in inspector_actions.get_children():
		c.queue_free()
	if main.selected_ant >= 0 and w.ants.is_alive(main.selected_ant):
		var info: Dictionary = w.ants.info(main.selected_ant)
		inspector.visible = true
		inspector_label.text = "[b][color=#f0a830]%s[/color][/b]  (%s)\n%s - %s\nCarrying: %s\nHP %d/%d   Age %.1f days\n%s" % [
			info["caste"].capitalize(), info["colony"], info["job"], info["state"],
			("%s x%.1f" % [info["carry"], info["carry_amt"]]) if info["carry"] != "" else "nothing",
			int(info["hp"]), int(info["max_hp"]), info["age_days"], info["layer"]]
		inspector_actions.add_child(UITheme.button("Follow (F)" if not main.follow else "Stop following", func(): main.follow = not main.follow))
	elif main.selected_creature >= 0 and w.creatures.exists(main.selected_creature):
		var cr: Dictionary = w.creatures.get_c(main.selected_creature)
		var d: Dictionary = w.creatures.defs[cr["kind"]]
		inspector.visible = true
		inspector_label.text = "[b][color=#f0a830]%s[/color][/b]  [i]%s[/i]\nHP %d/%d   %s\n%s" % [d.get("name", cr["kind"]), d.get("latin", ""), int(cr["hp"]), int(cr["max_hp"]), cr["state"], d.get("guide", "")]
		if cr["behaviour"] == "mount" and not cr["tame"]:
			inspector_actions.add_child(UITheme.button("Feed 20 sugar (%d/3)" % cr["fed"], func(): _on_toast(w.feed_mount(cr["id"]))))
	else:
		inspector.visible = false


# ---------------------------------------------------------------- messages

func _on_alert(kind: String, text: String, pos: Vector2, space: int) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.custom_minimum_size = Vector2(360, 0)
	var col := UITheme.DANGER if kind in ["raid", "mower", "bird", "collapse", "starving", "exterminator", "flood", "air", "queen", "bait"] else (UITheme.LEAF if kind in ["victory", "flight", "satellite", "house"] else UITheme.AMBER)
	b.add_theme_color_override("font_color", col)
	b.set_meta("t", 12.0)
	b.pressed.connect(func(): main.jump_to(pos, space))
	alerts_box.add_child(b)
	alerts_box.move_child(b, 0)
	while alerts_box.get_child_count() > 6:
		alerts_box.get_child(alerts_box.get_child_count() - 1).free()


func _on_toast(text: String) -> void:
	if text == "":
		return
	toast_label.text = text
	toast_timer = 3.5


func _on_hint(id: String) -> void:
	if id == "" or not Data.table("hints").has(id):
		return
	if Profile.take_hint(id):
		_hint_queue.append(id)


func show_dialog(speaker: String, text: String) -> void:
	dialog_queue.append([speaker, text])
	if not dialog_panel.visible:
		_next_dialog()


func _next_dialog() -> void:
	if dialog_queue.is_empty():
		dialog_panel.visible = false
		return
	var d: Array = dialog_queue.pop_front()
	dialog_label.text = ("[b][color=#7fb046]%s:[/color][/b] " % d[0] if d[0] != "" else "") + d[1]
	dialog_panel.visible = true


func show_game_over(won: bool, reason: String) -> void:
	var m := UITheme.modal(self, "Victory!" if won else "The colony has fallen", Vector2(520, 300))
	var v: VBoxContainer = m[1]
	var l := UITheme.label(reason, 16)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 480
	v.add_child(l)
	var w = Game.world
	var col: Colony = w.colonies[0]
	v.add_child(UITheme.label("Survived to %s. Hatched %d ants. Kills: %s" % [Clock.label(), col.hatched, str(col.kills)], 13, UITheme.MUTED))
	var h := UITheme.hbox()
	v.add_child(h)
	h.add_child(UITheme.button("Try again", func(): Game.restart()))
	h.add_child(UITheme.button("Main menu", func(): Game.to_menu()))


func show_chapter_complete(chapter: Dictionary) -> void:
	var m := UITheme.modal(self, "Chapter complete: %s" % chapter.get("title", ""), Vector2(620, 380))
	var v: VBoxContainer = m[1]
	for line in chapter.get("outro", []):
		var l := UITheme.label(line, 15)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 580
		v.add_child(l)
	var h := UITheme.hbox()
	v.add_child(h)
	var nxt: String = chapter.get("next", "")
	if nxt != "":
		h.add_child(UITheme.button("Next chapter", func(): Game.next_chapter(nxt)))
	else:
		h.add_child(UITheme.label("The campaign is complete. The house is yours.", 15, UITheme.LEAF))
	h.add_child(UITheme.button("Keep playing", func(): m[0].queue_free()))
	h.add_child(UITheme.button("Main menu", func(): Game.to_menu()))
