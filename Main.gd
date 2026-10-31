extends Node2D
## Game scene: owns the three views, the HUD, tools and input.
## Tab cycles Nest -> Surface -> House; every view keeps simulating.

const ZOOM_MIN := {"nest": 0.25, "surface": 0.05, "house": 0.12}
const ZOOM_MAX := {"nest": 14.0, "surface": 12.0, "house": 4.0}

var nest_view: NestView
var surface_view: SurfaceView
var house_view: HouseView
var hud: HUD
var modulator: CanvasModulate
var rain_fx: RainFX
var view := "nest"
var tool := "select"
var chamber_type := "nursery"
var build_kind := "vent"
var selected_ant := -1
var selected_creature := -1
var follow := false
var nest_index := 0
var _drag_from := Vector2i(-1, -1)
var _painting := false
var _panning := false
var _pan_last := Vector2.ZERO
var _pause_menu: Control


func _ready() -> void:
	var w := Game.world
	if w == null:
		Game.new_game("sandbox", {})
		return
	Settings.apply_video()
	Audio.start_game_audio()
	modulator = CanvasModulate.new()
	add_child(modulator)
	nest_view = NestView.new()
	nest_view.setup(AntSim.SPACE_NEST0, w.nests[0])
	add_child(nest_view)
	surface_view = SurfaceView.new()
	add_child(surface_view)
	if w.house:
		house_view = HouseView.new()
		house_view.setup(AntSim.SPACE_HOUSE, w.house)
		add_child(house_view)
	var layer := CanvasLayer.new()
	add_child(layer)
	rain_fx = RainFX.new()
	layer.add_child(rain_fx)
	hud = HUD.new()
	hud.main = self
	layer.add_child(hud)
	Events.game_over.connect(func(won, reason): hud.show_game_over(won, reason))
	Events.chapter_completed.connect(func(_id): hud.show_chapter_complete(w.campaign.chapter))
	var start_view := "nest" if not w.flags.get("surface", false) or w.mode == "campaign" and w.chapter_id == "chapter_1" else "surface"
	set_view(start_view)
	if w.campaign.active():
		var ch: Dictionary = w.campaign.chapter
		for line in ch.get("intro", []):
			hud.show_dialog("", line)
	Events.hint.emit("welcome")


func set_view(v: String) -> void:
	if v == "house" and house_view == null:
		v = "nest"
	if v == "surface" and not Game.world.flags.get("surface", false):
		hud._on_toast("The surface isn't unlocked yet.")
		v = "nest"
	view = v
	nest_view.visible = v == "nest"
	surface_view.visible = v == "surface"
	if house_view:
		house_view.visible = v == "house"
	active_camera().make_current()
	if v == "surface":
		Events.hint.emit("surface")
	Events.view_changed.emit(v)
	if tool in ["dig", "chamber", "build"] and v == "surface" and not (tool == "build" and build_kind == "thatch"):
		set_tool("trail")
	elif tool in ["trail", "erase", "avoid", "rally", "satellite"] and v == "nest":
		set_tool("dig")


func active_view() -> Node2D:
	match view:
		"surface": return surface_view
		"house": return house_view
	return nest_view


func active_camera() -> Camera2D:
	return active_view().camera


func active_space() -> int:
	match view:
		"surface": return AntSim.SPACE_SURFACE
		"house": return AntSim.SPACE_HOUSE
	return AntSim.SPACE_NEST0 + nest_index


func set_tool(t: String) -> void:
	tool = t
	surface_view.preview = "satellite" if t == "satellite" else ""
	var b: Dictionary = Data.table("pheromones").get("brush", {})
	surface_view.brush_r = float(b.get("radius_mm", 60)) * 2.5 if t in ["trail", "avoid"] else (float(b.get("erase_radius_mm", 90)) * 2.5 if t == "erase" else 0.0)
	if t in ["trail", "erase", "avoid", "rally", "satellite"] and view == "nest":
		set_view("surface")
	if t in ["dig", "chamber"] and view != "nest":
		set_view("nest")
	if t == "build" and build_kind != "thatch" and view != "nest":
		set_view("nest")
	Events.hint.emit({"dig": "dig", "chamber": "chamber", "trail": "trail", "erase": "erase", "select": "inspect"}.get(t, ""))


func toggle_overlay(o: String) -> void:
	if o == "scent":
		surface_view.show_scent = not surface_view.show_scent
		if view == "nest":
			set_view("surface")
		Events.hint.emit("overlay")
		return
	var gv: GridView = house_view if view == "house" and house_view else nest_view
	if view == "surface":
		set_view("nest")
		gv = nest_view
	gv.set_overlay(o)
	Events.hint.emit("overlay")


func overlay_text() -> String:
	if view == "surface" and surface_view.show_scent:
		return "Scent: green food, blue home, red alarm, purple explore, yellow your trails, orange rival"
	var gv: GridView = house_view if view == "house" and house_view else nest_view
	match gv.overlay:
		"air": return "Air: red = stale. Dig vent shafts to the surface."
		"water": return "Water: blue = wet. Sumps drain floods."
		"heat": return "Heat: green = ideal brood temperature (25-30 C)."
		"mould": return "Mould: green = rotting. Warm + wet + stale air, or unburied dead."
	return ""


# ---------------------------------------------------------------- input

func _unhandled_input(e: InputEvent) -> void:
	var w := Game.world
	if w == null:
		return
	var cam := active_camera()
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				_zoom_at(1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15)
			return
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if tool == "rally" and mb.pressed and view == "surface":
				w.clear_rally(0)
				return
			_panning = mb.pressed
			_pan_last = mb.position
			return
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			_pan_last = mb.position
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_on_left(mb.pressed, mb.shift_pressed)
			return
	if e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _panning:
			cam.position -= (mm.position - _pan_last) / cam.zoom
			_pan_last = mm.position
			follow = false
		if _painting:
			_paint()
		if _drag_from.x >= 0 and view == "nest":
			var c := nest_view.world_cell(nest_view.mouse_world())
			nest_view.drag_rect = Rect2i(Vector2i(mini(_drag_from.x, c.x), mini(_drag_from.y, c.y)), (_drag_from - c).abs() + Vector2i.ONE)
		if view == "nest":
			var g: NestGrid = w.nests[nest_index]
			nest_view.hover_cell = g.cell_at(nest_view.mouse_world()) if tool == "build" else -1
		return
	if e is InputEventKey and e.pressed and not e.echo:
		_on_key(e)


func _on_key(e: InputEventKey) -> void:
	if e.is_action("toggle_view"):
		var order := ["nest", "surface"] + (["house"] if house_view else [])
		set_view(order[(order.find(view) + 1) % order.size()])
	elif e.is_action("pause"):
		Game.toggle_pause()
	elif e.is_action("speed_up"):
		Clock.running = true
		Game.state = Game.State.PLAYING
		Clock.set_speed_index(mini(Clock.speed_index() + 1, 3))
		Events.hint.emit("speed")
	elif e.is_action("speed_down"):
		Clock.set_speed_index(maxi(Clock.speed_index() - 1, 1))
	elif e.is_action("overlay_scent"):
		toggle_overlay("scent")
	elif e.is_action("overlay_air"):
		toggle_overlay("air")
	elif e.is_action("overlay_water"):
		toggle_overlay("water")
	elif e.is_action("overlay_heat"):
		toggle_overlay("heat")
	elif e.is_action("overlay_mould"):
		toggle_overlay("mould")
	elif e.is_action("follow"):
		follow = not follow and selected_ant >= 0
	elif e.is_action("evolution"):
		open_evolution()
	elif e.is_action("guide"):
		open_guide()
	elif e.is_action("castes"):
		open_castes()
	elif e.is_action("menu"):
		open_pause()
	elif e.is_action("next_nest"):
		var player_nests: Array = []
		for c in Game.world.player_colonies():
			player_nests.append(c.nest)
		var k := (player_nests.find(nest_index) + 1) % player_nests.size()
		nest_index = player_nests[k]
		nest_view.show_nest(nest_index)
		set_view("nest")
		hud._on_toast("Viewing %s" % Game.world.colonies[Game.world.nests[nest_index].owner].name)
	elif e.is_action("quicksave"):
		Save.save_game("quick")
	elif e.is_action("quickload"):
		Save.load_game("quick")
	else:
		for t in HUD.TOOLS:
			if t[2] != "" and e.is_action(t[2]):
				set_tool(t[0])


func _zoom_at(factor: float) -> void:
	var cam := active_camera()
	var before := active_view().get_global_mouse_position()
	var z := clampf(cam.zoom.x * factor, ZOOM_MIN[view], ZOOM_MAX[view])
	cam.zoom = Vector2(z, z)
	var after := active_view().get_global_mouse_position()
	cam.position += before - after


func _on_left(pressed: bool, shift: bool) -> void:
	var w := Game.world
	var mp := active_view().get_global_mouse_position()
	if not pressed:
		if _drag_from.x >= 0 and view == "nest":
			var c := nest_view.world_cell(mp)
			if tool == "dig":
				var n := w.dig_rect(nest_index, _drag_from, c, not shift)
				if n > 0:
					Audio.play("build", -10.0)
			elif tool == "chamber":
				var err := w.chamber_rect(nest_index, _drag_from, c, chamber_type)
				hud._on_toast(err if err != "" else "%s marked." % Data.table("chambers")[chamber_type]["name"])
		_drag_from = Vector2i(-1, -1)
		nest_view.drag_active = false
		_painting = false
		return
	match tool:
		"select":
			_select_at(mp)
		"dig", "chamber":
			if view == "nest":
				_drag_from = nest_view.world_cell(mp)
				nest_view.drag_rect = Rect2i(_drag_from, Vector2i.ONE)
				nest_view.drag_active = true
		"build":
			if build_kind == "thatch":
				var err := w.build("thatch", _nearest_player_nest(mp), 0)
				hud._on_toast(err if err != "" else "Thatch dome built.")
			elif view == "nest":
				var g: NestGrid = w.nests[nest_index]
				var err := w.build(build_kind, nest_index, g.cell_at(mp))
				hud._on_toast(err if err != "" else "%s placed." % Data.table("builds")[build_kind]["name"])
				if err == "":
					Audio.play("build")
		"trail", "erase", "avoid":
			if view != "nest":
				_painting = true
				_paint()
		"rally":
			if view == "surface":
				w.set_rally(0, mp, 6.0)
				hud._on_toast("Soldiers rallying!")
		"satellite":
			if view == "surface":
				var err := w.found_satellite(mp)
				hud._on_toast(err if err != "" else "Satellite founded!")
				if err == "":
					set_tool("select")


func _paint() -> void:
	Game.world.paint(active_space(), active_view().get_global_mouse_position(), tool)


func _select_at(mp: Vector2) -> void:
	var w := Game.world
	selected_creature = -1
	surface_view.selected_creature = -1
	var space := active_space()
	var best := -1
	var bd := INF
	for cr in w.creatures.list:
		if cr["space"] == space:
			var d: float = cr["pos"].distance_to(mp)
			if d < cr["size"] * 0.8 + 10.0 / active_camera().zoom.x and d < bd:
				bd = d
				best = cr["id"]
	if best >= 0:
		selected_creature = best
		surface_view.selected_creature = best
		selected_ant = -1
		return
	selected_ant = w.ants.nearest_ant(space, mp, maxf(12.0 / active_camera().zoom.x, 4.0))
	follow = false
	Events.selection_changed.emit("ant", selected_ant)


func _nearest_player_nest(p: Vector2) -> int:
	var w := Game.world
	var best := 0
	var bd := INF
	for c in w.player_colonies():
		var d: float = w.nests[c.nest].surface_pos.distance_to(p)
		if d < bd:
			bd = d
			best = c.nest
	return best


func jump_to(p: Vector2, space: int) -> void:
	if space == AntSim.SPACE_SURFACE:
		set_view("surface")
		surface_view.camera.position = p
	elif space == AntSim.SPACE_HOUSE and house_view:
		set_view("house")
		house_view.camera.position = p
	elif space >= AntSim.SPACE_NEST0:
		nest_index = space - AntSim.SPACE_NEST0
		if nest_view.nest_index != nest_index:
			nest_view.show_nest(nest_index)
		set_view("nest")
		nest_view.camera.position = p


func surface_camera_rect() -> Rect2:
	var cam := surface_view.camera
	var sz := get_viewport_rect().size / cam.zoom
	return Rect2(cam.get_screen_center_position() - sz * 0.5, sz)


func _process(delta: float) -> void:
	var w := Game.world
	if w == null:
		return
	var cam := active_camera()
	var pan := Vector2(Input.get_axis("pan_left", "pan_right"), Input.get_axis("pan_up", "pan_down"))
	if pan != Vector2.ZERO:
		cam.position += pan * 600.0 * delta / cam.zoom.x
		follow = false
	if follow and w.ants.is_alive(selected_ant):
		var sp := w.ants.space_of(selected_ant)
		if sp != active_space():
			jump_to(w.ants.pos[selected_ant], sp)
		cam.position = cam.position.lerp(w.ants.pos[selected_ant], minf(1.0, delta * 6.0))
	var day := Clock.daylight()
	var tint := Color.WHITE
	if view == "surface":
		tint = Color(0.35, 0.4, 0.6).lerp(Color.WHITE, clampf(day * 1.6 - 0.1, 0.0, 1.0))
		if w.weather.rain > 0.0:
			tint = tint.darkened(0.25 * w.weather.rain)
		if w.weather.heatwave:
			tint = tint * Color(1.05, 0.97, 0.88)
	elif view == "house":
		tint = Color(0.75, 0.75, 0.85).lerp(Color.WHITE, day)
	modulator.color = tint
	rain_fx.intensity = w.weather.rain if view == "surface" else 0.0


# ---------------------------------------------------------------- panels & commands

func open_pause() -> void:
	if _pause_menu and is_instance_valid(_pause_menu):
		_pause_menu.queue_free()
		Game.set_paused(false)
		return
	Game.set_paused(true)
	_pause_menu = PauseMenu.open(hud)
	_pause_menu.tree_exited.connect(func():
		if Game.state == Game.State.PAUSED:
			Game.set_paused(false))


func open_castes() -> void:
	CastePanel.open(hud)
	Events.hint.emit("castes")


func open_evolution() -> void:
	if not Game.world.flags.get("evolution", false):
		hud._on_toast("Evolution unlocks later in the campaign.")
		return
	EvolutionTree.open(hud)
	Events.hint.emit("traits")


func open_guide() -> void:
	FieldGuide.open(hud)


func raise_royals() -> void:
	var w := Game.world
	if not w.flags.get("evolution", false):
		hud._on_toast("Nuptial flights unlock later in the campaign.")
		return
	var n := w.raise_royals(1)
	hud._on_toast("A royal pupa is growing. Flights happen on spring day %d at noon." % int(Data.table("seasons")["flight"]["day"]) if n > 0 else "Royals cost 60 sugar + 60 protein.")
	Events.hint.emit("flight")


func relocate_queen() -> void:
	var w := Game.world
	var target := -1
	for c in w.player_colonies():
		if c.is_satellite:
			target = c.index
			break
	if target < 0:
		hud._on_toast("You need a satellite nest to move the queen to.")
		return
	var err := w.start_queen_relocation(target)
	hud._on_toast(err)
