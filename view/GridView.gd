class_name GridView
extends Node2D
## Shared renderer for side-on grids (nests and the house): a data texture drawn by
## grid.gdshader with dirty-rectangle updates, an environment overlay, ants and
## creatures, plus a pannable/zoomable camera.

const OVERLAYS := ["none", "air", "water", "heat", "mould"]

var space := 2
var grid: NestGrid
var camera: Camera2D
var sprite: Sprite2D
var overlay_sprite: Sprite2D
var ants_r: AntRenderer
var overlay := "none"
var _bytes := PackedByteArray()
var _img: Image
var _tex: ImageTexture
var _overlay_img: Image
var _overlay_tex: ImageTexture
var _overlay_timer := 0.0
var _flags_timer := 0.0
var shake := 0.0
var dyn: Node2D  # redrawn every frame
var drag_rect := Rect2i()
var drag_active := false
var hover_cell := -1


func setup(space_id: int, g: NestGrid) -> void:
	space = space_id
	grid = g


func _ready() -> void:
	sprite = Sprite2D.new()
	sprite.centered = false
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/grid.gdshader")
	sprite.material = mat
	add_child(sprite)
	overlay_sprite = Sprite2D.new()
	overlay_sprite.centered = false
	overlay_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	overlay_sprite.visible = false
	add_child(overlay_sprite)
	_build_static()
	ants_r = AntRenderer.new(space)
	add_child(ants_r)
	dyn = Node2D.new()
	dyn.draw.connect(_draw_dynamic)
	add_child(dyn)
	camera = Camera2D.new()
	add_child(camera)
	rebind(grid)


## Point the view at a (possibly different) grid.
func rebind(g: NestGrid) -> void:
	grid = g
	if grid == null:
		return
	ants_r.space = space
	_bytes.resize(grid.w * grid.h * 4)
	_full_redraw()
	var mat := sprite.material as ShaderMaterial
	mat.set_shader_parameter("data", _tex)
	mat.set_shader_parameter("noise_tex", ArtGen.noise_texture())
	mat.set_shader_parameter("grid_size", Vector2(grid.w, grid.h))
	mat.set_shader_parameter("cell_px", 4.0)
	mat.set_shader_parameter("is_house", 1.0 if grid.kind == "house" else 0.0)
	var soils := Data.table("soils")
	var cols: Array = []
	cols.resize(16)
	for k in soils.keys():
		cols[int(soils[k]["index"])] = Color(soils[k]["color"])
	for i in 16:
		if cols[i] == null:
			cols[i] = Color.MAGENTA
	mat.set_shader_parameter("soil_colors", cols)
	mat.set_shader_parameter("chamber_colors", _chamber_palette())
	sprite.scale = Vector2(grid.cell, grid.cell)
	overlay_sprite.scale = Vector2(grid.cell, grid.cell)
	camera.limit_left = int(-grid.w * grid.cell * 0.25)
	camera.limit_right = int(grid.w * grid.cell * 1.25)
	camera.limit_top = int(-grid.h * grid.cell * 0.4)
	camera.limit_bottom = int(grid.h * grid.cell * 1.2)
	focus_default()


func focus_default() -> void:
	camera.position = Vector2(grid.entrance_x * grid.cell, grid.h * grid.cell * 0.18)
	var vp := get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	camera.zoom = Vector2.ONE * clampf(vp.x / (grid.w * grid.cell * 0.55), 0.3, 12.0)


func _chamber_palette() -> Array:
	var out: Array = []
	out.resize(16)
	out[0] = Color(0, 0, 0)
	var cdefs := Data.table("chambers")
	for i in range(1, 16):
		out[i] = Color(0.5, 0.5, 0.5)
	if grid == null:
		return out
	for i in mini(grid.chambers.size(), 15):
		var t: String = grid.chambers[i]["type"]
		out[(i + 1) % 16] = Color(cdefs.get(t, {}).get("color", "#777777"))
	return out


func _build_static() -> void:
	pass


func _cell_bytes(c: int) -> void:
	var o := c * 4
	_bytes[o] = grid.soil_type[c]
	_bytes[o + 1] = grid.solidity[c]
	_bytes[o + 2] = grid.room[c] if grid.kind == "house" else grid.chamber_id[c]
	var fl := grid.dig_mark[c]
	if grid.build[c] == NestGrid.BUILD_SEAL:
		fl |= 2
	if grid.solidity[c] == 0:
		if grid.moisture[c] > 170:
			fl |= 4
		if grid.mould[c] > 70:
			fl |= 8
	_bytes[o + 3] = fl


func _full_redraw() -> void:
	for c in grid.w * grid.h:
		_cell_bytes(c)
	_img = Image.create_from_data(grid.w, grid.h, false, Image.FORMAT_RGBA8, _bytes)
	_tex = ImageTexture.create_from_image(_img)
	sprite.texture = _tex
	grid.has_dirty = false


func _process(delta: float) -> void:
	if grid == null or Game.world == null:
		return
	var changed := false
	if grid.has_dirty:
		var r := grid.dirty_rect.intersection(Rect2i(0, 0, grid.w, grid.h))
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				_cell_bytes(y * grid.w + x)
		grid.has_dirty = false
		changed = true
		(sprite.material as ShaderMaterial).set_shader_parameter("chamber_colors", _chamber_palette())
	_flags_timer -= delta
	if _flags_timer <= 0.0:
		_flags_timer = 0.5
		for c in grid.open_list:
			_cell_bytes(c)
		changed = true
	if changed:
		_img.set_data(grid.w, grid.h, false, Image.FORMAT_RGBA8, _bytes)
		_tex.update(_img)
	(sprite.material as ShaderMaterial).set_shader_parameter("time", Clock.tick * Clock.DT)
	if overlay != "none":
		_overlay_timer -= delta
		if _overlay_timer <= 0.0:
			_overlay_timer = 0.4
			_rebuild_overlay()
	overlay_sprite.visible = overlay != "none"
	if shake > 0.0:
		shake = maxf(shake - delta * 3.0, 0.0)
		camera.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake * 6.0 / camera.zoom.x
	else:
		camera.offset = Vector2.ZERO
	dyn.queue_redraw()


func set_overlay(mode: String) -> void:
	overlay = mode if overlay != mode else "none"
	_overlay_timer = 0.0


func _rebuild_overlay() -> void:
	var bytes := PackedByteArray()
	bytes.resize(grid.w * grid.h * 4)
	for c in grid.open_list:
		var col := Color(0, 0, 0, 0)
		match overlay:
			"air":
				var a := grid.air[c] / 255.0
				col = Color(1.0, 0.25, 0.1, (1.0 - a) * 0.85) if a < 0.75 else Color(0.6, 0.9, 1.0, 0.15)
			"water":
				col = Color(0.2, 0.5, 1.0, clampf(grid.moisture[c] / 200.0, 0.0, 0.9))
			"heat":
				var t := grid.temperature[c]
				var k := clampf((t - 5.0) / 30.0, 0.0, 1.0)
				col = Color(k, 0.3 * (1.0 - absf(k - 0.6)), 1.0 - k, 0.6)
				if t >= 25.0 and t <= 30.0:
					col = Color(0.3, 1.0, 0.3, 0.6)
			"mould":
				col = Color(0.5, 0.9, 0.3, clampf(grid.mould[c] / 160.0, 0.0, 0.9))
		var o := c * 4
		bytes[o] = int(col.r * 255)
		bytes[o + 1] = int(col.g * 255)
		bytes[o + 2] = int(col.b * 255)
		bytes[o + 3] = int(col.a * 255)
	_overlay_img = Image.create_from_data(grid.w, grid.h, false, Image.FORMAT_RGBA8, bytes)
	if _overlay_tex == null or _overlay_tex.get_size() != Vector2(grid.w, grid.h):
		_overlay_tex = ImageTexture.create_from_image(_overlay_img)
	else:
		_overlay_tex.update(_overlay_img)
	overlay_sprite.texture = _overlay_tex


func world_cell(world_pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(world_pos.x / grid.cell)), int(floor(world_pos.y / grid.cell)))


func mouse_world() -> Vector2:
	return get_global_mouse_position()


func _draw_dynamic() -> void:
	var w = Game.world
	if w == null:
		return
	var t := Clock.tick * Clock.DT
	for cr in w.creatures.list:
		if cr["space"] == space:
			var def: Dictionary = w.creatures.defs[cr["kind"]]
			ArtGen.draw_bug(dyn, def, cr["pos"], cr["heading"], cr["size"], t, 0.0)
	if drag_active:
		var r := Rect2(Vector2(drag_rect.position) * grid.cell, Vector2(drag_rect.size) * grid.cell)
		dyn.draw_rect(r, Color(1, 0.85, 0.3, 0.18), true)
		dyn.draw_rect(r, Color(1, 0.85, 0.3, 0.9), false, 1.0 / camera.zoom.x)
	if hover_cell >= 0:
		var p := Vector2(hover_cell % grid.w, hover_cell / grid.w) * grid.cell
		dyn.draw_rect(Rect2(p, Vector2(grid.cell, grid.cell)), Color(1, 1, 1, 0.5), false, 1.0 / camera.zoom.x)
	_draw_extra(t)


func _draw_extra(_t: float) -> void:
	pass
