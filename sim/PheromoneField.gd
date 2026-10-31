class_name PheromoneField
extends RefCounted
## Scent grid for one space. Channels per faction: FOOD, HOME, ALARM, EXPLORE, PLAYER.
##
## Decay is lazy: every entry stores the value and the "decay clock" when it was last
## written. Reading applies exp(-k * (clock - stamp)). The decay clock advances by
## dt * rate_mult per tick, so rain (rate_mult >> 1) erases trails without touching
## every cell. Diffusion happens on deposit: a fraction spreads to the 4 neighbours.

const FOOD := 0
const HOME := 1
const ALARM := 2
const EXPLORE := 3
const PLAYER := 4
const PER_FACTION := 5

var w: int
var h: int
var cell: float
var inv_cell: float
var channels: int
var cells: int
var val := PackedFloat32Array()
var stamp := PackedFloat32Array()
var k := PackedFloat32Array()
var clock := 0.0
var rate_mult := 1.0
var max_value := 255.0
var diffuse := 0.18


func _init(width_mm: float = 0.0, height_mm: float = 0.0, cell_mm: float = 25.0, factions: int = 1) -> void:
	if width_mm <= 0.0:
		return
	var cfg := Data.table("pheromones")
	cell = cell_mm
	inv_cell = 1.0 / cell
	w = int(ceil(width_mm / cell))
	h = int(ceil(height_mm / cell))
	cells = w * h
	channels = PER_FACTION * factions
	max_value = float(cfg.get("max_value", 255.0))
	diffuse = float(cfg.get("diffuse", 0.18))
	val.resize(cells * channels)
	stamp.resize(cells * channels)
	k.resize(channels)
	var decay: Dictionary = cfg.get("decay_per_second", {})
	var names: Array = cfg.get("channels", ["FOOD", "HOME", "ALARM", "EXPLORE", "PLAYER"])
	for f in factions:
		for c in PER_FACTION:
			k[f * PER_FACTION + c] = float(decay.get(names[c], 0.01))


static func ch(faction: int, kind: int) -> int:
	return faction * PER_FACTION + kind


func advance(dt: float) -> void:
	clock += dt * rate_mult


func set_decay_mult(channel: int, base: float, mult: float) -> void:
	k[channel] = base * mult


func index_of(x: float, y: float) -> int:
	var ix := int(x * inv_cell)
	var iy := int(y * inv_cell)
	if ix < 0 or iy < 0 or ix >= w or iy >= h:
		return -1
	return iy * w + ix


func sample(x: float, y: float, channel: int) -> float:
	var ix := int(x * inv_cell)
	var iy := int(y * inv_cell)
	if ix < 0 or iy < 0 or ix >= w or iy >= h:
		return 0.0
	var i := channel * cells + iy * w + ix
	var v := val[i]
	if v == 0.0:
		return 0.0
	return v * exp(-k[channel] * (clock - stamp[i]))


func sample_cell(c: int, channel: int) -> float:
	var i := channel * cells + c
	var v := val[i]
	if v == 0.0:
		return 0.0
	return v * exp(-k[channel] * (clock - stamp[i]))


func _add(i: int, channel: int, amount: float) -> void:
	var v := val[i]
	if v != 0.0:
		v *= exp(-k[channel] * (clock - stamp[i]))
	v += amount
	if v > max_value:
		v = max_value
	elif v < 0.0:
		v = 0.0
	val[i] = v
	stamp[i] = clock


## Point deposit (no diffusion) - used by ants every few ticks.
func deposit(x: float, y: float, channel: int, amount: float) -> void:
	var ix := int(x * inv_cell)
	var iy := int(y * inv_cell)
	if ix < 0 or iy < 0 or ix >= w or iy >= h:
		return
	_add(channel * cells + iy * w + ix, channel, amount)


## Deposit with diffusion to the 4 neighbours.
func deposit_spread(x: float, y: float, channel: int, amount: float) -> void:
	var ix := int(x * inv_cell)
	var iy := int(y * inv_cell)
	if ix < 0 or iy < 0 or ix >= w or iy >= h:
		return
	var base := channel * cells
	var side := amount * diffuse * 0.25
	_add(base + iy * w + ix, channel, amount * (1.0 - diffuse))
	if ix > 0: _add(base + iy * w + ix - 1, channel, side)
	if ix < w - 1: _add(base + iy * w + ix + 1, channel, side)
	if iy > 0: _add(base + (iy - 1) * w + ix, channel, side)
	if iy < h - 1: _add(base + (iy + 1) * w + ix, channel, side)


## Brush: add (amount > 0) or remove (amount < 0) in a circle, falloff to the edge.
func brush(center: Vector2, radius: float, channel: int, amount: float) -> void:
	var r := int(ceil(radius * inv_cell))
	var cx := int(center.x * inv_cell)
	var cy := int(center.y * inv_cell)
	var base := channel * cells
	for y in range(maxi(cy - r, 0), mini(cy + r + 1, h)):
		for x in range(maxi(cx - r, 0), mini(cx + r + 1, w)):
			var d := Vector2((x + 0.5) * cell, (y + 0.5) * cell).distance_to(center)
			if d <= radius:
				_add(base + y * w + x, channel, amount * (1.0 - 0.6 * d / radius))


func erase(center: Vector2, radius: float, channel_list: Array) -> void:
	var r := int(ceil(radius * inv_cell))
	var cx := int(center.x * inv_cell)
	var cy := int(center.y * inv_cell)
	for channel in channel_list:
		var base: int = channel * cells
		for y in range(maxi(cy - r, 0), mini(cy + r + 1, h)):
			for x in range(maxi(cx - r, 0), mini(cx + r + 1, w)):
				if Vector2((x + 0.5) * cell, (y + 0.5) * cell).distance_to(center) <= radius:
					val[base + y * w + x] = 0.0


func clear_channel(channel: int) -> void:
	# Native fill on a slice is not available; zero via a loop over the slice.
	var base := channel * cells
	for i in cells:
		val[base + i] = 0.0


func clear_all() -> void:
	val.fill(0.0)


## Sample 3 antenna points (left/forward/right) and return the turn direction
## (-1, 0, +1) toward the best score = a + wb * b - avoid * alarm. 0 if all weak.
func steer(p: Vector2, hd: float, sd: float, sa: float, ch_a: int, ch_b: int, wb: float, avoid: float) -> float:
	var alarm := ch_a - (ch_a % PER_FACTION) + ALARM
	var best_dir := 0.0
	var best := 0.02
	var now := clock
	for j in 3:
		var a := hd + (j - 1) * sa
		var ix := int((p.x + cos(a) * sd) * inv_cell)
		var iy := int((p.y + sin(a) * sd) * inv_cell)
		if ix < 0 or iy < 0 or ix >= w or iy >= h:
			continue
		var c := iy * w + ix
		var i := ch_a * cells + c
		var s := 0.0
		var v := val[i]
		if v != 0.0:
			s = v * exp(-k[ch_a] * (now - stamp[i]))
		if ch_b >= 0:
			i = ch_b * cells + c
			v = val[i]
			if v != 0.0:
				s += wb * v * exp(-k[ch_b] * (now - stamp[i]))
		if avoid != 0.0:
			i = alarm * cells + c
			v = val[i]
			if v != 0.0:
				s -= avoid * v * exp(-k[alarm] * (now - stamp[i]))
		if j == 1:
			s *= 1.05
		if s > best:
			best = s
			best_dir = j - 1
	return best_dir


func serialize() -> Dictionary:
	return {"w": w, "h": h, "cell": cell, "channels": channels, "val": val, "stamp": stamp, "k": k, "clock": clock, "rate_mult": rate_mult, "max_value": max_value, "diffuse": diffuse}


func deserialize(d: Dictionary) -> void:
	w = d["w"]
	h = d["h"]
	cell = d["cell"]
	inv_cell = 1.0 / cell
	channels = d["channels"]
	cells = w * h
	val = d["val"]
	stamp = d["stamp"]
	k = d["k"]
	clock = d["clock"]
	rate_mult = d["rate_mult"]
	max_value = d["max_value"]
	diffuse = d["diffuse"]
