class_name NestView
extends GridView
## Side-on nest renderer: soil, tunnels, chambers, brood, mound, dig dust.

var nest_index := 0
var _dust: Array = []  # [pos, vel, life]


func show_nest(i: int) -> void:
	nest_index = i
	space = AntSim.SPACE_NEST0 + i
	rebind(Game.world.nests[i])


func _ready() -> void:
	super._ready()
	Events.cell_dug.connect(_on_dug)
	Events.collapse.connect(_on_collapse)


func _on_dug(sp: int, p: Vector2) -> void:
	if sp != space:
		return
	for k in 5:
		_dust.append([p, Vector2(randf_range(-12, 12), randf_range(-16, 2)), 0.6])


func _on_collapse(sp: int, p: Vector2, cells: int) -> void:
	if sp != space:
		return
	shake = clampf(0.4 + cells * 0.05, 0.4, 1.5)
	for k in 30:
		_dust.append([p + Vector2(randf_range(-30, 30), randf_range(-8, 8)), Vector2(randf_range(-20, 20), randf_range(-10, 15)), 1.2])


func _process(delta: float) -> void:
	super._process(delta)
	var keep: Array = []
	for d in _dust:
		d[2] -= delta
		d[0] += d[1] * delta
		d[1].y += 30.0 * delta
		if d[2] > 0.0:
			keep.append(d)
	_dust = keep


func _draw_extra(t: float) -> void:
	var w = Game.world
	var g := grid
	var zoom := camera.zoom.x
	# Sky + grass strip above the surface row.
	var width := g.w * g.cell
	var sky_top := -g.h * g.cell * 0.4
	var day := Clock.daylight()
	var sky := Color("#16202e").lerp(Color("#8ec5e8"), day)
	if w.weather.rain > 0.0:
		sky = sky.darkened(0.35)
	dyn.draw_rect(Rect2(Vector2(-width * 0.25, sky_top), Vector2(width * 1.5, -sky_top)), sky)
	dyn.draw_rect(Rect2(Vector2(-width * 0.25, -6.0), Vector2(width * 1.5, 6.0)), Color("#4f7a2c"))
	for k in 140:
		var x := -width * 0.25 + k * width * 1.5 / 140.0
		var hgt := 6.0 + 5.0 * sin(k * 12.9898)
		dyn.draw_line(Vector2(x, -5.0), Vector2(x + sin(t + k) * 1.5, -5.0 - hgt), Color("#5d8f33"), 1.2)
	# Spoil mound at the entrance.
	var ex := (g.entrance_x + 0.5) * g.cell
	var mh := minf(4.0 + sqrt(g.mound) * 1.6, 60.0)
	var mound := PackedVector2Array([Vector2(ex - mh * 2.2, -4), Vector2(ex - 4, -mh), Vector2(ex + 4, -mh), Vector2(ex + mh * 2.2, -4)])
	dyn.draw_colored_polygon(mound, Color("#6b4a2b"))
	dyn.draw_rect(Rect2(Vector2(ex - 2.5, -mh), Vector2(5, mh)), Color("#1b120c"))
	if g.thatch:
		dyn.draw_arc(Vector2(ex, -mh), 18.0, PI, TAU, 16, Color("#c8a050"), 5.0)
	# Chamber labels.
	var cdefs := Data.table("chambers")
	var font := ThemeDB.fallback_font
	var fs := int(clampf(10.0 / zoom * 1.2, 4.0, 40.0))
	for i in g.chambers.size():
		var ch: Dictionary = g.chambers[i]
		if ch["type"] == "none" or ch["cells"].is_empty():
			continue
		var def: Dictionary = cdefs.get(ch["type"], {})
		var c: Vector2 = ch["center"] if ch["open"] > 0 else g.center(ch["cells"][0])
		var label: String = def.get("name", ch["type"])
		if not ch["ok"]:
			label += " (%d/%d)" % [ch["open"], def.get("min_cells", 0)]
		dyn.draw_string(font, c + Vector2(-label.length() * fs * 0.27, -2), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.75))
	# Brood.
	if g.owner >= 0 and g.owner < w.colonies.size():
		var col: Colony = w.colonies[g.owner]
		var k := 0
		for b in col.brood:
			var ci: int = b["chamber"]
			if ci < 0 or ci >= g.chambers.size():
				continue
			var cells: PackedInt32Array = g.chambers[ci]["cells"]
			if cells.is_empty():
				continue
			var cell := cells[(k * 7919) % cells.size()]
			k += 1
			if g.solidity[cell] != 0:
				continue
			var p := g.center(cell) + Vector2(sin(k * 1.3) * 1.2, cos(k * 2.1) * 1.2)
			match b["stage"]:
				Colony.STAGE_EGG:
					dyn.draw_circle(p, 0.7, Color("#f6f1df"))
				Colony.STAGE_LARVA:
					var s := 1.0 + float(b["fed"]) * 0.15
					dyn.draw_circle(p, s, Color("#efe6c8") if b["sick"] < 0.4 else Color("#b8c890"))
					if b["hunger"] > 8.0:
						dyn.draw_circle(p + Vector2(0, -s - 1.0), 0.4, Color(1, 0.3, 0.2))
				Colony.STAGE_PUPA:
					ArtGen._ellipse_draw(dyn, p, Vector2(2.0, 1.1), Color("#e8d4a8") if not b["royal"] else Color("#f0c060"))
	# Dust.
	for d in _dust:
		dyn.draw_circle(d[0], 0.8 + (1.2 - d[2]) * 0.8, Color(0.55, 0.42, 0.3, clampf(d[2], 0.0, 0.8)))
	# Exterminator digging marker.
	if w.house_ai and w.house_ai.ext_phase == "dig" and nest_index == 0:
		var x: float = w.house_ai.ext_dig_x * g.cell
		var depth: float = w.house_ai.ext_dig_depth * g.cell
		dyn.draw_rect(Rect2(Vector2(x - 4.5 * g.cell, 0), Vector2(9 * g.cell, depth)), Color(0.9, 0.2, 0.1, 0.25))
		dyn.draw_line(Vector2(x, depth), Vector2(x, depth - 12), Color(0.8, 0.8, 0.85), 2.0)
