class_name World
extends RefCounted
## Owns every simulation system and steps them in a fixed order each 20 Hz tick.
## Seeded RNG per system => same seed + same inputs = same world.

const SPACE_SURFACE := 0
const SPACE_HOUSE := 1
const SPACE_NEST0 := 2

var seed := 0
var mode := "sandbox"
var difficulty := "normal"
var diff: Dictionary = {}
var flags: Dictionary = {}
var options: Dictionary = {}
var chapter_id := ""
var yard: Dictionary = {}
var start_day_index := 0
var start_traits := 0

var rng_ants := RandomNumberGenerator.new()
var rng_nest := RandomNumberGenerator.new()
var rng_surface := RandomNumberGenerator.new()
var rng_colony := RandomNumberGenerator.new()
var rng_creatures := RandomNumberGenerator.new()
var rng_weather := RandomNumberGenerator.new()
var rng_house := RandomNumberGenerator.new()

var nests: Array[NestGrid] = []
var colonies: Array[Colony] = []
var pher: Array[PheromoneField] = []
var surface: SurfaceWorld
var house: NestGrid = null
var house_ai: HouseAI = null
var ants: AntSim
var creatures: Creatures
var weather: Weather
var env: NestEnvironment
var campaign: Campaign
var env_cfg: Dictionary = {}

var rally: Array = [{"pos": Vector2.INF, "active": false, "until": 0, "last": -999999}, {"pos": Vector2.INF, "active": false, "until": 0, "last": -999999}]
var stats: Dictionary = {"satellites": 0, "flights": 0}
var field_guide: Dictionary = {}
var haul_power: Dictionary = {}
var over := false
var queen_relocating := false
var _danger := 0.0
var _alert_last: Dictionary = {}
var _dig_sfx_tick := 0


# ---------------------------------------------------------------- setup

func setup(mode_in: String, opts: Dictionary) -> void:
	mode = mode_in
	options = opts.duplicate(true)
	seed = int(opts.get("seed", randi()))
	difficulty = String(opts.get("difficulty", Settings.difficulty))
	diff = Data.table("difficulty").get(difficulty, Data.table("difficulty").get("normal", {}))
	var start: Dictionary = {"workers": 5, "soldiers": 0, "scouts": 0, "nurses": 0, "stores": {}, "day": 1, "hour": 6, "season": "spring", "trait_points": 0, "traits": []}
	var chapter: Dictionary = {}
	match mode:
		"campaign":
			chapter_id = String(opts.get("chapter", "chapter_1"))
			chapter = Data.campaign.get(chapter_id, {})
			start.merge(chapter.get("start", {}), true)
			yard = Data.campaign.get(chapter.get("yard", "yard_01"), Data.campaign.get("yard_01", {}))
			flags = {"nest": true}
			for u in chapter.get("unlocks", []):
				flags[u] = true
		"endless":
			yard = SurfaceWorld.procedural_yard(seed)
			flags = _all_flags()
			flags["house"] = false
			start["workers"] = 12
			start["scouts"] = 2
			start["stores"] = {"sugar": 60, "protein": 40, "water": 20}
		"test":
			yard = opts.get("yard", Data.campaign.get("yard_01", {}))
			flags = opts.get("flags", {"nest": true, "surface": true})
			start.merge(opts.get("start", {}), true)
		_:
			yard = Data.campaign.get(opts.get("yard", "yard_01"), Data.campaign.get("yard_01", {}))
			flags = _all_flags()
			for k in opts.get("flags", {}).keys():
				flags[k] = opts["flags"][k]
			start["workers"] = int(opts.get("workers", 40))
			start["soldiers"] = int(opts.get("soldiers", 8))
			start["scouts"] = int(opts.get("scouts", 6))
			start["nurses"] = int(opts.get("nurses", 6))
			start["stores"] = {"sugar": 150, "protein": 100, "seeds": 50, "water": 40}
			start["trait_points"] = int(opts.get("trait_points", 6))
	if yard.is_empty():
		push_error("No yard data")
	rng_ants.seed = seed
	rng_nest.seed = seed + 1
	rng_surface.seed = seed + 2
	rng_colony.seed = seed + 3
	rng_creatures.seed = seed + 4
	rng_weather.seed = seed + 5
	rng_house.seed = seed + 6
	env_cfg = Data.table("nest").get("env", {})
	Clock.reset(int(start["day"]), int(start["hour"]), String(start["season"]))
	start_day_index = Clock.day_index()

	surface = SurfaceWorld.new()
	surface.generate(yard, seed)
	var pcfg := Data.table("pheromones")
	pher = []
	pher.append(PheromoneField.new(surface.size.x, surface.size.y, float(pcfg.get("surface_cell_mm", 25.0)), 2))
	ants = AntSim.new(self)
	creatures = Creatures.new(self)
	weather = Weather.new(self)
	env = NestEnvironment.new()
	if flags.get("house", false):
		_setup_house()
	else:
		pher.append(PheromoneField.new(100.0, 100.0, 25.0, 1))

	var main_nest := _add_nest(surface.entrance, false)
	var col := _add_colony(0, main_nest, false, "Your Colony")
	col.trait_points = int(start.get("trait_points", 0))
	for t in start.get("traits", []):
		col.unlock_trait(String(t), true)
	start_traits = col.traits.size()
	for k in start.get("stores", {}).keys():
		col.stores[k] = float(start["stores"][k])
	if opts.has("caste_targets"):
		col.caste_targets = opts["caste_targets"]
	var founders := int(start.get("workers", 0)) + int(start.get("soldiers", 0)) + int(start.get("scouts", 0)) + int(start.get("nurses", 0))
	if founders > 15:
		ColonyAI.plan_template(nests[main_nest], true)
	_spawn_founders(col, start)
	if flags.get("rival", false):
		_setup_rival(int(opts.get("rival_start", 40)))
	for f in yard.get("foods", []):
		surface.add_food(f["food"], Vector2(f["pos"][0], f["pos"][1]), SPACE_SURFACE, 1.0, Clock.tick, Clock.ticks_per_hour)
	campaign = Campaign.new(self, chapter)
	discover("queen_ant")
	if campaign.active():
		campaign.on_start()


func _all_flags() -> Dictionary:
	return {"nest": true, "surface": true, "rival": true, "weather": true, "seasons": true, "evolution": true, "satellites": true, "house": true, "creatures": true}


func _setup_house() -> void:
	var hcfg := Data.table("house")
	house = NestGrid.new()
	house.generate_house(hcfg)
	house.owner = -1
	pher.append(PheromoneField.new(house.w * house.cell, house.h * house.cell, house.cell, 1))
	surface.add_space_map(SPACE_HOUSE, house.w, house.h, house.cell)
	house_ai = HouseAI.new(self)
	house_ai.setup()


func _add_nest(surface_pos: Vector2, small: bool) -> int:
	var cfg := Data.table("nest")
	var g := NestGrid.new()
	var sz: Array = cfg["satellite_size"] if small else cfg["size"]
	var r := RandomNumberGenerator.new()
	r.seed = seed * 31 + nests.size() * 977
	g.generate_nest(r, Vector2i(int(sz[0]), int(sz[1])))
	g.surface_pos = surface_pos
	nests.append(g)
	pher.append(PheromoneField.new(g.w * g.cell, g.h * g.cell, float(Data.table("pheromones").get("nest_cell_mm", 8.0)), 2))
	return nests.size() - 1


func _add_colony(faction: int, nest_idx: int, satellite: bool, name: String) -> Colony:
	var col := Colony.new()
	col.index = colonies.size()
	col.faction = faction
	col.nest = nest_idx
	col.is_satellite = satellite
	col.is_ai = faction != 0
	col.name = name
	colonies.append(col)
	nests[nest_idx].owner = col.index
	return col


func _spawn_founders(col: Colony, start: Dictionary) -> void:
	var g := nests[col.nest]
	var qc := g.chamber_of_type("queen")
	var center: Vector2 = g.chambers[qc]["center"] if qc >= 0 else g.center(g.entrance_x)
	ants.spawn(col.index, col.caste_index("queen"), center, AntSim.LAYER_NEST, col.nest)
	for pair in [["workers", "worker"], ["soldiers", "soldier"], ["scouts", "scout"], ["nurses", "nurse"]]:
		for i in int(start.get(pair[0], 0)):
			var c := g.random_open_cell_in_chamber(qc, rng_colony) if qc >= 0 else -1
			var p := g.center(c) if c >= 0 else center
			ants.spawn(col.index, col.caste_index(pair[1]), p, AntSim.LAYER_NEST, col.nest)


func _setup_rival(start_pop: int) -> void:
	var ni := _add_nest(surface.rival_entrance, true)
	var col := _add_colony(1, ni, false, "Red Ants")
	ColonyAI.plan_template(nests[ni], true)
	col.stores = {"sugar": 80.0, "protein": 60.0, "seeds": 0.0, "fungus": 0.0, "water": 30.0, "leaf": 0.0, "poison": 0.0}
	var n_sold := int(start_pop * 0.3)
	_spawn_founders(col, {"workers": start_pop - n_sold, "soldiers": n_sold})
	col.caste_targets = {"worker": 0.6, "soldier": 0.3, "scout": 0.1, "nurse": 0.12}


# ---------------------------------------------------------------- step

func step(dt: float) -> void:
	if over:
		return
	weather.step(dt)
	for p in pher:
		p.advance(dt)
	ants.step(dt)
	_haul_step(dt)
	creatures.step(dt)
	var st := weather.surface_temp()
	for i in nests.size():
		var g := nests[i]
		var col = colonies[g.owner] if g.owner >= 0 and g.owner < colonies.size() else null
		env.step(g, i, st, weather.rain_at(g.surface_pos), col)
		g.step_fields(1)
		if (Clock.tick + i * 7) % int(Data.table("nest").get("collapse_check_ticks", 40)) == 0:
			var mult_c: float = col.mult("nest.collapse_chance") if col else 1.0
			var mult_s: float = col.mult("nest.max_span") if col else 1.0
			var filled := g.collapse_check(rng_nest, mult_c, mult_s)
			if filled.size() > 0:
				on_cells_filled(i, filled, "collapse")
	if house:
		house.step_fields(1)
	if house_ai:
		house_ai.step(dt)
	campaign.step()
	_rally_step()
	if Clock.tick % 100 == 0:
		_check_traffic()
		surface.expire_foods(Clock.tick)
	if Clock.tick % 20 == 0:
		_update_danger()


func on_hour(hour: int) -> void:
	if over:
		return
	var season := weather.season_def()
	for col in colonies:
		if not col.alive:
			continue
		var g := nests[col.nest]
		var hatched: Array = col.on_hour(g, season, flags, rng_colony, env_cfg)
		for c in hatched:
			var qc := col.best_brood_chamber(g)
			var cell := g.random_open_cell_in_chamber(qc, rng_colony) if qc >= 0 else -1
			var p := g.center(cell) if cell >= 0 else g.center(g.entrance_x)
			if ants.spawn(col.index, col.caste_index(c), p, AntSim.LAYER_NEST, col.nest) >= 0 and col.faction == 0:
				Events.ant_hatched.emit(c)
		if col.is_ai:
			ColonyAI.on_hour(self, col)
	creatures.on_hour(Clock.season(), season, diff, flags)
	if house_ai:
		house_ai.on_hour(hour)
	_spawn_food(season)
	_check_flight(hour)
	_check_alerts()
	campaign.on_hour(hour)


func on_day(_d: int) -> void:
	if over:
		return
	var season := weather.season_def()
	for col in colonies:
		var starving := col.on_day(season, float(diff.get("upkeep", 1.0)) if col.faction == 0 else 0.8)
		if starving > 0:
			_starve(col, starving)
	weather.on_day()
	campaign.on_day()


func on_season(s: String) -> void:
	var prev_i := (Clock.season_names.find(s) + Clock.season_names.size() - 1) % Clock.season_names.size()
	campaign.on_season_end(Clock.season_names[prev_i])
	if s == "winter":
		Events.hint.emit("winter")
		Events.alert.emit("winter", "Winter: the surface closes. Live on your stores until spring.", nests[0].surface_pos, SPACE_SURFACE)
	if s == "spring" and Clock.tick > 0:
		for col in colonies:
			col.generation += 1
			if col.faction == 0 and flags.get("evolution", false):
				col.trait_points += 1
		Events.toast.emit("A new year begins. +1 trait point.")


# ---------------------------------------------------------------- hauling

func _haul_step(dt: float) -> void:
	var groups: Dictionary = {}
	for i in ants.n:
		if ants.state[i] == AntSim.HAUL:
			var fid := ants.target[i]
			if not surface.foods.has(fid):
				ants.release(i)
				continue
			if not groups.has(fid):
				groups[fid] = PackedInt32Array()
			var arr: PackedInt32Array = groups[fid]
			arr.append(i)
			groups[fid] = arr
	haul_power.clear()
	for fid in groups.keys():
		var f: Dictionary = surface.foods[fid]
		var haulers: PackedInt32Array = groups[fid]
		var strength := 0.0
		for i in haulers:
			strength += colonies[ants.home[i]].c_carry[ants.caste[i]]
		haul_power[fid] = strength
		var col := colonies[ants.home[haulers[0]]]
		var space := int(f["space"])
		var dest: Vector2 = nests[col.nest].surface_pos
		if space == SPACE_HOUSE:
			var c := house.cell_at(f["pos"])
			var fe := house.field("exit")
			dest = house.center(house.downhill(fe, c)) if c >= 0 and fe[c] < NestGrid.INF else f["pos"]
		var moved := false
		if strength >= f["weight"]:
			var spd := 14.0 * minf(strength / f["weight"], 2.0)
			var to: Vector2 = dest - f["pos"]
			if to.length() > 1.0:
				var np: Vector2 = f["pos"] + to.normalized() * minf(spd * dt, to.length())
				var blocked := surface.is_blocked(np.x, np.y) if space == SPACE_SURFACE else not house.passable(np)
				if blocked:
					np = f["pos"] + to.normalized().rotated(PI * 0.5) * spd * dt
				surface.move_food(fid, np)
				moved = true
			if space == SPACE_SURFACE and f["pos"].distance_to(nests[col.nest].surface_pos) < 20.0:
				col.add_store(f["type"], f["amount"], nests[col.nest])
				surface.remove_food(fid)
				for i in haulers:
					ants.enter_nest(i, col.nest)
				Events.toast.emit("Hauled a %s home! (+%d %s)" % [String(f.get("creature", f["kind"])).replace("_", " "), int(f["amount"]), f["type"]])
				continue
			if space == SPACE_HOUSE and house.cell_at(f["pos"]) in house.entrance_cells:
				var gp: Vector2 = surface.house_gaps[0] + Vector2(0, 30)
				surface.remove_food(fid)
				var nid := surface.add_carcass(String(f.get("creature", f["kind"])), gp, f["amount"], f["weight"], SPACE_SURFACE, Clock.tick, Clock.ticks_per_hour)
				for i in haulers:
					ants.leave_house_to(i, gp)
					ants.set_haul(i, nid)
				continue
		var k := 0
		for i in haulers:
			ants.hold_at(i, f["pos"] + Vector2(f["radius"] + 2.0, 0).rotated(k * TAU / haulers.size() + Clock.tick * 0.0))
			if not moved and ants.timer[i] > 25.0:
				ants.recruit(i)
			k += 1


func haul_strength(fid: int) -> float:
	return haul_power.get(fid, 0.0)


# ---------------------------------------------------------------- helpers for AntSim

func surface_open() -> bool:
	if not flags.get("seasons", false) and mode != "endless":
		return true
	return weather.surface_open()


func player_colonies() -> Array:
	var out := []
	for c in colonies:
		if c.faction == 0:
			out.append(c)
	return out


func colony_population() -> int:
	var n := 0
	for c in player_colonies():
		n += c.population()
	return n


func trade_quota(c: int) -> int:
	var col := colonies[c]
	if col.faction != 0 or player_colonies().size() < 2:
		return 0
	var t := trade_target(c)
	if t < 0:
		return 0
	return 3


func trade_target(c: int) -> int:
	var col := colonies[c]
	var best := -1
	var low := col.food_total() * 0.4
	for o in colonies:
		if o.index != c and o.faction == col.faction and o.alive and o.food_total() < low and col.food_total() > 40.0:
			low = o.food_total()
			best = o.index
	return best


func trade_item(c: int) -> int:
	var col := colonies[c]
	var best := "sugar"
	for t in ["sugar", "protein", "seeds"]:
		if col.stores[t] > col.stores[best]:
			best = t
	return AntSim.ITEM_NAMES.find(best)


func rally_quota(c: int, pop: int) -> int:
	var col := colonies[c]
	var r: Dictionary = rally[col.faction]
	if not r["active"] or col.is_satellite:
		return 0
	return int(pop * (0.5 if col.faction == 0 else 0.35))


func rally_point(f: int) -> Vector2:
	return rally[f]["pos"]


func rally_active(f: int) -> bool:
	return rally[f]["active"]


func set_rally(f: int, p: Vector2, hours: float = 6.0) -> void:
	rally[f]["pos"] = p
	rally[f]["active"] = true
	rally[f]["until"] = Clock.tick + int(hours * Clock.ticks_per_hour)


func clear_rally(f: int) -> void:
	rally[f]["active"] = false


func _rally_step() -> void:
	for r in rally:
		if r["active"] and Clock.tick > r["until"]:
			r["active"] = false


func enemy_nest_at(p: Vector2, f: int, r: float) -> int:
	for i in nests.size():
		var g := nests[i]
		if g.owner < 0 or g.owner >= colonies.size():
			continue
		var col := colonies[g.owner]
		if col.faction != f and col.alive and p.distance_to(g.surface_pos) < r:
			return i
	return -1


func weakest_player_nest() -> int:
	var best := -1
	var best_def := INF
	for col in player_colonies():
		if not col.alive:
			continue
		var d: float = col.counts[col.caste_index("soldier")] * 3 + col.population() * 0.2
		if not col.is_satellite:
			d *= 0.9
		if d < best_def:
			best_def = d
			best = col.nest
	return best


func house_gap_at(p: Vector2, r: float) -> int:
	for i in surface.house_gaps.size():
		if p.distance_to(surface.house_gaps[i]) < r:
			return i
	return -1


func year_ramp() -> float:
	if mode != "endless":
		return 1.0
	return 1.0 + (Clock.year() - 1) * float(diff.get("endless_year_ramp", 0.25))


# ---------------------------------------------------------------- events from systems

func on_cell_dug(nest_i: int, c: int) -> void:
	if Clock.tick - _dig_sfx_tick > 6:
		_dig_sfx_tick = Clock.tick
		Events.cell_dug.emit(SPACE_NEST0 + nest_i, nests[nest_i].center(c))


func on_cells_filled(nest_i: int, cells: PackedInt32Array, cause: String) -> void:
	var g := nests[nest_i]
	var space := SPACE_NEST0 + nest_i
	var killed := 0
	for c in cells:
		for j in ants.ants_near(space, g.center(c), g.cell * 0.75, 16):
			if g.cell_at(ants.pos[j]) == c:
				ants.kill(j, "crushed")
				killed += 1
	if cause == "collapse" and cells.size() > 0:
		Events.collapse.emit(space, g.center(cells[cells.size() / 2]), cells.size())
		if g.owner >= 0 and colonies[g.owner].faction == 0:
			_alert("collapse", "A tunnel collapsed! %d ants crushed. Wide spans need pillars, roots or stronger soil." % killed, g.center(cells[0]), space)
			Events.hint.emit("collapse")


func on_queen_died(colony_idx: int, cause: String) -> void:
	var col := colonies[colony_idx]
	if col.faction != 0:
		col.alive = false
		stats["rival_destroyed"] = true
		Events.alert.emit("victory", "The rival queen is dead! The red ants scatter.", nests[col.nest].surface_pos, SPACE_SURFACE)
		return
	if queen_relocating:
		return
	for c in player_colonies():
		if c.queen_alive:
			Events.alert.emit("queen", "%s's queen died (%s). The colony lives on through %s." % [col.name, cause, c.name], nests[c.nest].surface_pos, SPACE_SURFACE)
			return
	over = true
	Events.game_over.emit(false, "The queen has died (%s). Without her, the colony fades away." % cause)


func on_food_found(fid: int, f: int) -> void:
	if f != 0:
		return
	if not stats.has("first_food"):
		stats["first_food"] = Clock.tick
		Events.hint.emit("food_found")
	var food: Dictionary = surface.foods[fid]
	if food.get("creature", "") != "":
		discover(food["creature"])


func on_reach_house(c: int) -> void:
	if colonies[c].faction == 0 and not stats.get("reached_house", false):
		stats["reached_house"] = true
		Events.hint.emit("house")
		Events.alert.emit("house", "Your ants have found a way into the HOUSE!", surface.house_gaps[0] if surface.house_gaps.size() > 0 else Vector2.ZERO, SPACE_SURFACE)


func discover(species: String) -> void:
	if field_guide.has(species) or not creatures.defs.has(species):
		return
	field_guide[species] = Clock.tick
	Events.discovered.emit(species)


func _alert(kind: String, text: String, p: Vector2, space: int, cooldown_ticks: int = 1200) -> void:
	if Clock.tick - int(_alert_last.get(kind, -999999)) < cooldown_ticks:
		return
	_alert_last[kind] = Clock.tick
	Events.alert.emit(kind, text, p, space)


func _starve(col: Colony, count: int) -> void:
	var cands: Array = []
	for i in ants.n:
		if ants.is_alive(i) and ants.home[i] == col.index and ants.job[i] != AntSim.J_QUEEN:
			cands.append(i)
	cands.sort_custom(func(a, b): return ants.age[a] > ants.age[b] or (ants.age[a] == ants.age[b] and a < b))
	for k in mini(count, cands.size()):
		ants.kill(cands[k], "starvation")
	if col.faction == 0:
		_alert("starving", "%d ants starved! Bring in more food." % mini(count, cands.size()), nests[col.nest].surface_pos, SPACE_NEST0 + col.nest, 1)
		Events.hint.emit("starving")


func _check_alerts() -> void:
	for col in player_colonies():
		var g := nests[col.nest]
		var space: int = SPACE_NEST0 + col.nest
		for i in g.chambers.size():
			var ch: Dictionary = g.chambers[i]
			if not ch["ok"]:
				continue
			if g.chamber_avg(i, "moisture") > float(env_cfg.get("flood_level", 170)) * 0.8:
				_alert("flood", "The %s is flooding! Dig a drainage sump below it." % Data.table("chambers")[ch["type"]]["name"], ch["center"], space)
				Events.hint.emit("flood")
			if g.chamber_avg(i, "air") < 60.0:
				_alert("air", "The air in the %s is going stale. Dig a vent shaft." % Data.table("chambers")[ch["type"]]["name"], ch["center"], space)
				Events.hint.emit("air")
			if g.chamber_avg(i, "mould") > float(env_cfg.get("mould_spoil", 70)):
				_alert("mould", "Mould is spreading in the %s." % Data.table("chambers")[ch["type"]]["name"], ch["center"], space)
				Events.hint.emit("mould")


func _check_traffic() -> void:
	var busy := int(Data.table("castes").get("_ants", {}).get("trail_busy_count", 14))
	if ants.traffic.size() > 0 and ants.traffic[0] >= busy / 4 and not stats.has("trail_busy"):
		stats["trail_busy"] = true
		Events.trail_busy.emit(nests[0].surface_pos)


func _update_danger() -> void:
	var d := 0.0
	for cr in creatures.list:
		if cr["attached"] > 0:
			d += 0.6
		elif cr["behaviour"] in ["hunter", "raider"]:
			d += 0.2
	if rally[1]["active"]:
		d += 1.2
	if house_ai and house_ai.ext_phase in ["fog", "trace", "dig"]:
		d += 2.5
	if weather.mower_active:
		d += 1.0
	_danger = clampf(d, 0.0, 3.0)


func danger() -> float:
	return _danger


func _spawn_food(season: Dictionary) -> void:
	if not flags.get("surface", false):
		return
	var rate := float(season.get("food_spawn_per_hour", 1.0))
	var n := int(rate) + (1 if rng_surface.randf() < fmod(rate, 1.0) else 0)
	var count := 0
	for f in surface.foods.values():
		if f["space"] == SPACE_SURFACE:
			count += 1
	if count > 70:
		return
	var defs := Data.table("foods")
	var sname := Clock.season()
	for k in n:
		var pool := []
		var total := 0.0
		for id in defs.keys():
			var sp: Dictionary = defs[id].get("spawn", {})
			if sname in sp.get("seasons", []) and float(sp.get("weight", 0)) > 0.0:
				pool.append(id)
				total += float(sp["weight"])
		if pool.is_empty():
			return
		var r := rng_surface.randf() * total
		var pick: String = pool[0]
		for id in pool:
			r -= float(defs[id]["spawn"]["weight"])
			if r <= 0.0:
				pick = id
				break
		var p := _food_spot(String(defs[pick]["spawn"].get("near", "any")))
		if p != Vector2.INF:
			surface.add_food(pick, p, SPACE_SURFACE, 1.0, Clock.tick, Clock.ticks_per_hour)


func _food_spot(near: String) -> Vector2:
	var anchors: Array = []
	match near:
		"tree":
			for t in surface.trees:
				anchors.append([t["pos"], float(t["canopy"]) * 0.8])
		"flower":
			for f in surface.flowers:
				anchors.append([f, 300.0])
		"patio":
			for o in surface.objects:
				if o["type"] in ["bbq", "chair"]:
					anchors.append([o["pos"], 900.0])
	for col in player_colonies():
		anchors.append([nests[col.nest].surface_pos, 2500.0])
	if anchors.is_empty():
		return Vector2.INF
	for attempt in 12:
		var a: Array = anchors[rng_surface.randi() % anchors.size()]
		var p: Vector2 = a[0] + Vector2(rng_surface.randf_range(60.0, a[1]), 0).rotated(rng_surface.randf() * TAU)
		if p.x > 50 and p.y > 1300 and p.x < surface.size.x - 50 and p.y < surface.size.y - 50 and not surface.is_blocked(p.x, p.y):
			return p
	return Vector2.INF


# ---------------------------------------------------------------- flights & satellites

func _check_flight(hour: int) -> void:
	var f: Dictionary = Data.table("seasons").get("flight", {})
	if Clock.season() != "spring" or Clock.day_of_season() != int(f.get("day", 7)):
		if Clock.season() == "spring" and Clock.day_of_season() == int(f.get("day", 7)) - 2 and hour == 8 and flags.get("evolution", false):
			Events.hint.emit("flight")
		return
	if hour != int(f.get("hour", 12)):
		return
	for col in player_colonies():
		if col.royals <= 0:
			continue
		var p: float = float(f.get("base_success", 0.5)) * col.mult("flight.success") * (0.6 if weather.rain > 0.0 else 1.0)
		var ok := 0
		for k in col.royals:
			if rng_colony.randf() < p:
				ok += 1
		var flown: int = col.royals
		col.royals = 0
		colonies[0].trait_points += ok
		colonies[0].charters += ok
		stats["flights"] = int(stats.get("flights", 0)) + 1
		Events.sfx.emit("flight", nests[col.nest].surface_pos, SPACE_SURFACE)
		Events.alert.emit("flight", "Nuptial flight! %d of %d royals mated. +%d trait points, +%d satellite charters." % [ok, flown, ok, ok], nests[col.nest].surface_pos, SPACE_SURFACE)
		if ok > 0:
			Events.hint.emit("traits")
			Events.hint.emit("satellite")


func raise_royals(n: int) -> int:
	return colonies[0].raise_royals(n)


func found_satellite(p: Vector2) -> String:
	var main := colonies[0]
	if main.charters <= 0:
		return "Needs a satellite charter (from a successful nuptial flight)."
	var ents: Array = []
	for g in nests:
		ents.append(g.surface_pos)
	if not surface.valid_nest_site(p, ents):
		return "Can't found a nest there (needs open soil away from other nests)."
	main.charters -= 1
	var ni := _add_nest(p, true)
	var col := _add_colony(0, ni, true, "Satellite %d" % (player_colonies().size()))
	col.egg_rate = 0.8
	col.traits = main.traits.duplicate()
	col.recompute()
	col.caste_targets = main.caste_targets.duplicate()
	col.stores = {"sugar": 0.0, "protein": 0.0, "seeds": 0.0, "fungus": 0.0, "water": 10.0, "leaf": 0.0, "poison": 0.0}
	for t in ["sugar", "protein"]:
		var moved := main.take_store(t, 25.0)
		col.stores[t] = moved
	ColonyAI.plan_template(nests[ni], false)
	var g := nests[ni]
	var qc := g.chamber_of_type("queen")
	ants.spawn(col.index, col.caste_index("queen"), g.chambers[qc]["center"], AntSim.LAYER_NEST, ni)
	# Re-home some workers: they walk across the yard to the new nest.
	var want := int(Data.table("seasons").get("flight", {}).get("satellite_workers", 10))
	var moved_n := 0
	for i in ants.n:
		if moved_n >= want:
			break
		if ants.is_alive(i) and ants.home[i] == 0 and ants.caste[i] == main.caste_index("worker"):
			ants.rehome(i, col.index)
			moved_n += 1
	stats["satellites"] = int(stats.get("satellites", 0)) + 1
	Events.alert.emit("satellite", "A daughter queen founds %s!" % col.name, p, SPACE_SURFACE)
	return ""


## Exterminator boss: move the queen through a satellite.
func start_queen_relocation(target: int) -> String:
	var main := colonies[0]
	if target <= 0 or target >= colonies.size() or colonies[target].faction != 0:
		return "Choose a satellite nest."
	if not main.queen_alive or main.queen_ant < 0:
		return "The queen is not in the main nest."
	if colonies[target].queen_alive:
		# Satellite already has a daughter queen: the old queen joins her.
		pass
	ants.despawn(main.queen_ant)
	main.queen_alive = false
	main.queen_ant = -1
	queen_relocating = true
	var travel := 60.0
	if house_ai:
		house_ai.queen_relocating = travel
		house_ai.relocate_target = target
	else:
		finish_queen_relocation(target)
	Events.toast.emit("The queen slips out of a back tunnel toward %s..." % colonies[target].name)
	return ""


func finish_queen_relocation(target: int) -> void:
	queen_relocating = false
	var col := colonies[target]
	var g := nests[col.nest]
	var qc := g.chamber_of_type("queen")
	var p: Vector2 = g.chambers[qc]["center"] if qc >= 0 else g.center(g.entrance_x)
	var main := colonies[0]
	# The old queen takes over the satellite; the main colony's workers re-home there.
	if col.queen_alive and col.queen_ant >= 0:
		ants.despawn(col.queen_ant)
	ants.spawn(target, col.caste_index("queen"), p, AntSim.LAYER_NEST, col.nest)
	col.queen_alive = true
	col.egg_rate = maxf(col.egg_rate, main.egg_rate)
	Events.toast.emit("The queen is safe in %s." % col.name)
	if house_ai and house_ai.ext_phase in ["trace", "dig", "fog"]:
		var ph := pher[SPACE_SURFACE]
		var scent := ph.sample(g.surface_pos.x, g.surface_pos.y, PheromoneField.FOOD) + ph.sample(g.surface_pos.x, g.surface_pos.y, PheromoneField.HOME)
		if scent < 20.0:
			house_ai._win_exterminator("The exterminator never found the hidden queen. Victory!")


func exterminator_dig(x: int, depth: int) -> void:
	var g := nests[0]
	var y := depth - 1
	if y < 0 or y >= g.h:
		return
	var space := SPACE_NEST0
	for xx in range(x - 4, x + 5):
		if xx < 0 or xx >= g.w:
			continue
		var c := y * g.w + xx
		g.excavate(c)
	for j in ants.ants_near(space, Vector2(x * g.cell, y * g.cell * 0.5), maxf(y * g.cell * 0.5, 30.0) + 20.0, 256):
		var cx := int(ants.pos[j].x / g.cell)
		var cy := int(ants.pos[j].y / g.cell)
		if absi(cx - x) <= 4 and cy <= y:
			ants.kill(j, "exterminator")


# ---------------------------------------------------------------- player commands

func dig_rect(nest_i: int, a: Vector2i, b: Vector2i, on: bool) -> int:
	Events.hint.emit("chamber")
	return nests[nest_i].mark_rect(a, b, on)


func chamber_rect(nest_i: int, a: Vector2i, b: Vector2i, type: String) -> String:
	var def: Dictionary = Data.table("chambers").get(type, {})
	if def.is_empty():
		return "Unknown chamber."
	var col := colonies[nests[nest_i].owner]
	var req: String = def.get("requires", "")
	if req != "" and not col.has_unlock(req):
		return "Requires the %s trait." % req.split(":")[1].capitalize()
	if type == "queen" and nests[nest_i].chambers_of_type("queen", false).size() > 0:
		# Move the queen chamber: clear the old one.
		for i in nests[nest_i].chambers_of_type("queen", false):
			var cells: PackedInt32Array = nests[nest_i].chambers[i]["cells"]
			if cells.size() > 0:
				nests[nest_i].clear_chamber_at(cells[0])
	var g := nests[nest_i]
	var cells := PackedInt32Array()
	for y in range(maxi(mini(a.y, b.y), 0), mini(maxi(a.y, b.y) + 1, g.h)):
		for x in range(maxi(mini(a.x, b.x), 0), mini(maxi(a.x, b.x) + 1, g.w)):
			cells.append(y * g.w + x)
	if cells.size() < int(def.get("min_cells", 1)):
		return "Too small: %s needs at least %d cells." % [def["name"], def["min_cells"]]
	g.assign_chamber(cells, type)
	Events.hint.emit("queen" if type == "queen" else "brood")
	return ""


func build(kind: String, nest_i: int, c: int) -> String:
	var g := nests[nest_i]
	var col := colonies[g.owner]
	var def: Dictionary = Data.table("builds").get(kind, {})
	var cost: Dictionary = def.get("cost", {}).duplicate()
	if kind == "seal" and col.has_unlock("behaviour:clay_masons"):
		for k in cost.keys():
			cost[k] = float(cost[k]) * 0.5
	match kind:
		"vent":
			g.mark_vent(c)
			return ""
		"sump":
			if not col.spend(cost):
				return "Not enough stores."
			var x := c % g.w
			var y := c / g.w
			return chamber_rect(nest_i, Vector2i(x - 1, y), Vector2i(x + 1, y + 1), "sump")
		"seal":
			if not g.is_open(c):
				return "Seals go in open tunnels."
			if not col.spend(cost):
				return "Not enough stores."
			g.place_seal(c)
			return ""
		"pillar":
			if not g.is_open(c):
				return "Pillars go in open cells."
			if not col.spend(cost):
				return "Not enough stores."
			for j in ants.ants_near(SPACE_NEST0 + nest_i, g.center(c), g.cell, 32):
				if g.cell_at(ants.pos[j]) == c:
					ants.nudge_out(j)
			g.fill(c, "pillar")
			return ""
		"thatch":
			if g.thatch:
				return "Already thatched."
			if not col.spend(cost):
				return "Needs %d seeds." % int(cost.get("seeds", 30))
			g.thatch = true
			col.thatch = true
			Events.toast.emit("Thatch dome built over the entrance.")
			return ""
	return "Unknown build."


func paint(space: int, p: Vector2, tool: String) -> void:
	var b: Dictionary = Data.table("pheromones").get("brush", {})
	var ph := pher[space]
	var r := float(b.get("radius_mm", 60.0)) * (2.5 if space == SPACE_SURFACE else 1.0) * (0.2 if space >= SPACE_NEST0 else 1.0)
	match tool:
		"trail":
			ph.brush(p, r, PheromoneField.PLAYER, float(b.get("strength", 220.0)) * Clock.DT * 6.0)
			Events.hint.emit("trail")
		"erase":
			ph.erase(p, float(b.get("erase_radius_mm", 90.0)) * (2.5 if space == SPACE_SURFACE else 1.0), [0, 1, 3, 4])
			Events.hint.emit("erase")
		"avoid":
			ph.brush(p, r, PheromoneField.ALARM, float(b.get("strength", 220.0)) * Clock.DT * 4.0)


func feed_mount(id: int) -> String:
	return creatures.feed_mount(id)


func script_spawn(kind: String, count: int, near: String) -> void:
	var d: Dictionary = creatures.defs.get(kind, {})
	if d.is_empty():
		return
	for k in count:
		var p := _near_point(near)
		if d.get("layer", "surface") == "nest":
			creatures.spawn(kind, Vector2(rng_creatures.randf_range(100, 900), rng_creatures.randf_range(200, 600)), SPACE_NEST0)
		elif d.get("layer", "surface") == "house" and house:
			creatures.spawn(kind, house.center(house.open_list[rng_creatures.randi() % house.open_list.size()]), SPACE_HOUSE)
		else:
			if kind == "dead_beetle":
				surface.add_carcass("dead_beetle", p, float(d.get("loot", 60)), float(d.get("weight", 8)), SPACE_SURFACE, Clock.tick, Clock.ticks_per_hour)
			else:
				creatures.spawn(kind, p, SPACE_SURFACE)


func script_food(kind: String, count: int, near: String) -> void:
	for k in count:
		surface.add_food(kind, _near_point(near), SPACE_SURFACE, 1.0, Clock.tick, Clock.ticks_per_hour)


func _near_point(near: String) -> Vector2:
	var e := nests[0].surface_pos
	var d := 400.0
	match near:
		"entrance": d = rng_surface.randf_range(150, 450)
		"food": d = rng_surface.randf_range(300, 900)
		"far": d = rng_surface.randf_range(1800, 3500)
		_: d = rng_surface.randf_range(400, 1500)
	for attempt in 16:
		var p := e + Vector2(d, 0).rotated(rng_surface.randf() * TAU)
		if p.x > 50 and p.y > 1300 and p.x < surface.size.x - 50 and p.y < surface.size.y - 50 and not surface.is_blocked(p.x, p.y):
			return p
	return e + Vector2(200, 0)


# ---------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	var nest_out := []
	for g in nests:
		nest_out.append(g.serialize())
	var col_out := []
	for c in colonies:
		col_out.append(c.serialize())
	var pher_out := []
	for p in pher:
		pher_out.append(p.serialize())
	var rngs := {}
	for k in ["rng_ants", "rng_nest", "rng_surface", "rng_colony", "rng_creatures", "rng_weather", "rng_house"]:
		var r: RandomNumberGenerator = get(k)
		rngs[k] = [r.seed, r.state]
	return {
		"seed": seed, "mode": mode, "difficulty": difficulty, "flags": flags, "options": options, "chapter_id": chapter_id,
		"yard": yard, "start_day_index": start_day_index, "start_traits": start_traits, "rngs": rngs,
		"nests": nest_out, "colonies": col_out, "pher": pher_out, "surface": surface.serialize(),
		"house": house.serialize() if house else {}, "house_ai": house_ai.serialize() if house_ai else {},
		"ants": ants.serialize(), "creatures": creatures.serialize(), "weather": weather.serialize(),
		"campaign": campaign.serialize(), "rally": rally, "stats": stats, "field_guide": field_guide,
		"queen_relocating": queen_relocating,
	}


func deserialize(d: Dictionary) -> void:
	seed = d["seed"]
	mode = d["mode"]
	difficulty = d["difficulty"]
	diff = Data.table("difficulty").get(difficulty, {})
	flags = d["flags"]
	options = d["options"]
	chapter_id = d["chapter_id"]
	yard = d["yard"]
	start_day_index = d["start_day_index"]
	start_traits = d["start_traits"]
	env_cfg = Data.table("nest").get("env", {})
	for k in d["rngs"].keys():
		var r: RandomNumberGenerator = get(k)
		r.seed = d["rngs"][k][0]
		r.state = d["rngs"][k][1]
	surface = SurfaceWorld.new()
	surface.deserialize(d["surface"], yard)
	nests.clear()
	for nd in d["nests"]:
		var g := NestGrid.new()
		g.deserialize(nd)
		nests.append(g)
	colonies.clear()
	for cd in d["colonies"]:
		var c := Colony.new()
		c.deserialize(cd)
		colonies.append(c)
	pher.clear()
	for pd in d["pher"]:
		var p := PheromoneField.new()
		p.deserialize(pd)
		pher.append(p)
	ants = AntSim.new(self)
	ants.deserialize(d["ants"])
	creatures = Creatures.new(self)
	creatures.deserialize(d["creatures"])
	weather = Weather.new(self)
	weather.deserialize(d["weather"])
	env = NestEnvironment.new()
	if not d["house"].is_empty():
		house = NestGrid.new()
		house.deserialize(d["house"])
		surface.add_space_map(SPACE_HOUSE, house.w, house.h, house.cell)
		surface.restamp(SPACE_HOUSE)
		house_ai = HouseAI.new(self)
		house_ai.deserialize(d["house_ai"])
	campaign = Campaign.new(self, {})
	campaign.deserialize(d["campaign"])
	rally = d["rally"]
	stats = d["stats"]
	field_guide = d["field_guide"]
	queen_relocating = d["queen_relocating"]


## SHA-256 over the full serialized state (save round-trip + determinism tests).
func state_hash() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(var_to_bytes(serialize()))
	return ctx.finish().hex_encode()
