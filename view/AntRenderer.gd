class_name AntRenderer
extends MultiMeshInstance2D
## Batches every ant of one space into a single MultiMesh. The buffer is rebuilt
## once per sim tick; per-frame interpolation happens in the shader.
## When zoomed out past `lod_zoom`, ants are hidden and a density map is drawn instead.

const FLOATS := 16

var space := 0
var lod_zoom := 0.35
var _buf := PackedFloat32Array()
var _last_tick := -1
var _cap := 0
var _density: Sprite2D
var _density_img: Image
var _density_tex: ImageTexture
var _density_cell := 200.0
var lod_active := false
var count := 0


func _init(space_id: int = 0) -> void:
	space = space_id


func _ready() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	mm.mesh = quad
	multimesh = mm
	texture = ArtGen.ant_atlas()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/ants.gdshader")
	mat.set_shader_parameter("atlas", ArtGen.ant_atlas())
	var sizes := PackedFloat32Array()
	var castes := Data.table("castes")
	sizes.resize(8)
	for k in castes.keys():
		if not String(k).begins_with("_"):
			sizes[int(castes[k]["index"])] = float(castes[k].get("size", 5.0))
	mat.set_shader_parameter("sizes", sizes)
	var tints: Array = []
	for f in 2:
		for c in 8:
			var base := Color("#2a1a12")
			for k in castes.keys():
				if not String(k).begins_with("_") and int(castes[k]["index"]) == c:
					base = Color(castes[k].get("color", "#2a1a12"))
			if f == 1:
				base = Color("#b8321e").lerp(base, 0.25)
			tints.append(base.lightened(0.15))
	mat.set_shader_parameter("tints", tints)
	material = mat
	_density = Sprite2D.new()
	_density.centered = false
	_density.visible = false
	_density.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_density)


func _process(_delta: float) -> void:
	var w = Game.world
	if w == null:
		return
	var mat := material as ShaderMaterial
	mat.set_shader_parameter("alpha", Clock.alpha if Clock.running else 1.0)
	mat.set_shader_parameter("anim_time", Clock.tick * Clock.DT)
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam else 1.0
	lod_active = zoom < lod_zoom and space == AntSim.SPACE_SURFACE
	mat.set_shader_parameter("px_scale", 1.0 if zoom > 2.0 else 1.0 + (2.0 - zoom) * 0.5)
	if Clock.tick != _last_tick or not Clock.running:
		_last_tick = Clock.tick
		if lod_active:
			_rebuild_density(w)
			multimesh.visible_instance_count = 0
		else:
			_rebuild(w)
	_density.visible = lod_active


func _rebuild(w) -> void:
	var ants: AntSim = w.ants
	var n := ants.n
	if n > _cap:
		_cap = maxi(n, maxi(_cap * 2, 256))
		multimesh.instance_count = _cap
		_buf.resize(_cap * FLOATS)
	var k := 0
	var want_layer := 1 if space == AntSim.SPACE_SURFACE else (2 if space == AntSim.SPACE_HOUSE else 0)
	var want_inside := space - AntSim.SPACE_NEST0
	var colors: Array = AntSim.ITEM_COLORS
	for i in n:
		if ants.state[i] == AntSim.DEAD or ants.layer[i] != want_layer:
			continue
		if want_layer == 0 and ants.inside[i] != want_inside:
			continue
		var p := ants.pos[i]
		var d := p - ants.prev[i]
		if d.length_squared() > 400.0:
			d = Vector2.ZERO  # teleported (layer change): don't smear
		var o := k * FLOATS
		_buf[o] = 1.0
		_buf[o + 1] = 0.0
		_buf[o + 2] = 0.0
		_buf[o + 3] = p.x
		_buf[o + 4] = 0.0
		_buf[o + 5] = 1.0
		_buf[o + 6] = 0.0
		_buf[o + 7] = p.y
		var cc: Color = colors[ants.carry[i]]
		if ants.carry_amt[i] < 0.0:
			cc = Color(0, 0, 0, 0)
		_buf[o + 8] = cc.r
		_buf[o + 9] = cc.g
		_buf[o + 10] = cc.b
		_buf[o + 11] = cc.a
		_buf[o + 12] = float(ants.caste[i] + 8 * mini(ants.faction[i], 1))
		_buf[o + 13] = ants.heading[i]
		_buf[o + 14] = d.x
		_buf[o + 15] = d.y
		k += 1
	count = k
	if k > 0:
		multimesh.buffer = _buf
	multimesh.visible_instance_count = k


func _rebuild_density(w) -> void:
	var s: SurfaceWorld = w.surface
	var dw := int(ceil(s.size.x / _density_cell))
	var dh := int(ceil(s.size.y / _density_cell))
	var counts := PackedInt32Array()
	counts.resize(dw * dh * 2)
	var ants: AntSim = w.ants
	var k := 0
	for i in ants.n:
		if ants.state[i] == AntSim.DEAD or ants.layer[i] != 1:
			continue
		var p := ants.pos[i]
		var x := clampi(int(p.x / _density_cell), 0, dw - 1)
		var y := clampi(int(p.y / _density_cell), 0, dh - 1)
		counts[(y * dw + x) * 2 + mini(ants.faction[i], 1)] += 1
		k += 1
	count = k
	var bytes := PackedByteArray()
	bytes.resize(dw * dh * 4)
	for c in dw * dh:
		var mine := counts[c * 2]
		var theirs := counts[c * 2 + 1]
		var tot := mine + theirs
		if tot == 0:
			continue
		var a := clampf(0.35 + tot * 0.08, 0.0, 0.95)
		var col := Color(0.12, 0.06, 0.03) if mine >= theirs else Color(0.75, 0.15, 0.08)
		bytes[c * 4] = int(col.r * 255)
		bytes[c * 4 + 1] = int(col.g * 255)
		bytes[c * 4 + 2] = int(col.b * 255)
		bytes[c * 4 + 3] = int(a * 255)
	_density_img = Image.create_from_data(dw, dh, false, Image.FORMAT_RGBA8, bytes)
	if _density_tex == null or _density_tex.get_size() != Vector2(dw, dh):
		_density_tex = ImageTexture.create_from_image(_density_img)
	else:
		_density_tex.update(_density_img)
	_density.texture = _density_tex
	_density.scale = Vector2(_density_cell, _density_cell)
