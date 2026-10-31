class_name SurfaceWorld
extends RefCounted
## Top-down yard: ground grid, collision, shade, objects and food items.
## Grid tile = 25 mm (shared with the surface pheromone grid). Food items for the
## house layer live here too, each with its own per-space lookup grid.

const G_GRASS := 0
const G_DIRT := 1
const G_PAVING := 2
const G_MULCH := 3
const GROUND_SPEED := [0.8, 1.0, 1.25, 0.85]
const GROUND_NAMES := ["grass", "dirt", "paving", "mulch"]

var yard_id := ""
var yard_name := ""
var size := Vector2(20000, 15000)
var cell := 25.0
var inv_cell := 0.04
var w := 0
var h := 0
var ground := PackedByteArray()
var blocked := PackedByteArray()
var shade := PackedByteArray()
var objects: Array = []
var flowers: Array = []
var trees: Array = []
var house_gaps: Array = []
var entrance := Vector2.ZERO
var rival_entrance := Vector2.ZERO
var sprinkler: Dictionary = {}
var seed_value := 0

## Foods: id -> {id, kind, type, pos, amount, max, carry, radius, weight, expires, space, poison}
var foods: Dictionary = {}
var next_food_id := 1
## Per-space food lookup metadata: space -> {cell, w, h}. Space 0 = surface, 1 = house.
var food_maps: Dictionary = {}
var grid_surface := PackedInt32Array()
var grid_house := PackedInt32Array()


func generate(yard: Dictionary, seed_in: int) -> void:
	seed_value = seed_in
	yard_id = yard.get("id", "yard")
	yard_name = yard.get("name", "Backyard")
	var sz: Array = yard.get("size_mm", [20000, 15000])
	size = Vector2(sz[0], sz[1])
	cell = float(Data.table("pheromones").get("surface_cell_mm", 25.0))
	inv_cell = 1.0 / cell
	w = int(ceil(size.x / cell))
	h = int(ceil(size.y / cell))
	ground.resize(w * h)
	blocked.resize(w * h)
	shade.resize(w * h)
	ground.fill(G_GRASS)
	blocked.fill(0)
	shade.fill(0)
	entrance = _v(yard.get("entrance", [size.x * 0.3, size.y * 0.6]))
	rival_entrance = _v(yard.get("rival_entrance", [size.x * 0.7, size.y * 0.75]))
	house_gaps = []
	for g in yard.get("house_gaps", []):
		house_gaps.append(_v(g))
	sprinkler = yard.get("sprinkler", {}).duplicate()
	if sprinkler.has("pos"):
		sprinkler["pos"] = _v(sprinkler["pos"])
	# Ground: noise dirt patches over grass, then authored patches.
	var gn: Dictionary = yard.get("ground_noise", {})
	var noise := FastNoiseLite.new()
	noise.seed = seed_in
	noise.frequency = float(gn.get("frequency", 0.0006)) * cell
	noise.fractal_octaves = 3
	var img := noise.get_image(w, h, false, false, false)
	img.convert(Image.FORMAT_L8)
	var bytes := img.get_data()
	var thr := int(float(gn.get("dirt", 0.62)) * 255.0)
	for i in w * h:
		if bytes[i] > thr:
			ground[i] = G_DIRT
	for p in yard.get("ground_patches", []):
		var r: Array = p["rect"]
		var gt := GROUND_NAMES.find(p["type"])
		_fill_rect(ground, Rect2(r[0], r[1], r[2], r[3]), maxi(gt, 0))
	objects = []
	trees = []
	for o in yard.get("objects", []):
		var obj: Dictionary = o.duplicate(true)
		if obj.has("pos"):
			obj["pos"] = _v(obj["pos"])
		obj["size"] = _v(obj.get("size", [100, 100]))
		if obj.get("shape", "rect") == "line":
			var pts: Array = []
			for q in obj["points"]:
				pts.append(_v(q))
			obj["points"] = pts
		objects.append(obj)
		if obj.get("block", true):
			_raster_object(obj, blocked, 0.0)
		_raster_object(obj, shade, 60.0)
		if obj.has("canopy"):
			trees.append({"pos": obj["pos"], "canopy": float(obj["canopy"])})
			_fill_circle(shade, obj["pos"], float(obj["canopy"]), 1)
	flowers = []
	for f in yard.get("flowers", []):
		flowers.append(_v(f))
	# Keep entrances walkable.
	for e in [entrance, rival_entrance]:
		_fill_circle(blocked, e, 60.0, 0)
	for g in house_gaps:
		_fill_circle(blocked, g + Vector2(0, 20), 40.0, 0)
	food_maps = {}
	_ensure_map(0, w, h, cell)


## Procedural yard for Endless mode (same seed -> same yard).
static func procedural_yard(seed_in: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_in
	var sx := 20000.0
	var sy := 15000.0
	var objs := [{"type": "house_wall", "shape": "rect", "pos": [sx / 2, 600], "size": [sx, 1200], "block": true}]
	var used: Array = []
	var place := func(min_d: float) -> Vector2:
		for attempt in 40:
			var p := Vector2(rng.randf_range(1500, sx - 1500), rng.randf_range(2500, sy - 1200))
			var ok := true
			for u in used:
				if p.distance_to(u) < min_d:
					ok = false
					break
			if ok:
				used.append(p)
				return p
		return Vector2(rng.randf_range(1500, sx - 1500), rng.randf_range(2500, sy - 1200))
	var entrance: Vector2 = place.call(2000.0)
	var rival: Vector2 = place.call(5000.0)
	while rival.distance_to(entrance) < 6000.0:
		rival = Vector2(rng.randf_range(1500, sx - 1500), rng.randf_range(2500, sy - 1200))
	used.append(rival)
	var p: Vector2 = place.call(3000.0)
	objs.append({"type": "shed", "shape": "rect", "pos": [p.x, p.y], "size": [rng.randf_range(2200, 3200), rng.randf_range(2000, 2800)], "block": true})
	for i in rng.randi_range(1, 3):
		p = place.call(1800.0)
		var r := rng.randf_range(200, 320)
		objs.append({"type": "tree", "shape": "circle", "pos": [p.x, p.y], "size": [r, r], "block": true, "canopy": rng.randf_range(2000, 3000)})
	for kind in ["gnome", "bbq", "pot", "watering_can", "chair", "brick", "brick"]:
		p = place.call(900.0)
		var s: float = {"gnome": 160, "bbq": 600, "pot": 260, "watering_can": 300, "chair": 500, "brick": 200}[kind]
		objs.append({"type": kind, "shape": "circle" if kind in ["gnome", "pot", "watering_can"] else "rect", "pos": [p.x, p.y], "size": [s, s * (0.5 if kind == "brick" else 1.0)], "block": true})
	var patches := [{"type": "paving", "rect": [rng.randf_range(2000, 8000), 1200, rng.randf_range(4000, 8000), rng.randf_range(1500, 2600)]}]
	for i in 3:
		patches.append({"type": ["mulch", "dirt"][i % 2], "rect": [rng.randf_range(500, sx - 4000), rng.randf_range(2000, sy - 3000), rng.randf_range(1000, 3500), rng.randf_range(800, 2200)]})
	var flowers := []
	for i in 10:
		flowers.append([rng.randf_range(800, sx - 800), rng.randf_range(1800, sy - 800)])
	var foods := []
	for kind in ["dropped_chip", "dead_fly", "berry", "seed_head"]:
		var a := rng.randf_range(0, TAU)
		var d := rng.randf_range(250, 600)
		foods.append({"food": kind, "pos": [entrance.x + cos(a) * d, entrance.y + sin(a) * d]})
	var gap_x := rng.randf_range(3000, sx - 3000)
	return {
		"id": "endless_%d" % seed_in, "name": "Endless Yard #%d" % seed_in, "size_mm": [sx, sy],
		"entrance": [entrance.x, entrance.y], "rival_entrance": [rival.x, rival.y], "house_gaps": [[gap_x, 1200]],
		"sprinkler": {"pos": [rng.randf_range(4000, sx - 4000), rng.randf_range(4000, sy - 3000)], "radius": rng.randf_range(1800, 2600), "hour": rng.randi_range(5, 8), "hours": 1},
		"ground_noise": {"dirt": rng.randf_range(0.55, 0.68), "frequency": 0.0006},
		"ground_patches": patches, "objects": objs, "flowers": flowers, "scatter": {"pebbles": 900, "grass_clumps": 2500, "leaves": 400}, "foods": foods,
	}


func _v(a) -> Vector2:
	if a is Vector2:
		return a
	return Vector2(float(a[0]), float(a[1]))


func _fill_rect(arr: PackedByteArray, r: Rect2, value: int) -> void:
	var x0 := maxi(int(r.position.x * inv_cell), 0)
	var y0 := maxi(int(r.position.y * inv_cell), 0)
	var x1 := mini(int(r.end.x * inv_cell), w - 1)
	var y1 := mini(int(r.end.y * inv_cell), h - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			arr[y * w + x] = value


func _fill_circle(arr: PackedByteArray, c: Vector2, r: float, value: int) -> void:
	var x0 := maxi(int((c.x - r) * inv_cell), 0)
	var y0 := maxi(int((c.y - r) * inv_cell), 0)
	var x1 := mini(int((c.x + r) * inv_cell), w - 1)
	var y1 := mini(int((c.y + r) * inv_cell), h - 1)
	var r2 := r * r
	for y in range(y0, y1 + 1):
		var dy := (y + 0.5) * cell - c.y
		for x in range(x0, x1 + 1):
			var dx := (x + 0.5) * cell - c.x
			if dx * dx + dy * dy <= r2:
				arr[y * w + x] = value


func _raster_object(o: Dictionary, arr: PackedByteArray, margin: float) -> void:
	var s: Vector2 = o["size"]
	match o.get("shape", "rect"):
		"circle":
			_fill_circle(arr, o["pos"], s.x * 0.5 + margin, 1)
		"line":
			var pts: Array = o["points"]
			for i in pts.size() - 1:
				var a: Vector2 = pts[i]
				var b: Vector2 = pts[i + 1]
				var steps := int(a.distance_to(b) / (cell * 0.5)) + 1
				for k in steps + 1:
					_fill_circle(arr, a.lerp(b, float(k) / steps), s.x * 0.5 + margin, 1)
		_:
			var p: Vector2 = o["pos"]
			_fill_rect(arr, Rect2(p - s * 0.5 - Vector2(margin, margin), s + Vector2(margin, margin) * 2.0), 1)


# ---------------------------------------------------------------- queries

func idx(p: Vector2) -> int:
	var x := int(p.x * inv_cell)
	var y := int(p.y * inv_cell)
	if x < 0 or y < 0 or x >= w or y >= h:
		return -1
	return y * w + x


func is_blocked(x: float, y: float) -> bool:
	var ix := int(x * inv_cell)
	var iy := int(y * inv_cell)
	if ix < 0 or iy < 0 or ix >= w or iy >= h:
		return true
	return blocked[iy * w + ix] != 0


func ground_at(p: Vector2) -> int:
	var i := idx(p)
	return ground[i] if i >= 0 else G_PAVING


func speed_at(x: float, y: float) -> float:
	var ix := int(x * inv_cell)
	var iy := int(y * inv_cell)
	if ix < 0 or iy < 0 or ix >= w or iy >= h:
		return 1.0
	return GROUND_SPEED[ground[iy * w + ix]]


func in_shade(p: Vector2) -> bool:
	var i := idx(p)
	return i >= 0 and shade[i] != 0


func nearest_object(type: String, from: Vector2) -> Dictionary:
	var best := {}
	var bd := INF
	for o in objects:
		if o["type"] == type and o.has("pos"):
			var d: float = from.distance_to(o["pos"])
			if d < bd:
				bd = d
				best = o
	return best


func valid_nest_site(p: Vector2, other_entrances: Array) -> bool:
	if p.x < 300 or p.y < 1500 or p.x > size.x - 300 or p.y > size.y - 300:
		return false
	if ground_at(p) == G_PAVING:
		return false
	for a in range(0, 8):
		var q := p + Vector2(150, 0).rotated(a * TAU / 8.0)
		if is_blocked(q.x, q.y):
			return false
	for e in other_entrances:
		if p.distance_to(e) < 1200.0:
			return false
	return true


# ---------------------------------------------------------------- food

func _ensure_map(space: int, gw: int, gh: int, gcell: float) -> void:
	var g := PackedInt32Array()
	g.resize(gw * gh)
	food_maps[space] = {"cell": gcell, "w": gw, "h": gh}
	if space == 0:
		grid_surface = g
	else:
		grid_house = g


func add_space_map(space: int, gw: int, gh: int, gcell: float) -> void:
	if not food_maps.has(space):
		_ensure_map(space, gw, gh, gcell)


func add_food(kind: String, pos: Vector2, space: int = 0, amount_mult: float = 1.0, tick: int = 0, ticks_per_hour: int = 180) -> int:
	var def: Dictionary = Data.table("foods").get(kind, {})
	if def.is_empty():
		return -1
	var id := next_food_id
	next_food_id += 1
	var amt := float(def.get("amount", 100)) * amount_mult
	foods[id] = {
		"id": id, "kind": kind, "type": def.get("type", "sugar"), "pos": pos,
		"amount": amt, "max": amt, "carry": float(def.get("carry_per_ant", 1)),
		"radius": float(def.get("radius", 10)), "weight": float(def.get("weight", 0)),
		"expires": tick + int(float(def.get("decays_hours", 48)) * ticks_per_hour),
		"space": space, "poison": def.get("type", "") == "poison", "found": false,
	}
	_stamp(foods[id], id)
	return id


func add_carcass(kind: String, pos: Vector2, protein: float, weight: float, space: int, tick: int, tph: int) -> int:
	var id := add_food("carcass", pos, space, 1.0, tick, tph)
	if id < 0:
		return -1
	var f: Dictionary = foods[id]
	f["amount"] = protein
	f["max"] = protein
	f["weight"] = maxf(weight, 1.0)
	f["creature"] = kind
	return id


## Write (value = id) or clear (value = 0) the food's footprint in its space grid.
## Grids are members and written in place (no copy-on-write through a container).
func _stamp(f: Dictionary, value: int) -> void:
	var space: int = f["space"]
	var m: Dictionary = food_maps.get(space, {})
	if m.is_empty():
		return
	var gc: float = m["cell"]
	var gw: int = m["w"]
	var gh: int = m["h"]
	var p: Vector2 = f["pos"]
	var r: float = f["radius"] + gc * 0.5
	var x0 := maxi(int((p.x - r) / gc), 0)
	var y0 := maxi(int((p.y - r) / gc), 0)
	var x1 := mini(int((p.x + r) / gc), gw - 1)
	var y1 := mini(int((p.y + r) / gc), gh - 1)
	var fid: int = f["id"]
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var i := y * gw + x
			if space == 0:
				if value != 0:
					grid_surface[i] = value
				elif grid_surface[i] == fid:
					grid_surface[i] = 0
			else:
				if value != 0:
					grid_house[i] = value
				elif grid_house[i] == fid:
					grid_house[i] = 0


func food_at(space: int, x: float, y: float) -> int:
	if space == 0:
		var ix := int(x * inv_cell)
		var iy := int(y * inv_cell)
		if ix < 0 or iy < 0 or ix >= w or iy >= h:
			return 0
		return grid_surface[iy * w + ix]
	var m: Dictionary = food_maps.get(space, {})
	if m.is_empty():
		return 0
	var gc: float = m["cell"]
	var ix := int(x / gc)
	var iy := int(y / gc)
	var gw: int = m["w"]
	if ix < 0 or iy < 0 or ix >= gw or iy >= int(m["h"]):
		return 0
	return grid_house[iy * gw + ix]


## Take up to `want` from food id; returns amount taken.
func take_food(id: int, want: float) -> float:
	if not foods.has(id):
		return 0.0
	var f: Dictionary = foods[id]
	var got := minf(want, f["amount"])
	f["amount"] -= got
	if f["amount"] <= 0.001:
		remove_food(id)
	return got


func remove_food(id: int) -> void:
	if not foods.has(id):
		return
	_stamp(foods[id], 0)
	foods.erase(id)


func move_food(id: int, to: Vector2) -> void:
	var f: Dictionary = foods[id]
	_stamp(f, 0)
	f["pos"] = to
	_stamp(f, id)


func restamp(space: int) -> void:
	for f in foods.values():
		if f["space"] == space:
			_stamp(f, f["id"])


func expire_foods(tick: int) -> void:
	for id in foods.keys():
		if foods[id]["expires"] < tick:
			remove_food(id)


func foods_in_space(space: int) -> Array:
	var out := []
	for f in foods.values():
		if f["space"] == space:
			out.append(f)
	return out


# ---------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	return {"yard_id": yard_id, "seed": seed_value, "foods": foods, "next_food_id": next_food_id}


## Surface geometry is regenerated from the yard + seed; only dynamic state is saved.
func deserialize(d: Dictionary, yard: Dictionary) -> void:
	generate(yard, int(d["seed"]))
	foods = d["foods"]
	next_food_id = d["next_food_id"]
	for f in foods.values():
		_stamp(f, f["id"])
