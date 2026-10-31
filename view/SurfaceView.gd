class_name SurfaceView
extends Node2D
## Top-down yard: painterly ground, objects, food, scent overlay, ants, creatures,
## weather and event markers. Zoom from ant level to the whole yard.

const GROUND_COLORS := [Color("#5f8f3a"), Color("#8a6a45"), Color("#a8a49c"), Color("#5a3d28")]

var space := AntSim.SPACE_SURFACE
var camera: Camera2D
var ground: Sprite2D
var decor: Node2D
var canopy: Node2D
var scent: Sprite2D
var ants_r: AntRenderer
var dyn: Node2D
var show_scent := false
var _scent_timer := 0.0
var _scent_tex: ImageTexture
var telegraphs: Array = []  # [kind, pos, until_tick]
var preview := ""  # tool preview: "satellite", "rally", "thatch"
var brush_r := 0.0
var selected_creature := -1


func _ready() -> void:
	var w = Game.world
	var s: SurfaceWorld = w.surface
	ground = Sprite2D.new()
	ground.centered = false
	ground.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var bytes := PackedByteArray()
	bytes.resize(s.w * s.h * 4)
	for i in s.w * s.h:
		var g := s.ground[i]
		var c: Color = GROUND_COLORS[g]
		if s.shade[i] != 0:
			c = c.darkened(0.12)
		bytes[i * 4] = int(c.r * 255)
		bytes[i * 4 + 1] = int(c.g * 255)
		bytes[i * 4 + 2] = int(c.b * 255)
		bytes[i * 4 + 3] = 255 if g == SurfaceWorld.G_GRASS else 0
	ground.texture = ImageTexture.create_from_image(Image.create_from_data(s.w, s.h, false, Image.FORMAT_RGBA8, bytes))
	ground.scale = Vector2(s.cell, s.cell)
	var gm := ShaderMaterial.new()
	gm.shader = load("res://shaders/ground.gdshader")
	gm.set_shader_parameter("noise_tex", ArtGen.noise_texture())
	gm.set_shader_parameter("world_size", s.size)
	ground.material = gm
	add_child(ground)
	decor = Node2D.new()
	decor.draw.connect(_draw_decor)
	add_child(decor)
	scent = Sprite2D.new()
	scent.centered = false
	scent.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	scent.visible = false
	add_child(scent)
	ants_r = AntRenderer.new(space)
	add_child(ants_r)
	dyn = Node2D.new()
	dyn.draw.connect(_draw_dynamic)
	add_child(dyn)
	canopy = Node2D.new()
	canopy.draw.connect(_draw_canopy)
	add_child(canopy)
	camera = Camera2D.new()
	camera.limit_left = -2000
	camera.limit_top = -2000
	camera.limit_right = int(s.size.x) + 2000
	camera.limit_bottom = int(s.size.y) + 2000
	add_child(camera)
	focus_default()
	Events.telegraph.connect(_on_telegraph)


func focus_default() -> void:
	camera.position = Game.world.nests[0].surface_pos
	camera.zoom = Vector2.ONE * 1.6


func _on_telegraph(kind: String, p: Vector2, sp: int, seconds: float) -> void:
	if sp != space:
		return
	telegraphs.append([kind, p, Clock.tick + int(seconds * Clock.TICK_HZ)])


func _process(delta: float) -> void:
	var w = Game.world
	if w == null:
		return
	(ground.material as ShaderMaterial).set_shader_parameter("wet", w.weather.rain)
	if show_scent:
		_scent_timer -= delta
		if _scent_timer <= 0.0:
			_scent_timer = 0.3
			_rebuild_scent()
	scent.visible = show_scent
	var keep: Array = []
	for t in telegraphs:
		if t[2] > Clock.tick:
			keep.append(t)
	telegraphs = keep
	dyn.queue_redraw()


func _rebuild_scent() -> void:
	var w = Game.world
	var ph: PheromoneField = w.pher[space]
	var vp := get_viewport_rect().size / camera.zoom
	var tl := camera.get_screen_center_position() - vp * 0.5
	var c0 := Vector2i(maxi(int(tl.x / ph.cell), 0), maxi(int(tl.y / ph.cell), 0))
	var c1 := Vector2i(mini(int((tl.x + vp.x) / ph.cell) + 1, ph.w), mini(int((tl.y + vp.y) / ph.cell) + 1, ph.h))
	var stride := maxi(1, int(ceil(maxf(c1.x - c0.x, c1.y - c0.y) / 220.0)))
	var iw := maxi((c1.x - c0.x) / stride, 1)
	var ih := maxi((c1.y - c0.y) / stride, 1)
	var bytes := PackedByteArray()
	bytes.resize(iw * ih * 4)
	var cols: Array = Settings.scent_colors()
	var chans := [PheromoneField.FOOD, PheromoneField.HOME, PheromoneField.ALARM, PheromoneField.EXPLORE, PheromoneField.PLAYER]
	var rival_food := PheromoneField.ch(1, PheromoneField.FOOD)
	for y in ih:
		for x in iw:
			var c := (c0.y + y * stride) * ph.w + (c0.x + x * stride)
			var r := 0.0
			var g := 0.0
			var b := 0.0
			var a := 0.0
			for k in 5:
				var v := ph.sample_cell(c, chans[k])
				if v > 0.05:
					var s := clampf(v / (40.0 if k != 4 else 120.0), 0.0, 1.0)
					var cc: Color = cols[k]
					r = maxf(r, cc.r * s)
					g = maxf(g, cc.g * s)
					b = maxf(b, cc.b * s)
					a = maxf(a, s * 0.8)
			if ph.channels > 5:
				var rv := ph.sample_cell(c, rival_food)
				if rv > 0.05:
					var s2 := clampf(rv / 40.0, 0.0, 1.0)
					r = maxf(r, 0.9 * s2)
					g = maxf(g, 0.4 * s2)
					a = maxf(a, s2 * 0.6)
			var o := (y * iw + x) * 4
			bytes[o] = int(r * 255)
			bytes[o + 1] = int(g * 255)
			bytes[o + 2] = int(b * 255)
			bytes[o + 3] = int(a * 255)
	var img := Image.create_from_data(iw, ih, false, Image.FORMAT_RGBA8, bytes)
	if _scent_tex == null or _scent_tex.get_size() != Vector2(iw, ih):
		_scent_tex = ImageTexture.create_from_image(img)
	else:
		_scent_tex.update(img)
	scent.texture = _scent_tex
	scent.position = Vector2(c0) * ph.cell
	scent.scale = Vector2.ONE * ph.cell * stride


# ---------------------------------------------------------------- static decor

func _draw_decor() -> void:
	var w = Game.world
	var s: SurfaceWorld = w.surface
	var rng := RandomNumberGenerator.new()
	rng.seed = s.seed_value + 99
	var sc: Dictionary = w.yard.get("scatter", {})
	for i in int(sc.get("grass_clumps", 2000)):
		var p := Vector2(rng.randf() * s.size.x, rng.randf() * s.size.y)
		if s.ground_at(p) != SurfaceWorld.G_GRASS or s.is_blocked(p.x, p.y):
			continue
		var col := Color("#4d7d2c").lerp(Color("#7aa83f"), rng.randf())
		for k in 5:
			var a := -PI * 0.5 + rng.randf_range(-0.9, 0.9)
			var l := rng.randf_range(25, 60)
			decor.draw_line(p, p + Vector2(cos(a), sin(a)) * l + Vector2(rng.randf_range(-6, 6), 0), col, rng.randf_range(2.0, 4.0))
	for i in int(sc.get("pebbles", 800)):
		var p := Vector2(rng.randf() * s.size.x, rng.randf() * s.size.y)
		if s.is_blocked(p.x, p.y):
			continue
		var r := rng.randf_range(4, 22)
		var col := Color("#8c8780").lerp(Color("#b8b0a2"), rng.randf())
		decor.draw_circle(p + Vector2(r * 0.15, r * 0.2), r, Color(0, 0, 0, 0.2))
		decor.draw_circle(p, r, col)
		decor.draw_circle(p - Vector2(r, r) * 0.3, r * 0.35, col.lightened(0.25))
	for i in int(sc.get("leaves", 300)):
		var p := Vector2(rng.randf() * s.size.x, rng.randf() * s.size.y)
		if s.is_blocked(p.x, p.y):
			continue
		var col: Color = [Color("#9a7a30"), Color("#b0502a"), Color("#7a8a30")][rng.randi() % 3]
		decor.draw_set_transform(p, rng.randf() * TAU, Vector2.ONE)
		ArtGen._ellipse_draw(decor, Vector2.ZERO, Vector2(rng.randf_range(40, 90), rng.randf_range(20, 40)), col)
		decor.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
	for f in s.flowers:
		for k in 6:
			var a := k * TAU / 6.0
			decor.draw_circle(f + Vector2(cos(a), sin(a)) * 40.0, 28.0, Color("#f0e0f0"))
		decor.draw_circle(f, 22.0, Color("#f0c020"))
	for o in s.objects:
		_draw_object(o)


func _draw_object(o: Dictionary) -> void:
	var t: String = o["type"]
	var sz: Vector2 = o["size"]
	match o.get("shape", "rect"):
		"line":
			var pts := PackedVector2Array(o["points"])
			decor.draw_polyline(pts, Color(0, 0, 0, 0.25), sz.x + 20.0)
			decor.draw_polyline(pts, Color("#3a8a3a"), sz.x)
			decor.draw_polyline(pts, Color("#6ac06a"), sz.x * 0.3)
			return
		"circle":
			var p: Vector2 = o["pos"]
			var r := sz.x * 0.5
			decor.draw_circle(p + Vector2(r * 0.25, r * 0.3), r * 1.05, Color(0, 0, 0, 0.25))
			match t:
				"gnome":
					decor.draw_circle(p, r, Color("#3a6ab0"))
					decor.draw_circle(p, r * 0.55, Color("#e8d0b0"))
					decor.draw_circle(p, r * 0.32, Color("#d03020"))
					decor.draw_circle(p + Vector2(0, r * 0.25), r * 0.3, Color("#f0f0f0"))
				"tree":
					decor.draw_circle(p, r, Color("#5a3e26"))
					decor.draw_arc(p, r * 0.6, 0, TAU, 24, Color("#4a3220"), 6.0)
				"pot":
					decor.draw_circle(p, r, Color("#b0603a"))
					decor.draw_circle(p, r * 0.78, Color("#4a3020"))
					decor.draw_circle(p, r * 0.3, Color("#4a8a2a"))
				"watering_can":
					decor.draw_circle(p, r, Color("#3a7a6a"))
					decor.draw_circle(p, r * 0.7, Color("#2a5a4a"))
					decor.draw_line(p, p + Vector2(r * 1.6, -r * 0.6), Color("#3a7a6a"), r * 0.25)
				_:
					decor.draw_circle(p, r, Color("#777777"))
			return
	var p: Vector2 = o["pos"]
	var r := Rect2(p - sz * 0.5, sz)
	decor.draw_rect(Rect2(r.position + Vector2(40, 50), r.size), Color(0, 0, 0, 0.25))
	match t:
		"house_wall":
			decor.draw_rect(r, Color("#9c4b36"))
			var rows := int(r.size.y / 70.0)
			for y in rows:
				var yy := r.position.y + y * 70.0
				decor.draw_line(Vector2(r.position.x, yy), Vector2(r.end.x, yy), Color("#7a3a28"), 6.0)
			decor.draw_rect(Rect2(r.position.x, r.end.y - 120, r.size.x, 120), Color("#6a6460"))
		"shed":
			decor.draw_rect(r, Color("#6a5038"))
			for k in int(r.size.x / 160.0):
				decor.draw_line(Vector2(r.position.x + k * 160.0, r.position.y), Vector2(r.position.x + k * 160.0, r.end.y), Color("#4a3828"), 10.0)
			decor.draw_rect(r, Color("#3a2a1c"), false, 30.0)
		"bbq":
			decor.draw_rect(r, Color("#2a2a2a"))
			for k in 6:
				decor.draw_line(Vector2(r.position.x + 40, r.position.y + 40 + k * 70), Vector2(r.end.x - 40, r.position.y + 40 + k * 70), Color("#6a6a6a"), 10.0)
		"chair":
			decor.draw_rect(r, Color("#e8e8e0"))
			decor.draw_rect(r.grow(-60), Color("#c8c8c0"))
		"brick":
			decor.draw_rect(r, Color("#b0503a"))
			decor.draw_rect(r, Color("#7a3020"), false, 8.0)
		_:
			decor.draw_rect(r, Color("#777777"))


func _draw_canopy() -> void:
	var s: SurfaceWorld = Game.world.surface
	for t in s.trees:
		var p: Vector2 = t["pos"]
		var r: float = t["canopy"]
		canopy.draw_circle(p + Vector2(260, 320), r, Color(0, 0, 0, 0.14))
		for k in 7:
			var a := k * TAU / 7.0
			canopy.draw_circle(p + Vector2(cos(a), sin(a)) * r * 0.45, r * 0.62, Color(0.2, 0.42, 0.16, 0.22))
		canopy.draw_circle(p, r * 0.5, Color(0.25, 0.5, 0.18, 0.25))


# ---------------------------------------------------------------- dynamic

func _draw_dynamic() -> void:
	var w = Game.world
	var s: SurfaceWorld = w.surface
	var t := Clock.tick * Clock.DT
	var z := camera.zoom.x
	var font := ThemeDB.fallback_font
	# Nest entrances + mounds.
	for i in w.nests.size():
		var g: NestGrid = w.nests[i]
		var col_i := g.owner
		var friendly: bool = col_i >= 0 and w.colonies[col_i].faction == 0
		var p := g.surface_pos
		var mr := 30.0 + sqrt(g.mound) * 3.0
		dyn.draw_circle(p + Vector2(6, 8), mr, Color(0, 0, 0, 0.2))
		dyn.draw_circle(p, mr, Color("#7a5634") if friendly else Color("#8a4a34"))
		dyn.draw_circle(p, mr * 0.6, Color("#6a4a2c"))
		dyn.draw_circle(p, 9.0, Color("#140c08"))
		if g.thatch:
			dyn.draw_arc(p, mr * 0.8, 0, TAU, 20, Color("#d0a858"), 12.0)
		if z < 1.2:
			var label: String = w.colonies[col_i].name if col_i >= 0 else ""
			dyn.draw_string(font, p + Vector2(-60, -mr - 12) , label, HORIZONTAL_ALIGNMENT_LEFT, -1, int(14.0 / z), Color(1, 1, 1, 0.85) if friendly else Color(1, 0.5, 0.4, 0.85))
	# House gaps.
	for gp in s.house_gaps:
		dyn.draw_rect(Rect2(gp - Vector2(30, 40), Vector2(60, 40)), Color("#140c08"))
	# Food.
	var vp := get_viewport_rect().size / camera.zoom
	var view_r := Rect2(camera.get_screen_center_position() - vp * 0.5, vp).grow(200)
	for f in s.foods.values():
		if f["space"] == 0 and view_r.has_point(f["pos"]):
			ArtGen.draw_food(dyn, f, 1.0 if z > 0.3 else 3.0)
	# Creatures.
	for cr in w.creatures.list:
		if cr["space"] != space or not view_r.has_point(cr["pos"]):
			continue
		var def: Dictionary = w.creatures.defs[cr["kind"]]
		if cr["behaviour"] == "swooper":
			if cr["state"] == "shadow":
				var k := clampf(1.0 - cr["timer"] / 3.0, 0.0, 1.0)
				dyn.draw_circle(cr["pos"], 40.0 + 260.0 * (1.0 - k), Color(0, 0, 0, 0.15 + 0.35 * k))
				ArtGen.draw_bug(dyn, def, cr["pos"] + Vector2(0, -600 * (1.0 - k)), PI * 0.5, cr["size"] * (1.0 + (1.0 - k)), t, 0.0, k)
			continue
		var attack := 0.6 if cr["attached"] > 0 and fmod(t * 3.0, 1.0) < 0.3 else 0.0
		ArtGen.draw_bug(dyn, def, cr["pos"], cr["heading"], maxf(cr["size"], 3.0 / z), t, attack, 1.0, cr["tame"])
		if cr["id"] == selected_creature:
			dyn.draw_arc(cr["pos"], cr["size"] * 0.8 + 6.0, 0, TAU, 24, Color(1, 1, 0.4), 2.0 / z)
		if cr["hp"] < cr["max_hp"] and cr["behaviour"] in ["hunter", "raider", "mount"]:
			var hp_w: float = cr["size"]
			dyn.draw_rect(Rect2(cr["pos"] + Vector2(-hp_w * 0.5, -cr["size"] * 0.8), Vector2(hp_w, 2.0 / z * 2.0)), Color(0.2, 0, 0))
			dyn.draw_rect(Rect2(cr["pos"] + Vector2(-hp_w * 0.5, -cr["size"] * 0.8), Vector2(hp_w * cr["hp"] / cr["max_hp"], 2.0 / z * 2.0)), Color(0.9, 0.2, 0.1))
	# Sprinkler.
	if w.weather.sprinkler_active and not s.sprinkler.is_empty():
		var sp: Vector2 = s.sprinkler["pos"]
		var rr: float = s.sprinkler.get("radius", 2000)
		dyn.draw_circle(sp, rr, Color(0.4, 0.6, 1.0, 0.12))
		var a := fmod(t * 1.5, TAU)
		dyn.draw_line(sp, sp + Vector2(cos(a), sin(a)) * rr, Color(0.7, 0.85, 1.0, 0.5), 30.0)
		dyn.draw_circle(sp, 50.0, Color("#404850"))
	# Mower.
	if w.weather.mower_active:
		var mx: float = w.weather.mower_x
		dyn.draw_rect(Rect2(mx - Weather.MOWER_BAND, 0, Weather.MOWER_BAND * 2.0, s.size.y), Color(1, 0.2, 0.1, 0.12))
		var mp := Vector2(mx, camera.get_screen_center_position().y)
		dyn.draw_rect(Rect2(mp - Vector2(250, 350), Vector2(500, 700)), Color("#c03020"))
		dyn.draw_rect(Rect2(mp - Vector2(200, 300), Vector2(400, 600)), Color("#202020"))
		dyn.draw_line(mp + Vector2(-250, 0), mp + Vector2(-900, 0), Color("#808080"), 30.0)
	# Upcoming event markers (telegraph).
	for e in w.weather.upcoming():
		if e["warned"]:
			var secs: float = e["in_seconds"]
			var p: Vector2 = e["pos"]
			if e["kind"] == "mower":
				dyn.draw_rect(Rect2(0, 0, Weather.MOWER_BAND * 2.0, s.size.y), Color(1, 0.6, 0.1, 0.15 + 0.1 * sin(t * 6.0)))
				p = Vector2(Weather.MOWER_BAND, camera.get_screen_center_position().y)
			dyn.draw_arc(p, 200.0 + 40.0 * sin(t * 5.0), 0, TAU, 32, Color(1, 0.7, 0.1, 0.9), 6.0 / z)
			dyn.draw_string(font, p + Vector2(-80, -240), "%s in %ds" % [String(e["kind"]).to_upper(), int(secs)], HORIZONTAL_ALIGNMENT_LEFT, -1, int(16.0 / z), Color(1, 0.8, 0.2))
	for tg in telegraphs:
		var k := clampf(float(tg[2] - Clock.tick) / Clock.TICK_HZ, 0.0, 30.0)
		dyn.draw_arc(tg[1], 60.0 + 20.0 * sin(t * 8.0), 0, TAU, 24, Color(1, 0.3, 0.1, 0.9), 3.0 / z)
		if k > 0.5:
			dyn.draw_string(font, tg[1] + Vector2(-40, -80), "%ds" % int(k), HORIZONTAL_ALIGNMENT_LEFT, -1, int(14.0 / z), Color(1, 0.5, 0.3))
	# Rally flag.
	for f in 2:
		if w.rally_active(f):
			var rp: Vector2 = w.rally_point(f)
			var c := Color(1, 0.85, 0.2) if f == 0 else Color(0.9, 0.2, 0.15)
			dyn.draw_line(rp, rp + Vector2(0, -160), Color(0.3, 0.2, 0.1), 8.0)
			dyn.draw_colored_polygon(PackedVector2Array([rp + Vector2(0, -160), rp + Vector2(110, -125), rp + Vector2(0, -90)]), c)
	# Exterminator on the surface.
	if w.house_ai and w.house_ai.ext_phase in ["trace", "dig"]:
		var ep: Vector2 = w.house_ai.ext_pos if w.house_ai.ext_phase == "trace" else w.nests[0].surface_pos + Vector2(0, -260)
		dyn.draw_circle(ep, 220.0, Color(0.1, 0.4, 0.2, 0.18))
		dyn.draw_circle(ep + Vector2(0, 30), 160.0, Color(0, 0, 0, 0.25))
		dyn.draw_circle(ep, 150.0, Color("#e0e040"))
		dyn.draw_circle(ep, 60.0, Color("#202020"))
		dyn.draw_string(font, ep + Vector2(-140, -240), "EXTERMINATOR", HORIZONTAL_ALIGNMENT_LEFT, -1, int(18.0 / z), Color(1, 0.3, 0.2))
	# Tool previews.
	var mp2 := get_global_mouse_position()
	if preview == "satellite":
		var ents: Array = []
		for g2 in w.nests:
			ents.append(g2.surface_pos)
		var ok: bool = s.valid_nest_site(mp2, ents)
		dyn.draw_arc(mp2, 120.0, 0, TAU, 32, Color(0.3, 1, 0.3) if ok else Color(1, 0.3, 0.3), 4.0 / z)
	elif brush_r > 0.0:
		dyn.draw_arc(mp2, brush_r, 0, TAU, 32, Color(1, 1, 1, 0.5), 2.0 / z)
