class_name HouseView
extends GridView
## House cross-section: rooms, wall cavities, under-floor; crumbs, cat, homeowner,
## spray clouds, exterminator fog.


func _ready() -> void:
	space = AntSim.SPACE_HOUSE
	super._ready()


func _chamber_palette() -> Array:
	var out: Array = []
	out.resize(16)
	for i in 16:
		out[i] = Color("#3a2a20")
	if grid == null:
		return out
	var rooms: Dictionary = Data.table("house").get("rooms", {})
	for i in grid.room_names.size():
		var rn: String = grid.room_names[i]
		if rooms.has(rn):
			out[i % 16] = Color(rooms[rn]["color"])
		elif rn == "cavity" or rn == "gap":
			out[i % 16] = Color("#2a2018")
	return out


func focus_default() -> void:
	camera.position = Vector2(grid.w * grid.cell * 0.3, grid.h * grid.cell * 0.65)
	camera.zoom = Vector2.ONE * 0.5


func _draw_extra(t: float) -> void:
	var w = Game.world
	var hai: HouseAI = w.house_ai
	if hai == null:
		return
	var font := ThemeDB.fallback_font
	var rooms: Dictionary = Data.table("house").get("rooms", {})
	for rn in rooms.keys():
		var r: Array = rooms[rn]["rect"]
		var p := Vector2(r[0], r[1]) * grid.cell + Vector2(20, 60)
		dyn.draw_string(font, p, rooms[rn]["name"], HORIZONTAL_ALIGNMENT_LEFT, -1, 48, Color(0, 0, 0, 0.35))
	# Sunbeam.
	var sb: Array = Data.table("house")["cat"].get("sunbeam", [160, 84])
	var sbp := grid.center(int(sb[1]) * grid.w + int(sb[0]))
	if Clock.hour_f() > 10.0 and Clock.hour_f() < 17.0:
		dyn.draw_colored_polygon(PackedVector2Array([sbp + Vector2(-400, -1100), sbp + Vector2(-100, -1100), sbp + Vector2(250, 30), sbp + Vector2(-250, 30)]), Color(1, 0.95, 0.6, 0.12))
	# Food.
	for f in w.surface.foods_in_space(AntSim.SPACE_HOUSE):
		ArtGen.draw_food(dyn, f, 1.6)
	# Sprays & fog.
	for s in hai.sprays:
		dyn.draw_circle(s["pos"], s["radius"], Color(0.6, 0.9, 0.7, 0.18))
	if hai.ext_phase == "fog" and hai.ext_fog_room != "":
		var r: Array = rooms[hai.ext_fog_room]["rect"]
		var rect := Rect2(Vector2(r[0], r[1]) * grid.cell, Vector2(r[2], r[3]) * grid.cell)
		dyn.draw_rect(rect, Color(0.8, 0.85, 0.8, 0.35 + 0.1 * sin(t * 3.0)))
		dyn.draw_string(font, rect.get_center() - Vector2(160, 0), "FOGGING", HORIZONTAL_ALIGNMENT_LEFT, -1, 96, Color(0.2, 0.3, 0.2, 0.7))
	# Cat.
	var cat_def: Dictionary = w.creatures.defs.get("house_cat", {})
	if not cat_def.is_empty():
		ArtGen.draw_bug(dyn, cat_def, hai.cat_pos + Vector2(0, -60), 0.0 if hai.cat_goal.x >= hai.cat_pos.x else PI, 450.0, t if not hai.cat_sleeping else 0.0)
		if hai.cat_sleeping:
			dyn.draw_string(font, hai.cat_pos + Vector2(80, -220), "z z z", HORIZONTAL_ALIGNMENT_LEFT, -1, 60, Color(1, 1, 1, 0.8))
	# Homeowner: tall silhouette.
	if hai.person_room != "away":
		var p := hai.person_pos
		var body := Color(0.25, 0.3, 0.45, 0.85)
		dyn.draw_rect(Rect2(p + Vector2(-110, -1500), Vector2(220, 820)), body)
		dyn.draw_rect(Rect2(p + Vector2(-90, -700), Vector2(80, 700)), Color(0.2, 0.2, 0.3, 0.85))
		dyn.draw_rect(Rect2(p + Vector2(10, -700), Vector2(80, 700)), Color(0.2, 0.2, 0.3, 0.85))
		dyn.draw_circle(p + Vector2(0, -1620), 120, Color(0.85, 0.7, 0.55, 0.9))
		if hai.level > 0:
			dyn.draw_string(font, p + Vector2(-60, -1800), "!".repeat(hai.level), HORIZONTAL_ALIGNMENT_LEFT, -1, 120, Color(1, 0.3, 0.2))
