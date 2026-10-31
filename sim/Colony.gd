class_name Colony
extends RefCounted
## One colony (player main nest, a satellite, or the rival): queen, brood, stores,
## caste targets and evolution traits. Traits only modify multipliers or unlock ids.

const STAGE_EGG := 0
const STAGE_LARVA := 1
const STAGE_PUPA := 2
const FOOD_TYPES := ["sugar", "seeds", "fungus", "protein"]
const EGG_HOURS := 8.0
const LARVA_MIN_HOURS := 12.0
const PUPA_HOURS := 10.0
const LARVA_STARVE := 14.0

var index := 0
var faction := 0
var nest := 0  # index into World.nests
var is_satellite := false
var is_ai := false
var name := "Colony"
var queen_alive := true
var queen_ant := -1
var egg_rate := 1.0
var egg_acc := 0.0
var brood: Array[Dictionary] = []
var stores: Dictionary = {"sugar": 40.0, "protein": 20.0, "seeds": 0.0, "fungus": 0.0, "water": 20.0, "leaf": 0.0, "poison": 0.0}
var caste_targets: Dictionary = {"worker": 0.6, "soldier": 0.12, "scout": 0.1, "nurse": 0.18}
var traits: PackedStringArray = []
var trait_points := 0
var generation := 1
var royals := 0
var charters := 0
var thatch := false

var harvested: Dictionary = {"sugar": 0.0, "protein": 0.0, "seeds": 0.0, "fungus": 0.0, "water": 0.0, "leaf": 0.0, "poison": 0.0}
var hatched := 0
var kills: Dictionary = {}
var deaths: Dictionary = {}
var nursing_power := 0.0  # accumulated nurse-ticks this hour (AntSim)
var counts := PackedInt32Array()  # per caste index (AntSim, each tick)
var forager_count := 0
var alive := true

# Derived (rebuilt from traits).
var _mult: Dictionary = {}
var _unlocks: Dictionary = {}
var caste_names: PackedStringArray = []
var caste_defs: Array = []
var c_speed := PackedFloat32Array()
var c_attack := PackedFloat32Array()
var c_hp := PackedFloat32Array()
var c_dig := PackedFloat32Array()
var c_carry := PackedFloat32Array()
var c_grip := PackedFloat32Array()
var c_sense := PackedFloat32Array()
var c_food := PackedFloat32Array()
var c_life := PackedFloat32Array()
var c_nurse := PackedFloat32Array()
var c_wander := PackedFloat32Array()


func _init() -> void:
	var castes := Data.table("castes")
	var n := 0
	for k in castes.keys():
		if not String(k).begins_with("_"):
			n += 1
	caste_names.resize(n)
	caste_defs.resize(n)
	for k in castes.keys():
		if String(k).begins_with("_"):
			continue
		var i := int(castes[k]["index"])
		caste_names[i] = k
		caste_defs[i] = castes[k]
	counts.resize(n)
	recompute()


func caste_index(c: String) -> int:
	return caste_names.find(c)


# ---------------------------------------------------------------- traits

func mult(key: String) -> float:
	return _mult.get(key, 1.0)


func has_unlock(id: String) -> bool:
	return _unlocks.has(id)


func recompute() -> void:
	_mult.clear()
	_unlocks.clear()
	var tdefs := Data.table("traits")
	for t in traits:
		var d: Dictionary = tdefs.get(t, {})
		for key in d.get("mult", {}).keys():
			_mult[key] = _mult.get(key, 1.0) * float(d["mult"][key])
		for u in d.get("unlock", []):
			_unlocks[u] = true
	var n := caste_names.size()
	for arr_name in ["c_speed", "c_attack", "c_hp", "c_dig", "c_carry", "c_grip", "c_sense", "c_food", "c_life", "c_nurse", "c_wander"]:
		var a := PackedFloat32Array()
		a.resize(n)
		set(arr_name, a)
	var ants_cfg: Dictionary = Data.table("castes").get("_ants", {})
	var base_speed := float(ants_cfg.get("base_speed", 45.0))
	var tph := float(Data.table("seasons").get("ticks_per_hour", 180))
	for i in n:
		var c: String = caste_names[i]
		var d: Dictionary = caste_defs[i]
		c_speed[i] = float(d["speed"]) * base_speed * mult("caste.%s.speed" % c) * mult("ant.speed")
		c_attack[i] = float(d["attack"]) * mult("caste.%s.attack" % c) * mult("ant.attack")
		c_hp[i] = float(d["hp"]) * mult("caste.%s.hp" % c) * mult("ant.hp")
		c_dig[i] = float(d["dig"]) * mult("caste.%s.dig" % c) * mult("ant.dig") * mult("nest.dig_speed")
		c_carry[i] = float(d["carry"]) * mult("caste.%s.carry" % c) * mult("ant.carry")
		c_grip[i] = float(d["grip"]) * mult("ant.grip")
		c_sense[i] = float(d.get("sense", 1.0)) * mult("pheromone.sense_radius")
		c_food[i] = float(d["food_cost"]) * mult("colony.food_cost")
		c_life[i] = float(d["lifespan_days"]) * 24.0 * tph * mult("ant.lifespan")
		c_nurse[i] = float(d.get("nurse", 0.0))
		c_wander[i] = float(d.get("wander", 0.35))


func can_unlock(id: String) -> bool:
	var d: Dictionary = Data.table("traits").get(id, {})
	if d.is_empty() or traits.has(id):
		return false
	if trait_points < int(d.get("cost", 1)):
		return false
	for r in d.get("requires", []):
		if not traits.has(r):
			return false
	return true


func unlock_trait(id: String, free: bool = false) -> bool:
	if not free and not can_unlock(id):
		return false
	if traits.has(id):
		return false
	if not free:
		trait_points -= int(Data.table("traits")[id].get("cost", 1))
	traits.append(id)
	recompute()
	return true


func producible_castes() -> PackedStringArray:
	var out: PackedStringArray = []
	for i in caste_names.size():
		var d: Dictionary = caste_defs[i]
		if not d.get("producible", false):
			continue
		var u: String = d.get("unlock", "")
		if u == "" or has_unlock(u):
			out.append(caste_names[i])
	return out


# ---------------------------------------------------------------- stores

func food_total() -> float:
	return stores["sugar"] + stores["protein"] + stores["seeds"] + stores["fungus"] + stores["leaf"]


func capacity(grid: NestGrid) -> float:
	var cells := grid.chamber_cells_of_type("food_store") if grid else 0
	var fungus := grid.chamber_cells_of_type("fungus") if grid else 0
	return (200.0 + cells * 6.0 + fungus * 3.0) * mult("colony.store_capacity")


func water_capacity(grid: NestGrid) -> float:
	var cells := grid.chamber_cells_of_type("water") if grid else 0
	return 30.0 + cells * 2.0


## Returns amount accepted.
func add_store(type: String, amount: float, grid: NestGrid) -> float:
	if not stores.has(type):
		return 0.0
	var room := 0.0
	if type == "water":
		room = water_capacity(grid) - stores["water"]
	elif type == "poison":
		room = 9999.0
	else:
		room = capacity(grid) - food_total()
	var got := clampf(amount, 0.0, maxf(room, 0.0))
	stores[type] += got
	harvested[type] = harvested.get(type, 0.0) + got
	return got


func take_store(type: String, amount: float) -> float:
	var got := minf(stores.get(type, 0.0), amount)
	stores[type] -= got
	return got


## Spend a cost dictionary atomically.
func spend(cost: Dictionary) -> bool:
	for k in cost.keys():
		if stores.get(k, 0.0) < float(cost[k]):
			return false
	for k in cost.keys():
		stores[k] -= float(cost[k])
	return true


# ---------------------------------------------------------------- population

func population() -> int:
	var n := 0
	for i in counts.size():
		if caste_names[i] != "queen":
			n += counts[i]
	return n


func brood_of_caste(c: String) -> int:
	var n := 0
	for b in brood:
		if b["caste"] == c and b["stage"] >= STAGE_LARVA:
			n += 1
	return n


func choose_caste() -> String:
	var options := producible_castes()
	var total := 0.0
	var tsum := 0.0
	for c in options:
		tsum += float(caste_targets.get(c, 0.0))
	if population() < 8 or tsum <= 0.0:
		return "worker"
	var share := {}
	for c in options:
		var n := counts[caste_index(c)] + brood_of_caste(c)
		share[c] = float(n)
		total += n
	var best := "worker"
	var best_gap := -INF
	for c in options:
		var gap: float = float(caste_targets.get(c, 0.0)) / tsum - share[c] / maxf(total, 1.0)
		if gap > best_gap:
			best_gap = gap
			best = c
	return best


func brood_capacity(grid: NestGrid) -> int:
	var cap := 0.0
	var cdefs := Data.table("chambers")
	for ch in grid.chambers:
		if ch["ok"]:
			cap += float(ch["open"]) * float(cdefs.get(ch["type"], {}).get("brood_per_cell", 0.0))
	return maxi(int(cap), 6)


func best_brood_chamber(grid: NestGrid) -> int:
	var best := -1
	var best_score := -INF
	for t in ["nursery", "queen"]:
		for i in grid.chambers_of_type(t):
			var temp := grid.chamber_avg(i, "temperature")
			var score := -absf(temp - 27.5) - grid.chamber_avg(i, "mould") * 0.05 - grid.chamber_avg(i, "moisture") * 0.02
			if t == "nursery":
				score += 3.0
			if score > best_score:
				best_score = score
				best = i
	return best


static func dev_speed(temp: float) -> float:
	if temp >= 25.0 and temp <= 30.0:
		return 1.5
	if temp < 25.0:
		return clampf(0.1 + (temp - 8.0) / 17.0 * 1.2, 0.05, 1.3)
	return clampf(1.5 - (temp - 30.0) * 0.15, 0.2, 1.5)


## Hourly brood + queen logic. Returns array of castes that hatched (World spawns them).
func on_hour(grid: NestGrid, season: Dictionary, flags: Dictionary, rng: RandomNumberGenerator, env_cfg: Dictionary) -> Array:
	var hatched_now: Array = []
	if not alive:
		return hatched_now
	var brood_chamber := best_brood_chamber(grid)
	# Queen lays.
	if queen_alive and brood.size() < brood_capacity(grid):
		var rate := egg_rate * float(season.get("egg_rate", 1.0)) * mult("colony.egg_rate")
		if food_total() < 2.0:
			rate = 0.0
		egg_acc += rate
		while egg_acc >= 1.0:
			egg_acc -= 1.0
			var cost := 0.3
			if stores["protein"] >= cost:
				stores["protein"] -= cost
			elif stores["sugar"] >= cost:
				stores["sugar"] -= cost
			else:
				break
			brood.append({"stage": STAGE_EGG, "age": 0.0, "caste": "", "fed": 0, "protein": 0, "hunger": 0.0, "chamber": brood_chamber, "sick": 0.0, "royal": false})
	# Feed larvae with this hour's nursing power.
	var tph := float(Data.table("seasons").get("ticks_per_hour", 180))
	var feeds := nursing_power / tph
	if feeds < 0.5 and queen_alive and population() < 12:
		feeds += 1.0  # claustral queen feeds the first brood herself
	nursing_power = 0.0
	var larvae: Array = []
	for b in brood:
		if b["stage"] == STAGE_LARVA:
			larvae.append(b)
	larvae.sort_custom(func(a, b): return a["hunger"] > b["hunger"])
	var fed_budget := int(floor(feeds * 2.0))
	for b in larvae:
		if fed_budget <= 0:
			break
		if _feed(b, rng):
			fed_budget -= 1
	# Develop.
	var flood_level := float(env_cfg.get("flood_level", 170))
	var spoil_mould := float(env_cfg.get("mould_spoil", 70))
	var keep: Array[Dictionary] = []
	for b in brood:
		var ci: int = b["chamber"]
		if ci < 0 or ci >= grid.chambers.size() or not grid.chambers[ci]["ok"]:
			ci = brood_chamber
			b["chamber"] = ci
		var temp := 20.0
		var mould := 0.0
		var wet := 0.0
		if ci >= 0:
			temp = grid.chamber_avg(ci, "temperature")
			mould = grid.chamber_avg(ci, "mould")
			wet = grid.chamber_avg(ci, "moisture")
		if wet > flood_level and not has_unlock("behaviour:raft"):
			_die_brood("drowned")
			continue
		if mould > spoil_mould:
			b["sick"] = minf(b["sick"] + 0.15 * mult("mould.growth"), 1.0)
		else:
			b["sick"] = maxf(b["sick"] - 0.05, 0.0)
		if b["sick"] > 0.8 and rng.randf() < 0.1:
			_die_brood("mould")
			continue
		var speed: float = dev_speed(temp) * mult("colony.brood_speed") * (1.0 - b["sick"] * 0.7)
		b["age"] += speed
		match b["stage"]:
			STAGE_EGG:
				if b["age"] >= EGG_HOURS:
					b["stage"] = STAGE_LARVA
					b["age"] = 0.0
					if b["caste"] == "":
						b["caste"] = choose_caste()
			STAGE_LARVA:
				b["hunger"] += 1.0
				if b["hunger"] > LARVA_STARVE:
					_die_brood("starved")
					continue
				var need := int(caste_defs[caste_index(b["caste"])]["feeds"])
				if b["fed"] >= need and b["age"] >= LARVA_MIN_HOURS:
					var cd: Dictionary = caste_defs[caste_index(b["caste"])]
					var ratio := float(b["protein"]) / maxf(b["fed"], 1)
					if not b["royal"] and ratio < float(cd["diet"]) - 0.3:
						b["caste"] = "worker"  # malnourished: wrong diet makes a worker
					b["stage"] = STAGE_PUPA
					b["age"] = 0.0
			STAGE_PUPA:
				if b["age"] >= PUPA_HOURS:
					hatched += 1
					if b["royal"]:
						royals += 1
					else:
						hatched_now.append(b["caste"])
					continue
		keep.append(b)
	brood = keep
	# Fungus garden converts leaves.
	var gardens := grid.chambers_of_type("fungus")
	if gardens.size() > 0 and has_unlock("chamber:fungus"):
		var conv := minf(stores["leaf"], 2.0 * gardens.size())
		stores["leaf"] -= conv
		stores["fungus"] += conv * 1.5
	# Water chamber collects seepage.
	for i in grid.chambers_of_type("water"):
		if grid.chamber_avg(i, "moisture") > 20.0:
			add_store("water", grid.chambers[i]["open"] * 0.05, grid)
	# Mould spoils food stores.
	for i in grid.chambers_of_type("food_store"):
		if grid.chamber_avg(i, "mould") > spoil_mould:
			for t in ["sugar", "protein", "fungus"]:
				stores[t] *= 0.98
			if not has_unlock("behaviour:seed_granary"):
				stores["seeds"] *= 0.98
	return hatched_now


func _feed(b: Dictionary, rng: RandomNumberGenerator) -> bool:
	var cd: Dictionary = caste_defs[caste_index(b["caste"])]
	var want_protein: bool = float(b["protein"]) / maxf(b["fed"], 1) < float(cd["diet"]) or (b["fed"] == 0 and float(cd["diet"]) >= 0.5)
	var order := ["protein", "sugar", "fungus", "seeds"] if want_protein else ["sugar", "fungus", "seeds", "protein"]
	if stores["poison"] > 0.5 and rng.randf() < 0.5:
		stores["poison"] -= 1.0
		b["sick"] = minf(b["sick"] + 0.6, 1.0)
		b["hunger"] = 0.0
		return true
	for t in order:
		if stores[t] >= 1.0:
			stores[t] -= 1.0
			b["fed"] += 1
			if t == "protein":
				b["protein"] += 1
			b["hunger"] = 0.0
			return true
	return false


func _die_brood(cause: String) -> void:
	deaths["brood_" + cause] = deaths.get("brood_" + cause, 0) + 1


func brood_counts() -> Vector3i:
	var e := 0
	var l := 0
	var p := 0
	for b in brood:
		match b["stage"]:
			STAGE_EGG: e += 1
			STAGE_LARVA: l += 1
			STAGE_PUPA: p += 1
	return Vector3i(e, l, p)


## Daily upkeep. Returns how many adult ants must starve (oldest first).
func on_day(season: Dictionary, upkeep_mult: float) -> int:
	if not alive:
		return 0
	var need := 0.0
	for i in counts.size():
		need += counts[i] * c_food[i]
	need *= float(season.get("upkeep", 1.0)) * upkeep_mult
	var remaining := need
	for t in FOOD_TYPES:
		remaining -= take_store(t, remaining)
		if remaining <= 0.0:
			break
	# Water: a little per ant in warm seasons, not lethal on its own.
	take_store("water", population() * 0.05)
	if remaining <= 0.01:
		return 0
	var avg := need / maxf(population(), 1)
	return int(ceil(remaining / maxf(avg, 0.1)))


func raise_royals(n: int) -> int:
	var f: Dictionary = Data.table("seasons").get("flight", {})
	var made := 0
	for i in n:
		if not spend({"sugar": float(f.get("cost_sugar", 60)), "protein": float(f.get("cost_protein", 60))}):
			break
		brood.append({"stage": STAGE_PUPA, "age": 0.0, "caste": "royal", "fed": 10, "protein": 10, "hunger": 0.0, "chamber": -1, "sick": 0.0, "royal": true})
		made += 1
	return made


func serialize() -> Dictionary:
	return {
		"index": index, "faction": faction, "nest": nest, "is_satellite": is_satellite, "is_ai": is_ai, "name": name,
		"queen_alive": queen_alive, "queen_ant": queen_ant, "egg_rate": egg_rate, "egg_acc": egg_acc, "brood": brood,
		"stores": stores, "caste_targets": caste_targets, "traits": traits, "trait_points": trait_points,
		"generation": generation, "royals": royals, "charters": charters, "thatch": thatch, "harvested": harvested,
		"hatched": hatched, "kills": kills, "deaths": deaths, "nursing_power": nursing_power, "alive": alive,
	}


func deserialize(d: Dictionary) -> void:
	for k in d.keys():
		if k == "brood":
			brood.clear()
			for b in d["brood"]:
				brood.append(b)
		else:
			set(k, d[k])
	recompute()
