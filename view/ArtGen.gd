class_name ArtGen
extends RefCounted
## Procedural art. Ants: a 16x16, 2-frame-per-caste sprite atlas (grey mask,
## tinted in the shader). Creatures and field-guide portraits: vector-drawn from
## the `body` spec in creatures.json (plan, segments, legs, wings, colours).

const ANT_FRAME := 16
const CASTE_ROWS := 8
const PLAN_SHAPES := {"insect": 3, "arachnid": 2, "worm": 12, "myriapod": 10, "snail": 2, "bird": 1, "mammal": 1, "amphibian": 1, "human": 1}

static var _ant_tex: ImageTexture
static var _noise_tex: Texture2D


## Atlas: 2 columns (walk frames) x 8 rows (castes by index). Ant faces +x.
static func ant_atlas() -> ImageTexture:
	if _ant_tex != null:
		return _ant_tex
	var img := Image.create(ANT_FRAME * 2, ANT_FRAME * CASTE_ROWS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	# per caste: head size, thorax, gaster, mandible, wings
	var specs := [
		[2.0, 1.6, 2.6, 1, false],  # worker
		[3.0, 1.8, 2.8, 2, false],  # soldier (big head)
		[1.7, 1.4, 2.2, 1, false],  # scout (slim)
		[1.8, 1.6, 2.9, 1, false],  # nurse
		[3.4, 2.1, 3.0, 2, false],  # major
		[1.5, 1.2, 2.0, 1, false],  # minim
		[2.2, 2.2, 3.6, 1, false],  # queen
		[2.1, 2.0, 3.2, 1, true],   # royal (winged)
	]
	for row in CASTE_ROWS:
		var s: Array = specs[row]
		for frame in 2:
			var ox := frame * ANT_FRAME
			var oy := row * ANT_FRAME
			var cy := oy + 8.0
			var shade := Color(0.95, 0.95, 0.95, 1)
			var dark := Color(0.55, 0.55, 0.55, 1)
			# legs (3 pairs, alternating tripod per frame)
			for k in 3:
				var lx := ox + 6.0 + k * 1.8
				var sw := (1.0 if (k + frame) % 2 == 0 else -1.0) * 1.2
				_line(img, Vector2(lx, cy), Vector2(lx + sw - 1.0, cy - 5.0), dark)
				_line(img, Vector2(lx, cy), Vector2(lx - sw - 1.0, cy + 5.0), dark)
			if s[4]:
				_ellipse(img, Vector2(ox + 6.5, cy - 3.2), Vector2(3.6, 1.6), Color(1, 1, 1, 0.45))
				_ellipse(img, Vector2(ox + 6.5, cy + 3.2), Vector2(3.6, 1.6), Color(1, 1, 1, 0.45))
			_ellipse(img, Vector2(ox + 3.6, cy), Vector2(s[2], s[2] * 0.75), shade)  # gaster
			_ellipse(img, Vector2(ox + 7.6, cy), Vector2(s[1], s[1] * 0.6), shade)   # thorax
			_ellipse(img, Vector2(ox + 10.6, cy), Vector2(s[0] * 0.8, s[0] * 0.72), shade)  # head
			# antennae
			_line(img, Vector2(ox + 11.5, cy - 0.8), Vector2(ox + 14.5, cy - 3.0 + frame * 0.6), dark)
			_line(img, Vector2(ox + 11.5, cy + 0.8), Vector2(ox + 14.5, cy + 3.0 - frame * 0.6), dark)
			# mandibles
			for m in int(s[3]):
				img.set_pixel(ox + 13 + m, int(cy) - 1, dark)
				img.set_pixel(ox + 13 + m, int(cy) + 1, dark)
	_ant_tex = ImageTexture.create_from_image(img)
	return _ant_tex


static func save_atlas(path: String) -> void:
	ant_atlas().get_image().save_png(path)


static func _ellipse(img: Image, c: Vector2, r: Vector2, col: Color) -> void:
	for y in range(int(c.y - r.y - 1), int(c.y + r.y + 2)):
		for x in range(int(c.x - r.x - 1), int(c.x + r.x + 2)):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var d := Vector2((x + 0.5 - c.x) / r.x, (y + 0.5 - c.y) / r.y)
			var l := d.length_squared()
			if l <= 1.0:
				var shade := 1.0 - 0.25 * clampf(d.y + 0.5, 0.0, 1.0) * 0.6 - 0.2 * l
				var cc := col
				cc.r *= shade
				cc.g *= shade
				cc.b *= shade
				var under := img.get_pixel(x, y)
				img.set_pixel(x, y, under.blend(cc))


static func _line(img: Image, a: Vector2, b: Vector2, col: Color) -> void:
	var steps := int(a.distance_to(b) * 2.0) + 1
	for k in steps + 1:
		var p := a.lerp(b, float(k) / steps)
		var x := int(p.x)
		var y := int(p.y)
		if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
			img.set_pixel(x, y, col)


static func noise_texture() -> Texture2D:
	if _noise_tex != null:
		return _noise_tex
	var n := FastNoiseLite.new()
	n.seed = 7
	n.frequency = 0.06
	var img := n.get_seamless_image(128, 128)
	_noise_tex = ImageTexture.create_from_image(img)
	return _noise_tex


# ---------------------------------------------------------------- creatures

## Draw a creature on `ci` (a CanvasItem inside its _draw). size_px = body length in
## canvas units; t = animation time; attack in 0..1 lunges forward.
static func draw_bug(ci: CanvasItem, def: Dictionary, pos: Vector2, heading: float, size_px: float, t: float, attack: float = 0.0, alpha: float = 1.0, tame: bool = false) -> void:
	var body: Dictionary = def.get("body", {})
	var plan: String = body.get("plan", "insect")
	var col := Color(body.get("color", "#553322"))
	var acc := Color(body.get("accent", "#221100"))
	col.a = alpha
	acc.a = alpha
	var L := size_px * float(body.get("length", 1.0))
	var W := size_px * 0.42 * float(body.get("width", 0.8))
	var fwd := Vector2(cos(heading), sin(heading))
	var side := fwd.orthogonal()
	var lunge := fwd * attack * L * 0.15
	var p := pos + lunge
	match plan:
		"worm", "myriapod":
			var segs := int(body.get("segments", 10))
			var legs := int(body.get("legs", 0))
			var sw := sin(t * 3.0)
			for k in segs:
				var f := float(k) / maxf(segs - 1, 1)
				var wob := side * sin(t * 4.0 + f * 6.0) * W * 0.35
				var c := p + fwd * (0.5 - f) * L + wob
				var r := W * (0.55 - 0.15 * absf(f - 0.3))
				if legs > 0:
					var lp := sin(t * 14.0 + k) * W * 0.3
					ci.draw_line(c, c + side * W * 0.9 + fwd * lp, acc, maxf(size_px * 0.02, 1.0))
					ci.draw_line(c, c - side * W * 0.9 - fwd * lp, acc, maxf(size_px * 0.02, 1.0))
				ci.draw_circle(c, r, col.lerp(acc, 0.25 * (k % 2)))
			if body.get("antennae", false):
				var head := p + fwd * 0.5 * L
				ci.draw_line(head, head + (fwd + side * 0.5) * W, acc, maxf(size_px * 0.02, 1.0))
				ci.draw_line(head, head + (fwd - side * 0.5) * W, acc, maxf(size_px * 0.02, 1.0))
			return
		"snail":
			ci.draw_set_transform(p, heading, Vector2.ONE)
			_ellipse_draw(ci, Vector2(0, 0), Vector2(L * 0.55, W * 0.45), col)
			ci.draw_line(Vector2(L * 0.45, 0), Vector2(L * 0.62, -W * 0.3), col, maxf(size_px * 0.03, 1.0))
			ci.draw_line(Vector2(L * 0.45, 0), Vector2(L * 0.62, W * 0.3), col, maxf(size_px * 0.03, 1.0))
			if body.get("shell", true):
				ci.draw_circle(Vector2(-L * 0.05, 0), W * 0.75, acc)
				ci.draw_arc(Vector2(-L * 0.05, 0), W * 0.5, 0, TAU * 0.8, 16, col.lightened(0.2), maxf(size_px * 0.03, 1.0))
				ci.draw_arc(Vector2(-L * 0.05, 0), W * 0.25, 0, TAU * 0.8, 12, col.lightened(0.2), maxf(size_px * 0.03, 1.0))
			ci.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
			return
		"bird":
			ci.draw_set_transform(p, heading, Vector2.ONE)
			var flap := sin(t * 10.0) * 0.4
			var wing := PackedVector2Array([Vector2(L * 0.1, 0), Vector2(-L * 0.2, L * (0.6 + flap)), Vector2(-L * 0.35, L * (0.55 + flap)), Vector2(-L * 0.15, 0)])
			ci.draw_colored_polygon(wing, acc)
			var wing2 := PackedVector2Array()
			for v in wing:
				wing2.append(Vector2(v.x, -v.y))
			ci.draw_colored_polygon(wing2, acc)
			_ellipse_draw(ci, Vector2.ZERO, Vector2(L * 0.4, W * 0.5), col)
			ci.draw_circle(Vector2(L * 0.38, 0), W * 0.35, col)
			ci.draw_colored_polygon(PackedVector2Array([Vector2(L * 0.55, -W * 0.08), Vector2(L * 0.7, 0), Vector2(L * 0.55, W * 0.08)]), Color(0.9, 0.7, 0.2, alpha))
			ci.draw_colored_polygon(PackedVector2Array([Vector2(-L * 0.35, 0), Vector2(-L * 0.6, -W * 0.3), Vector2(-L * 0.6, W * 0.3)]), acc)
			ci.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
			return
		"mammal", "amphibian", "human":
			ci.draw_set_transform(p, heading, Vector2.ONE)
			var step := sin(t * 8.0) * W * 0.25
			for k in 4:
				var lx := (0.25 if k < 2 else -0.25) * L
				var ly := (1 if k % 2 == 0 else -1) * W * 0.55
				ci.draw_circle(Vector2(lx + step * (1 if k % 3 == 0 else -1), ly), W * 0.22, acc)
			_ellipse_draw(ci, Vector2.ZERO, Vector2(L * 0.42, W * 0.55), col)
			ci.draw_circle(Vector2(L * 0.45, 0), W * 0.45, col)
			if plan == "mammal":
				ci.draw_colored_polygon(PackedVector2Array([Vector2(L * 0.4, -W * 0.3), Vector2(L * 0.38, -W * 0.65), Vector2(L * 0.52, -W * 0.38)]), acc)
				ci.draw_colored_polygon(PackedVector2Array([Vector2(L * 0.4, W * 0.3), Vector2(L * 0.38, W * 0.65), Vector2(L * 0.52, W * 0.38)]), acc)
				ci.draw_line(Vector2(-L * 0.4, 0), Vector2(-L * 0.75, sin(t * 2.0) * W * 0.5), col, W * 0.18)
			ci.draw_circle(Vector2(L * 0.55, -W * 0.15), W * 0.07, Color(0, 0, 0, alpha))
			ci.draw_circle(Vector2(L * 0.55, W * 0.15), W * 0.07, Color(0, 0, 0, alpha))
			ci.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
			return
	# insect / arachnid
	var segs := clampi(int(body.get("segments", 3)), 1, 4)
	var legs := int(body.get("legs", 6))
	var wings := int(body.get("wings", 0))
	ci.draw_set_transform(p, heading, Vector2.ONE)
	var lw := maxf(size_px * 0.035, 1.0)
	var pairs := legs / 2
	for k in pairs:
		var f := (float(k) / maxf(pairs - 1, 1) - 0.5)
		var phase := sin(t * 16.0 + k * 2.1) * W * 0.3
		var root := Vector2(-f * L * 0.2, 0)
		var reach := W * (1.6 if plan == "arachnid" else 1.25)
		ci.draw_polyline(PackedVector2Array([root, root + Vector2(-f * L * 0.25 + phase, -reach * 0.6), root + Vector2(-f * L * 0.5 + phase, -reach)]), acc, lw)
		ci.draw_polyline(PackedVector2Array([root, root + Vector2(-f * L * 0.25 - phase, reach * 0.6), root + Vector2(-f * L * 0.5 - phase, reach)]), acc, lw)
	if wings > 0:
		var flutter := 1.0 + sin(t * 30.0) * 0.15 if def.get("behaviour", "") == "ambient_flyer" else 1.0
		var wc := Color(0.9, 0.95, 1.0, 0.45 * alpha)
		if body.get("shell", false):
			wc = col.darkened(0.1)
		_ellipse_draw(ci, Vector2(-L * 0.15, -W * 0.55 * flutter), Vector2(L * 0.35, W * 0.45 * flutter), wc)
		_ellipse_draw(ci, Vector2(-L * 0.15, W * 0.55 * flutter), Vector2(L * 0.35, W * 0.45 * flutter), wc)
	var parts: Array = []
	match segs:
		1: parts = [[0.0, 0.5, 0.9]]
		2: parts = [[-0.18, 0.34, 1.0], [0.24, 0.2, 0.75]]
		3: parts = [[-0.25, 0.28, 0.95], [0.05, 0.16, 0.6], [0.32, 0.14, 0.7]]
		_: parts = [[-0.3, 0.22, 0.9], [-0.05, 0.14, 0.7], [0.15, 0.12, 0.6], [0.36, 0.12, 0.65]]
	for k in parts.size():
		var pt: Array = parts[k]
		var c := col if k != parts.size() - 1 else col.darkened(0.15)
		_ellipse_draw(ci, Vector2(pt[0] * L, 0), Vector2(pt[1] * L, W * pt[2] * 0.6), c)
	if body.get("shell", false) and wings == 0:
		ci.draw_line(Vector2(-L * 0.5, 0), Vector2(L * 0.05, 0), acc, lw)
	var spots := int(body.get("spots", 0))
	for k in spots:
		var a := float(k) * 2.4
		ci.draw_circle(Vector2(-L * 0.25 + cos(a) * L * 0.15, sin(a) * W * 0.35), W * 0.09, acc)
	if body.get("antennae", false):
		var hx: float = parts[parts.size() - 1][0] * L + L * 0.06
		ci.draw_line(Vector2(hx, -W * 0.1), Vector2(hx + L * 0.25, -W * 0.5), acc, lw)
		ci.draw_line(Vector2(hx, W * 0.1), Vector2(hx + L * 0.25, W * 0.5), acc, lw)
	if tame:
		# Champion ant riding on top.
		_ellipse_draw(ci, Vector2(-L * 0.05, 0), Vector2(W * 0.3, W * 0.18), Color(0.2, 0.1, 0.05, alpha))
		ci.draw_circle(Vector2(W * 0.2, 0), W * 0.13, Color(0.25, 0.12, 0.05, alpha))
	ci.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)


static func _ellipse_draw(ci: CanvasItem, c: Vector2, r: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	for k in 18:
		var a := k * TAU / 18.0
		pts.append(c + Vector2(cos(a) * r.x, sin(a) * r.y))
	ci.draw_colored_polygon(pts, col)


## Draw a food item.
static func draw_food(ci: CanvasItem, f: Dictionary, size_mult: float = 1.0) -> void:
	var def: Dictionary = Data.table("foods").get(f["kind"], {})
	var col := Color(def.get("color", "#e0c060"))
	var r: float = f["radius"] * size_mult * clampf(0.4 + 0.6 * f["amount"] / maxf(f["max"], 1.0), 0.35, 1.0)
	var p: Vector2 = f["pos"]
	if f.get("creature", "") != "":
		var cdef: Dictionary = Data.table("creatures").get(f["creature"], {})
		if not cdef.is_empty():
			draw_bug(ci, cdef, p, 0.6 + f["id"], maxf(float(cdef.get("size", 10)), 6.0), 0.0, 0.0, 0.85)
			return
	match f["type"]:
		"poison":
			ci.draw_rect(Rect2(p - Vector2(r, r * 0.6), Vector2(r * 2, r * 1.2)), Color("#3060a0"))
			ci.draw_circle(p, r * 0.45, col)
		"water":
			ci.draw_circle(p, r, Color(col, 0.7))
			ci.draw_circle(p - Vector2(r, r) * 0.3, r * 0.25, Color(1, 1, 1, 0.7))
		"leaf":
			ci.draw_set_transform(p, f["id"] * 1.7, Vector2.ONE)
			_ellipse_draw(ci, Vector2.ZERO, Vector2(r, r * 0.5), col)
			ci.draw_line(Vector2(-r, 0), Vector2(r, 0), col.darkened(0.3), maxf(r * 0.08, 1.0))
			ci.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
		_:
			var n := 7
			var pts := PackedVector2Array()
			for k in n:
				var a: float = k * TAU / n + f["id"]
				pts.append(p + Vector2(cos(a), sin(a)) * r * (0.75 + 0.25 * sin(k * 3.7 + f["id"])))
			ci.draw_colored_polygon(pts, col)
			ci.draw_circle(p - Vector2(r, r) * 0.25, r * 0.25, col.lightened(0.35))
