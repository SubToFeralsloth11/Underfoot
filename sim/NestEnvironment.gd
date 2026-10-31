class_name NestEnvironment
extends RefCounted
## Cellular automaton on a nest's open cells: air, moisture, temperature, mould.
## Work is amortized: each tick processes 1/update_divisor of the open-cell list.
##
## Packed arrays are copy-on-write, so writing `grid.air[c]` from outside NestGrid
## would copy the whole array per write. We detach the arrays into locals, update
## them, and reattach.

var cfg: Dictionary = {}
var divisor := 4
var _cursor: Dictionary = {}  # nest key -> position in open_list


func _init() -> void:
	cfg = Data.table("nest").get("env", {})
	divisor = int(cfg.get("update_divisor", 4))


## surface_temp in degrees C; rain 0..1; colony for trait multipliers.
func step(grid: NestGrid, key: int, surface_temp: float, rain: float, colony) -> void:
	var list := grid.open_list
	var total := list.size()
	if total == 0:
		return
	var chunk := int(ceil(float(total) / divisor))
	var start: int = _cursor.get(key, 0)
	if start >= total:
		start = 0
	var end := mini(start + chunk, total)
	_cursor[key] = end
	var dt := float(divisor) * Clock.DT

	var w := grid.w
	var n := w * grid.h
	var air_diffuse := float(cfg.get("air_diffuse", 0.45))
	var air_use := float(cfg.get("air_base_use", 1.2)) * dt
	var ant_use := float(cfg.get("air_ant_use", 1.5)) * dt
	var air_mult: float = colony.mult("nest.air_use") if colony else 1.0
	var flow := float(cfg.get("water_flow", 0.5))
	var drain_rate := float(cfg.get("drain_rate", 4.0)) * dt
	var sump_drain := float(cfg.get("sump_drain", 60.0)) * dt
	var thatch: bool = grid.thatch
	var entrance_in := float(cfg.get("rain_entrance_inflow", 40.0)) * rain * dt * (1.0 - (float(cfg.get("thatch_rain_block", 0.8)) if thatch else 0.0))
	var seep := float(cfg.get("rain_seep", 2.2)) * rain * dt
	var seep_depth := float(cfg.get("seep_depth_mm", 140.0))
	var deep := float(cfg.get("deep_temp", 14.0))
	var lam := float(cfg.get("temp_lambda_mm", 180.0))
	var lag := clampf(float(cfg.get("temp_lag", 0.04)) * dt * 20.0, 0.0, 1.0)
	var insul := float(cfg.get("thatch_insulation", 0.5)) if thatch else 0.0
	var warmth := float(cfg.get("thatch_warmth", 3.0)) if thatch else 0.0
	var m_temp := float(cfg.get("mould_temp", 22.0))
	var m_moist := int(cfg.get("mould_moist", 90))
	var m_air := int(cfg.get("mould_air", 150))
	var m_grow: float = float(cfg.get("mould_growth", 1.5)) * dt * (colony.mult("mould.growth") if colony else 1.0)
	var m_decay := float(cfg.get("mould_decay", 1.0)) * dt
	var corpse_cap := float(cfg.get("corpse_mould", 25))
	var has_midden := grid.count_ok_chambers("midden") > 0
	var sump_cells := {}
	var corpses_by_ch := PackedInt32Array()
	corpses_by_ch.resize(grid.chambers.size())
	for i in grid.chambers.size():
		corpses_by_ch[i] = 0 if has_midden else int(grid.chambers[i]["corpses"])
		if grid.chambers[i]["type"] == "sump":
			for c in grid.chambers[i]["cells"]:
				sump_cells[c] = true
	var dry_soil: float = colony.mult("env.flood_resist") if colony else 1.0
	var swing := surface_temp - deep
	var drains := PackedFloat32Array()
	drains.resize(256)
	for si in 16:
		var sd: Dictionary = grid._soils[si] if si < grid._soils.size() else {}
		drains[si] = float(sd.get("drains", 0.5))

	# Read-only views (no copy unless written).
	var solidity := grid.solidity
	var build := grid.build
	var occupancy := grid.occupancy
	var soil_type := grid.soil_type
	var chamber_id := grid.chamber_id
	# Detach writable arrays.
	var air := grid.air
	var moist := grid.moisture
	var temp := grid.temperature
	var mould := grid.mould
	grid.air = PackedFloat32Array()
	grid.moisture = PackedFloat32Array()
	grid.temperature = PackedFloat32Array()
	grid.mould = PackedFloat32Array()

	for k in range(start, end):
		var c := list[k]
		if c >= n or solidity[c] != 0:
			continue
		var x := c % w
		var y := c / w
		var sealed := build[c] == NestGrid.BUILD_SEAL
		# --- air: relax toward the mean of open, unsealed neighbours; consumption
		var a := float(air[c])
		if y == 0:
			a = 255.0
		else:
			var s := 0.0
			var cnt := 0
			if x > 0 and solidity[c - 1] == 0 and build[c - 1] != NestGrid.BUILD_SEAL:
				s += air[c - 1]
				cnt += 1
			if x < w - 1 and solidity[c + 1] == 0 and build[c + 1] != NestGrid.BUILD_SEAL:
				s += air[c + 1]
				cnt += 1
			if solidity[c - w] == 0 and build[c - w] != NestGrid.BUILD_SEAL:
				s += air[c - w]
				cnt += 1
			if c + w < n and solidity[c + w] == 0 and build[c + w] != NestGrid.BUILD_SEAL:
				s += air[c + w]
				cnt += 1
			if cnt > 0 and not sealed:
				a += (s / cnt - a) * air_diffuse
			a -= (air_use + ant_use * occupancy[c]) * air_mult
		air[c] = clampf(a, 0.0, 255.0)
		# --- moisture: inflow at the surface row, seepage, gravity flow, drainage
		var m := float(moist[c])
		if y == 0:
			m += entrance_in if absi(x - grid.entrance_x) <= 1 else entrance_in * 0.4
		var depth := (y + 0.5) * grid.cell
		if seep > 0.0:
			m += seep * exp(-depth / seep_depth) * 3.0
		var below_c := c + w
		if below_c < n and solidity[below_c] == 0 and not sealed and build[below_c] != NestGrid.BUILD_SEAL:
			var below := float(moist[below_c])
			var mv := minf(m * flow, 255.0 - below)
			if mv > 0.0:
				moist[below_c] = below + mv
				m -= mv
		elif m > 40.0:
			if x > 0 and solidity[c - 1] == 0 and build[c - 1] != NestGrid.BUILD_SEAL and moist[c - 1] < m:
				var mv := (m - moist[c - 1]) * 0.25
				moist[c - 1] = moist[c - 1] + mv
				m -= mv
			if x < w - 1 and solidity[c + 1] == 0 and build[c + 1] != NestGrid.BUILD_SEAL and moist[c + 1] < m:
				var mv := (m - moist[c + 1]) * 0.25
				moist[c + 1] = moist[c + 1] + mv
				m -= mv
		if below_c < n and solidity[below_c] != 0:
			m -= drain_rate * drains[soil_type[below_c]] * dry_soil
		if sump_cells.has(c):
			m -= sump_drain
		moist[c] = clampf(m, 0.0, 255.0)
		# --- temperature: lagged toward the depth profile
		var e := exp(-depth / lam)
		var target := deep + swing * e * (1.0 - insul) + warmth * e
		temp[c] += (target - temp[c]) * lag
		# --- mould: warm + wet + stale air, or unburied corpses
		var mo := float(mould[c])
		var cid := chamber_id[c]
		var corpses := corpses_by_ch[cid - 1] if cid > 0 and cid - 1 < corpses_by_ch.size() else 0
		if (temp[c] > m_temp and moist[c] > m_moist and air[c] < m_air) or corpses > 3:
			mo += m_grow * (1.0 + minf(corpses, corpse_cap) * 0.2)
		else:
			mo -= m_decay
		mould[c] = clampf(mo, 0.0, 255.0)

	grid.air = air
	grid.moisture = moist
	grid.temperature = temp
	grid.mould = mould
	if has_midden:
		for ch in grid.chambers:
			ch["corpses"] = 0


## Fraction of a chamber that is flooded.
func flooded_fraction(grid: NestGrid, chamber: int) -> float:
	var lvl := int(cfg.get("flood_level", 170))
	var cnt := 0
	var f := 0
	for c in grid.chambers[chamber]["cells"]:
		if grid.solidity[c] == 0:
			cnt += 1
			if grid.moisture[c] > lvl:
				f += 1
	return float(f) / cnt if cnt > 0 else 0.0
