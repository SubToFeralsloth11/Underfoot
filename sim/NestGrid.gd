class_name NestGrid
extends RefCounted
## Side-on cell grid used for nests (diggable soil) and the house cross-section.
## Per-cell packed arrays; solidity 0 = open, 255 = intact.

const INF := 1 << 30
const BUILD_NONE := 0
const BUILD_SEAL := 2

var kind := "nest"
var w := 0
var h := 0
var cell := 4.0
var soil_type := PackedByteArray()
var solidity := PackedByteArray()
var moisture := PackedFloat32Array()
var air := PackedFloat32Array()
var mould := PackedFloat32Array()
var chamber_id := PackedByteArray()
var dig_mark := PackedByteArray()
var build := PackedByteArray()
var temperature := PackedFloat32Array()
var occupancy := PackedByteArray()
var room := PackedByteArray()  # house: index into room_names + 1

var open_list := PackedInt32Array()
var chambers: Array = []  # {type, cells: PackedInt32Array, open: int, center: Vector2, ok: bool, corpses: int}
var room_names: PackedStringArray = []
var entrance_x := 0
var entrance_cells := PackedInt32Array()
var mound := 0.0
var marks := 0
var thatch := false
var owner := 0  # colony index
var surface_pos := Vector2.ZERO  # entrance position on the surface layer

var fields: Dictionary = {}
var field_dirty: Dictionary = {}
var dirty_rect := Rect2i()
var has_dirty := true
var open_changed := true
var _soils: Array = []  # index -> soil dict
var _soil_idx: Dictionary = {}
var _cfg: Dictionary = {}
var _min_open_row := 0
var _max_open_row := 0


func _init() -> void:
	_cfg = Data.table("nest")
	var soils := Data.table("soils")
	_soils.resize(soils.size())
	for id in soils.keys():
		var s: Dictionary = soils[id].duplicate()
		s["id"] = id
		_soils[int(s["index"])] = s
		_soil_idx[id] = int(s["index"])


func soil(c: int) -> Dictionary:
	return _soils[soil_type[c]]


func soil_id_index(id: String) -> int:
	return _soil_idx.get(id, 2)


## Change the soil of a cell (scenario setup and tests).
func set_soil(c: int, soil_name: String) -> void:
	soil_type[c] = soil_id_index(soil_name)
	mark_dirty(c)


func _alloc(width: int, height: int) -> void:
	w = width
	h = height
	var n := w * h
	for arr_name in ["soil_type", "solidity", "chamber_id", "dig_mark", "build", "occupancy", "room"]:
		var a := PackedByteArray()
		a.resize(n)
		set(arr_name, a)
	for arr_name in ["moisture", "air", "mould", "temperature"]:
		var f := PackedFloat32Array()
		f.resize(n)
		set(arr_name, f)
	temperature.fill(float(_cfg.get("env", {}).get("deep_temp", 14.0)))
	air.fill(255.0)
	solidity.fill(255)


# ---------------------------------------------------------------- generation

func generate_nest(rng: RandomNumberGenerator, size: Vector2i) -> void:
	kind = "nest"
	cell = float(_cfg.get("cell_mm", 4.0))
	_alloc(size.x, size.y)
	var layers: Array = _cfg["layers"]
	for y in h:
		var f := float(y) / h
		var si := soil_id_index("bedrock")
		for l in layers:
			if f < float(l["to"]):
				si = soil_id_index(l["soil"])
				break
		# Wobble layer boundaries a little per column via row fill then noise pass below.
		for x in w:
			soil_type[y * w + x] = si
	var noise := FastNoiseLite.new()
	noise.seed = rng.randi()
	noise.frequency = 0.08
	# Perturb boundaries: swap with the soil a few rows above/below.
	for y in range(1, h - 1):
		for x in w:
			var n := noise.get_noise_2d(x, y)
			if n > 0.45:
				soil_type[y * w + x] = soil_type[mini(y + 2, h - 1) * w + x]
			elif n < -0.45:
				soil_type[y * w + x] = soil_type[maxi(y - 2, 0) * w + x]
	var lens: Dictionary = _cfg["sand_lenses"]
	for i in int(lens["count"]):
		var r := rng.randi_range(int(lens["radius"][0]), int(lens["radius"][1]))
		var cx := rng.randi_range(0, w - 1)
		var cy := rng.randi_range(int(float(lens["from"]) * h), int(float(lens["to"]) * h))
		_blob(cx, cy, r * 2, r, soil_id_index("sand"), rng)
	var st: Dictionary = _cfg["stones"]
	for i in int(st["count"]):
		var r := rng.randi_range(int(st["radius"][0]), int(st["radius"][1]))
		_blob(rng.randi_range(0, w - 1), rng.randi_range(int(h * 0.1), h - 1), r, r, soil_id_index("stone"), rng)
	var rt: Dictionary = _cfg["roots"]
	for i in int(rt["count"]):
		var x := float(rng.randi_range(0, w - 1))
		var y := 0.0
		var length := rng.randi_range(int(rt["length"][0]), int(rt["length"][1]))
		var dir := rng.randf_range(-0.6, 0.6)
		for s in length:
			var ix := int(x)
			var iy := int(y)
			if ix >= 0 and ix < w and iy >= 0 and iy < int(h * float(rt["max_depth"])):
				soil_type[iy * w + ix] = soil_id_index("root")
			x += sin(dir)
			y += cos(dir) * 0.8 + 0.3
			dir += rng.randf_range(-0.35, 0.35)
	entrance_x = int(w * float(_cfg.get("entrance_x_frac", 0.5)))
	var starter: Dictionary = _cfg["starter"]
	var depth := int(starter["shaft_depth"])
	var cav: Array = starter["cavity"]
	# Keep the starter area free of stones/sand so it never collapses at once.
	for y in range(0, depth + int(cav[1]) + 2):
		for x in range(entrance_x - int(cav[0]) / 2 - 2, entrance_x + int(cav[0]) / 2 + 3):
			if x >= 0 and x < w:
				var c := y * w + x
				var sid := soil_type[c]
				if sid == soil_id_index("sand") or sid == soil_id_index("stone"):
					soil_type[c] = soil_id_index("loam" if y > 2 else "topsoil")
	for y in depth:
		_open_now(y * w + entrance_x)
	for y in range(depth, depth + int(cav[1])):
		for x in range(entrance_x - int(cav[0]) / 2, entrance_x + int(cav[0]) / 2):
			_open_now(y * w + x)
	_init_temperatures()
	rebuild_open_list()
	var cells := PackedInt32Array()
	for y in range(depth, depth + int(cav[1])):
		for x in range(entrance_x - int(cav[0]) / 2, entrance_x + int(cav[0]) / 2):
			cells.append(y * w + x)
	assign_chamber(cells, "queen")


func _blob(cx: int, cy: int, rx: int, ry: int, sid: int, rng: RandomNumberGenerator) -> void:
	for y in range(cy - ry, cy + ry + 1):
		for x in range(cx - rx, cx + rx + 1):
			if x < 0 or y < 1 or x >= w or y >= h:
				continue
			var dx := float(x - cx) / maxf(rx, 1)
			var dy := float(y - cy) / maxf(ry, 1)
			if dx * dx + dy * dy <= 1.0 + rng.randf_range(-0.15, 0.15):
				var cur := soil_type[y * w + x]
				if cur != soil_id_index("bedrock"):
					soil_type[y * w + x] = sid


func generate_house(cfg: Dictionary) -> void:
	kind = "house"
	cell = float(cfg.get("cell_mm", 25.0))
	var size: Array = cfg["size"]
	_alloc(int(size[0]), int(size[1]))
	var fill := soil_id_index(cfg.get("fill_soil", "wall"))
	var border := soil_id_index(cfg.get("border_soil", "brick"))
	var b := int(cfg.get("border", 3))
	for y in h:
		for x in w:
			soil_type[y * w + x] = border if (x < b or y < b or x >= w - b or y >= h - b) else fill
	room_names = PackedStringArray(["none"])
	for o in cfg["open"]:
		var r: Array = o["rect"]
		var rname: String = o.get("room", "")
		var ri := room_names.find(rname)
		if ri < 0:
			room_names.append(rname)
			ri = room_names.size() - 1
		for y in range(int(r[1]), int(r[1]) + int(r[3])):
			for x in range(int(r[0]), int(r[0]) + int(r[2])):
				if x >= 0 and y >= 0 and x < w and y < h:
					var c := y * w + x
					solidity[c] = 0
					soil_type[c] = 0
					room[c] = ri
	for s in cfg["solid"]:
		var r: Array = s["rect"]
		var sid := soil_id_index(s.get("soil", "timber"))
		for y in range(int(r[1]), int(r[1]) + int(r[3])):
			for x in range(int(r[0]), int(r[0]) + int(r[2])):
				if x >= 0 and y >= 0 and x < w and y < h:
					solidity[y * w + x] = 255
					soil_type[y * w + x] = sid
	var ec: Array = cfg["entrance_cell"]
	entrance_x = int(ec[0])
	entrance_cells = PackedInt32Array([int(ec[1]) * w + int(ec[0])])
	temperature.fill(20.0)
	rebuild_open_list()


func room_at(c: int) -> String:
	if c < 0 or c >= room.size():
		return ""
	return room_names[room[c]] if room[c] < room_names.size() else ""


func _init_temperatures() -> void:
	var env: Dictionary = _cfg.get("env", {})
	var deep := float(env.get("deep_temp", 14.0))
	for i in w * h:
		temperature[i] = deep


# ---------------------------------------------------------------- queries

func idx(x: int, y: int) -> int:
	return y * w + x


func cell_at(p: Vector2) -> int:
	var x := int(p.x / cell)
	var y := int(p.y / cell)
	if x < 0 or y < 0 or x >= w or y >= h:
		return -1
	return y * w + x


func center(c: int) -> Vector2:
	return Vector2((c % w + 0.5) * cell, (c / w + 0.5) * cell)


func occupy(c: int) -> void:
	if occupancy[c] < 255:
		occupancy[c] += 1


func clear_occupancy() -> void:
	occupancy.fill(0)


func is_open(c: int) -> bool:
	return c >= 0 and solidity[c] == 0


func passable(p: Vector2) -> bool:
	var c := cell_at(p)
	return c >= 0 and solidity[c] == 0


func depth_mm(c: int) -> float:
	return (c / w + 0.5) * cell


func size_mm() -> Vector2:
	return Vector2(w * cell, h * cell)


func mark_dirty(c: int) -> void:
	var p := Vector2i(c % w, c / w)
	if not has_dirty:
		dirty_rect = Rect2i(p, Vector2i.ONE)
		has_dirty = true
	else:
		dirty_rect = dirty_rect.expand(p).expand(p + Vector2i.ONE)


func mark_all_dirty() -> void:
	dirty_rect = Rect2i(0, 0, w, h)
	has_dirty = true


# ---------------------------------------------------------------- digging

func can_dig(c: int) -> bool:
	return c >= 0 and solidity[c] > 0 and bool(_soils[soil_type[c]].get("diggable", false))


func set_mark(c: int, on: bool) -> void:
	if c < 0:
		return
	if on and can_dig(c) and dig_mark[c] == 0:
		dig_mark[c] = 1
		marks += 1
		mark_dirty(c)
		field_dirty["dig"] = true
	elif not on and dig_mark[c] == 1:
		dig_mark[c] = 0
		marks -= 1
		mark_dirty(c)
		field_dirty["dig"] = true


func mark_rect(a: Vector2i, b: Vector2i, on: bool) -> int:
	var n := 0
	for y in range(maxi(mini(a.y, b.y), 0), mini(maxi(a.y, b.y) + 1, h)):
		for x in range(maxi(mini(a.x, b.x), 0), mini(maxi(a.x, b.x) + 1, w)):
			var c := y * w + x
			var before := dig_mark[c]
			set_mark(c, on)
			if dig_mark[c] != before:
				n += 1
	return n


## Mark a straight shaft from c up to the surface (vent).
func mark_vent(c: int) -> void:
	var x := c % w
	for y in range(c / w, -1, -1):
		set_mark(y * w + x, true)


## Seconds of work for one ant with dig skill 1.0.
func dig_seconds(c: int) -> float:
	return float(_soils[soil_type[c]].get("dig_time", 1.0)) * float(_cfg.get("dig_time_scale", 2.0))


## Apply digging work; returns true if the cell opened.
func dig(c: int, skill_seconds: float) -> bool:
	if solidity[c] == 0:
		return false
	var t := dig_seconds(c)
	if t <= 0.0:
		return false
	var dmg := int(ceil(255.0 * skill_seconds / t))
	if solidity[c] <= dmg:
		_open_now(c)
		if dig_mark[c] == 1:
			dig_mark[c] = 0
			marks -= 1
		rebuild_open_list_add(c)
		return true
	solidity[c] -= dmg
	return false


func _open_now(c: int) -> void:
	solidity[c] = 0
	if soil_type[c] == soil_id_index("seal"):
		soil_type[c] = soil_id_index("loam")
	build[c] = BUILD_NONE
	mark_dirty(c)


func rebuild_open_list_add(c: int) -> void:
	open_list.append(c)
	var row := c / w
	_min_open_row = mini(_min_open_row, row)
	_max_open_row = maxi(_max_open_row, row)
	open_changed = true
	_invalidate_fields()
	var cid := chamber_id[c]
	if cid > 0:
		_recount_chamber(cid - 1)


## Fill an open cell with soil (collapse, worm, pillar). Returns true if it was open.
func fill(c: int, soil_name: String) -> bool:
	if c < 0 or solidity[c] != 0:
		return false
	solidity[c] = 255
	soil_type[c] = soil_id_index(soil_name)
	moisture[c] = 0.0
	build[c] = BUILD_NONE
	mark_dirty(c)
	open_changed = true
	rebuild_open_list()
	_invalidate_fields()
	var cid := chamber_id[c]
	if cid > 0:
		_recount_chamber(cid - 1)
	return true


## Force a cell open with no spoil (exterminator digging).
func excavate(c: int) -> void:
	if c < 0 or solidity[c] == 0:
		return
	_open_now(c)
	if dig_mark[c] == 1:
		dig_mark[c] = 0
		marks -= 1
	rebuild_open_list_add(c)


func place_seal(c: int) -> bool:
	if c < 0 or solidity[c] != 0:
		return false
	build[c] = BUILD_SEAL
	soil_type[c] = soil_id_index("seal")
	mark_dirty(c)
	return true


func rebuild_open_list() -> void:
	open_list = PackedInt32Array()
	_min_open_row = h
	_max_open_row = 0
	for c in w * h:
		if solidity[c] == 0:
			open_list.append(c)
			var row := c / w
			if row < _min_open_row: _min_open_row = row
			if row > _max_open_row: _max_open_row = row
	open_changed = true


func _invalidate_fields() -> void:
	for key in fields.keys():
		field_dirty[key] = true
	field_dirty["exit"] = true
	field_dirty["dig"] = true


# ---------------------------------------------------------------- chambers

func assign_chamber(cells: PackedInt32Array, type: String) -> int:
	var id := chambers.size()
	if id >= 254:
		return -1
	var ch := {"type": type, "cells": PackedInt32Array(), "open": 0, "center": Vector2.ZERO, "ok": false, "corpses": 0}
	chambers.append(ch)
	for c in cells:
		if c < 0 or c >= w * h:
			continue
		var s: Dictionary = _soils[soil_type[c]]
		if solidity[c] > 0 and not bool(s.get("diggable", false)):
			continue
		var old := chamber_id[c]
		if old > 0 and old - 1 != id:
			var oc: Dictionary = chambers[old - 1]
			var arr: PackedInt32Array = oc["cells"]
			var at := arr.find(c)
			if at >= 0:
				arr.remove_at(at)
				oc["cells"] = arr
		chamber_id[c] = id + 1
		ch["cells"].append(c)
		if solidity[c] > 0:
			set_mark(c, true)
		mark_dirty(c)
	for i in chambers.size():
		_recount_chamber(i)
	return id


func clear_chamber_at(c: int) -> void:
	if c < 0 or chamber_id[c] == 0:
		return
	var id := chamber_id[c] - 1
	var ch: Dictionary = chambers[id]
	for cc in ch["cells"]:
		chamber_id[cc] = 0
		mark_dirty(cc)
	ch["cells"] = PackedInt32Array()
	ch["type"] = "none"
	_recount_chamber(id)
	fields.erase("ch:%d" % id)


func _recount_chamber(i: int) -> void:
	var ch: Dictionary = chambers[i]
	var n := 0
	var sum := Vector2.ZERO
	for c in ch["cells"]:
		if solidity[c] == 0:
			n += 1
			sum += center(c)
	ch["open"] = n
	ch["center"] = sum / n if n > 0 else Vector2.ZERO
	var def: Dictionary = Data.table("chambers").get(ch["type"], {})
	ch["ok"] = n >= int(def.get("min_cells", 1)) and ch["type"] != "none"
	field_dirty["ch:%d" % i] = true


func chamber_of_type(type: String) -> int:
	var best := -1
	var best_n := -1
	for i in chambers.size():
		var ch: Dictionary = chambers[i]
		if ch["type"] == type and ch["open"] > best_n:
			best = i
			best_n = ch["open"]
	return best


func chambers_of_type(type: String, only_ok: bool = true) -> Array:
	var out := []
	for i in chambers.size():
		var ch: Dictionary = chambers[i]
		if ch["type"] == type and (ch["ok"] or not only_ok):
			out.append(i)
	return out


func chamber_cells_of_type(type: String) -> int:
	var n := 0
	for ch in chambers:
		if ch["type"] == type and ch["ok"]:
			n += int(ch["open"])
	return n


func count_ok_chambers(type: String = "") -> int:
	var n := 0
	for ch in chambers:
		if ch["ok"] and (type == "" or ch["type"] == type):
			n += 1
	return n


func chamber_avg(i: int, arr_name: String) -> float:
	var ch: Dictionary = chambers[i]
	var arr = get(arr_name)
	var s := 0.0
	var n := 0
	for c in ch["cells"]:
		if solidity[c] == 0:
			s += arr[c]
			n += 1
	return s / n if n > 0 else 0.0


func random_open_cell_in_chamber(i: int, rng: RandomNumberGenerator) -> int:
	var ch: Dictionary = chambers[i]
	var arr: PackedInt32Array = ch["cells"]
	for attempt in 6:
		if arr.is_empty():
			return -1
		var c := arr[rng.randi() % arr.size()]
		if solidity[c] == 0:
			return c
	return -1


# ---------------------------------------------------------------- flow fields

func field(key: String) -> PackedInt32Array:
	if not fields.has(key) or field_dirty.get(key, true):
		_rebuild_field(key)
	return fields[key]


## Rebuild at most `budget` dirty fields (called each tick).
func step_fields(budget: int = 1) -> void:
	for key in field_dirty.keys():
		if budget <= 0:
			return
		if field_dirty[key]:
			_rebuild_field(key)
			budget -= 1


func _rebuild_field(key: String) -> void:
	var sources := PackedInt32Array()
	if key == "exit":
		if kind == "house":
			sources = entrance_cells
		else:
			for x in w:
				if solidity[x] == 0:
					sources.append(x)
	elif key == "dig":
		for c in open_list:
			var x := c % w
			if (x > 0 and dig_mark[c - 1] == 1) or (x < w - 1 and dig_mark[c + 1] == 1) or (c >= w and dig_mark[c - w] == 1) or (c + w < w * h and dig_mark[c + w] == 1):
				sources.append(c)
	elif key.begins_with("ch:"):
		var i := int(key.substr(3))
		if i < chambers.size():
			for c in chambers[i]["cells"]:
				if solidity[c] == 0:
					sources.append(c)
	elif key.begins_with("cell:"):
		sources.append(int(key.substr(5)))
	fields[key] = _bfs(sources)
	field_dirty[key] = false


func _bfs(sources: PackedInt32Array) -> PackedInt32Array:
	var n := w * h
	var dist := PackedInt32Array()
	dist.resize(n)
	dist.fill(INF)
	var q := PackedInt32Array()
	q.resize(open_list.size() + sources.size() + 4)
	var tail := 0
	for s in sources:
		if s >= 0 and s < n and dist[s] != 0:
			dist[s] = 0
			q[tail] = s
			tail += 1
	var head := 0
	while head < tail:
		var c := q[head]
		head += 1
		var d := dist[c] + 1
		var x := c % w
		if x > 0:
			var nb := c - 1
			if solidity[nb] == 0 and dist[nb] > d:
				dist[nb] = d
				q[tail] = nb
				tail += 1
		if x < w - 1:
			var nb := c + 1
			if solidity[nb] == 0 and dist[nb] > d:
				dist[nb] = d
				q[tail] = nb
				tail += 1
		if c >= w:
			var nb := c - w
			if solidity[nb] == 0 and dist[nb] > d:
				dist[nb] = d
				q[tail] = nb
				tail += 1
		if c + w < n:
			var nb := c + w
			if solidity[nb] == 0 and dist[nb] > d:
				dist[nb] = d
				q[tail] = nb
				tail += 1
	return dist


## Next cell downhill on field `f` from cell c (c itself if at goal or unreachable).
func downhill(f: PackedInt32Array, c: int) -> int:
	var best := c
	var bd := f[c]
	var x := c % w
	if x > 0 and f[c - 1] < bd:
		best = c - 1
		bd = f[c - 1]
	if x < w - 1 and f[c + 1] < bd:
		best = c + 1
		bd = f[c + 1]
	if c >= w and f[c - w] < bd:
		best = c - w
		bd = f[c - w]
	if c + w < w * h and f[c + w] < bd:
		best = c + w
	return best


## A marked cell adjacent to open cell c, or -1.
func adjacent_mark(c: int) -> int:
	var x := c % w
	if c >= w and dig_mark[c - w] == 1: return c - w
	if x > 0 and dig_mark[c - 1] == 1: return c - 1
	if x < w - 1 and dig_mark[c + 1] == 1: return c + 1
	if c + w < w * h and dig_mark[c + w] == 1: return c + w
	return -1


# ---------------------------------------------------------------- collapse

## Check unsupported spans. Returns cells that were filled.
func collapse_check(rng: RandomNumberGenerator, chance_mult: float, span_mult: float) -> PackedInt32Array:
	var filled := PackedInt32Array()
	if kind != "nest":
		return filled
	var rubble := soil_id_index("rubble")
	# Rubble that fell during this check settles before it can cave in again.
	var fresh := {}
	for y in range(maxi(_min_open_row, 1), mini(_max_open_row + 1, h)):
		var x := 0
		while x < w:
			var c := y * w + x
			if solidity[c] != 0 or not _weak_ceiling(c - w) or fresh.has(c - w):
				x += 1
				continue
			var x0 := x
			var weakest := 999.0
			var chance := 0.0
			while x < w:
				var cc := y * w + x
				if solidity[cc] != 0 or not _weak_ceiling(cc - w) or fresh.has(cc - w):
					break
				var s: Dictionary = _soils[soil_type[cc - w]]
				var ms := float(s.get("max_span", 999))
				if ms < weakest:
					weakest = ms
					chance = float(s.get("collapse_chance", 0.0))
				x += 1
			var span := x - x0
			var limit := weakest * span_mult
			if span > limit:
				var mid := y * w + (x0 + x) / 2
				if _void_height(mid) >= 3:
					var p := chance * chance_mult * (span - limit)
					if rng.randf() < p:
						for xx in range(x0, x):
							var fc := y * w + xx
							solidity[fc] = 255
							soil_type[fc] = rubble
							moisture[fc] = 0.0
							mark_dirty(fc)
							filled.append(fc)
							fresh[fc] = true
	if filled.size() > 0:
		rebuild_open_list()
		_invalidate_fields()
		for i in chambers.size():
			_recount_chamber(i)
	return filled


func _weak_ceiling(c: int) -> bool:
	if c < 0 or solidity[c] == 0:
		return false
	return not bool(_soils[soil_type[c]].get("support", false))


func _void_height(c: int) -> int:
	var n := 0
	while c < w * h and solidity[c] == 0 and n < 8:
		n += 1
		c += w
	return n


# ---------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	var ch_out := []
	for ch in chambers:
		ch_out.append({"type": ch["type"], "cells": ch["cells"], "corpses": ch["corpses"]})
	return {
		"kind": kind, "w": w, "h": h, "cell": cell,
		"soil_type": soil_type, "solidity": solidity, "moisture": moisture, "air": air,
		"mould": mould, "chamber_id": chamber_id, "dig_mark": dig_mark, "build": build,
		"temperature": temperature, "room": room, "room_names": room_names,
		"chambers": ch_out, "entrance_x": entrance_x, "entrance_cells": entrance_cells,
		"mound": mound, "thatch": thatch, "owner": owner, "surface_pos": surface_pos, "open_list": open_list,
	}


func deserialize(d: Dictionary) -> void:
	kind = d["kind"]
	w = d["w"]
	h = d["h"]
	cell = d["cell"]
	soil_type = d["soil_type"]
	solidity = d["solidity"]
	moisture = d["moisture"]
	air = d["air"]
	mould = d["mould"]
	chamber_id = d["chamber_id"]
	dig_mark = d["dig_mark"]
	build = d["build"]
	temperature = d["temperature"]
	room = d["room"]
	room_names = d["room_names"]
	entrance_x = d["entrance_x"]
	entrance_cells = d["entrance_cells"]
	mound = d["mound"]
	thatch = d["thatch"]
	owner = d["owner"]
	surface_pos = d["surface_pos"]
	occupancy = PackedByteArray()
	occupancy.resize(w * h)
	marks = 0
	for v in dig_mark:
		marks += v
	chambers = []
	for ch in d["chambers"]:
		chambers.append({"type": ch["type"], "cells": ch["cells"], "open": 0, "center": Vector2.ZERO, "ok": false, "corpses": ch["corpses"]})
	rebuild_open_list()
	if d.has("open_list") and d["open_list"].size() == open_list.size():
		open_list = d["open_list"]  # keep dig order: the environment sweeps cells in this order
	for i in chambers.size():
		_recount_chamber(i)
	fields.clear()
	field_dirty.clear()
	_invalidate_fields()
	mark_all_dirty()
