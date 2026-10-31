class_name Creatures
extends RefCounted
## Backyard creatures: hunters, raiders, birds, worms, aphids, ambient critters and
## the rhinoceros beetle mount. Combat uses a grapple model: ants latch on, each
## attached ant adds damage and slows the target; the creature bites and shakes.

var world
var list: Array[Dictionary] = []
var by_id: Dictionary = {}
var next_id := 1
var defs: Dictionary = {}
var discovered: Dictionary = {}


func _init(w = null) -> void:
	world = w
	defs = Data.table("creatures")


func exists(id: int) -> bool:
	return by_id.has(id)


func get_c(id: int) -> Dictionary:
	return by_id.get(id, {})


func count_kind(kind: String) -> int:
	var c := 0
	for cr in list:
		if cr["kind"] == kind:
			c += 1
	return c


func spawn(kind: String, p: Vector2, space: int = 0) -> int:
	var d: Dictionary = defs.get(kind, {})
	if d.is_empty():
		return -1
	var id := next_id
	next_id += 1
	var cr := {
		"id": id, "kind": kind, "behaviour": d.get("behaviour", "ambient"), "pos": p, "heading": world.rng_creatures.randf() * TAU,
		"hp": float(d.get("hp", 10)), "max_hp": float(d.get("hp", 10)), "space": space, "state": "wander", "timer": 0.0,
		"life": 0.0, "target": -1, "attached": 0, "bite": 0.0, "shake": 0.0, "fed": 0, "tame": false, "carrying": -1,
		"tended": 0.0, "produce": 0.0, "size": float(d.get("size", 10)), "goal": p,
	}
	list.append(cr)
	by_id[id] = cr
	if cr["behaviour"] == "swooper":
		cr["state"] = "circle"
		cr["timer"] = 6.0
	return id


func remove(id: int) -> void:
	if not by_id.has(id):
		return
	var cr: Dictionary = by_id[id]
	world.ants.release_attached(id)
	by_id.erase(id)
	list.erase(cr)


## Hourly spawning, weighted by season + difficulty.
func on_hour(season_name: String, season: Dictionary, diff: Dictionary, flags: Dictionary) -> void:
	if not flags.get("creatures", false):
		return
	var rate: float = float(season.get("creature_rate", 0.5)) * float(diff.get("creature_rate", 1.0)) * world.year_ramp()
	# Small colonies get fewer visitors: threats scale in with the population.
	rate *= clampf(world.colony_population() / 80.0, 0.2, 1.0)
	var rng: RandomNumberGenerator = world.rng_creatures
	var attempts := int(rate) + (1 if rng.randf() < fmod(rate, 1.0) else 0)
	for a in attempts:
		var pool: Array = []
		var total := 0.0
		for k in defs.keys():
			var d: Dictionary = defs[k]
			var sp: Dictionary = d.get("spawn", {})
			var wgt := float(sp.get("weight", 0))
			if wgt <= 0.0 or not (season_name in sp.get("seasons", [])):
				continue
			var layer: String = d.get("layer", "surface")
			if layer == "house" and world.house == null:
				continue
			if layer == "surface" and not flags.get("surface", false):
				continue
			if count_kind(k) >= int(sp.get("max", 1)):
				continue
			pool.append([k, wgt])
			total += wgt
		if pool.is_empty():
			return
		var r := rng.randf() * total
		for e in pool:
			r -= e[1]
			if r <= 0.0:
				_spawn_natural(e[0])
				break


func _spawn_natural(kind: String) -> void:
	var d: Dictionary = defs[kind]
	var rng: RandomNumberGenerator = world.rng_creatures
	var layer: String = d.get("layer", "surface")
	var beh: String = d.get("behaviour", "ambient")
	if layer == "nest":
		var g: NestGrid = world.nests[0]
		var p := Vector2(rng.randf_range(0.1, 0.9) * g.w * g.cell, rng.randf_range(0.2, 0.8) * g.h * g.cell)
		spawn(kind, p, AntSim.SPACE_NEST0)
		return
	if layer == "house":
		var hg: NestGrid = world.house
		for attempt in 20:
			var c: int = hg.open_list[rng.randi() % hg.open_list.size()]
			if hg.room_at(c) in ["kitchen", "pantry", "living", "bathroom", "under_floor"]:
				spawn(kind, hg.center(c), AntSim.SPACE_HOUSE)
				return
		return
	var s: SurfaceWorld = world.surface
	var p := Vector2.ZERO
	if beh == "farmable" and s.flowers.size() > 0:
		p = s.flowers[rng.randi() % s.flowers.size()] + Vector2(rng.randf_range(-80, 80), rng.randf_range(-80, 80))
	elif beh in ["hunter", "raider"]:
		# Arrive from somewhere within a few metres of the colony.
		var e: Vector2 = world.nests[0].surface_pos
		for attempt in 10:
			p = e + Vector2(rng.randf_range(1500, 3500), 0).rotated(rng.randf() * TAU)
			if not s.is_blocked(p.x, p.y):
				break
	else:
		for attempt in 10:
			p = Vector2(rng.randf_range(300, s.size.x - 300), rng.randf_range(1500, s.size.y - 300))
			if not s.is_blocked(p.x, p.y):
				break
	p = p.clamp(Vector2(100, 1300), s.size - Vector2(100, 100))
	spawn(kind, p, AntSim.SPACE_SURFACE)


func step(dt: float) -> void:
	var rng: RandomNumberGenerator = world.rng_creatures
	var dead: Array = []
	for cr in list:
		cr["life"] += dt
		var d: Dictionary = defs[cr["kind"]]
		match cr["behaviour"]:
			"hunter": _hunter(cr, d, dt, rng)
			"raider": _raider(cr, d, dt, rng)
			"swooper": _swooper(cr, d, dt, rng)
			"burrower": _burrower(cr, d, dt, rng)
			"farmable": _farmable(cr, d, dt, rng)
			"mount": _mount(cr, d, dt, rng)
			_: _ambient(cr, d, dt, rng)
		if cr["behaviour"] in ["hunter", "raider", "burrower", "mount", "farmable"] and not cr["tame"]:
			_grapple(cr, d, dt, rng)
		if cr["hp"] <= 0.0:
			dead.append(cr)
		elif cr.get("leave", false):
			dead.append(cr)
	for cr in dead:
		if cr["hp"] <= 0.0:
			_die(cr)
		remove(cr["id"])
	if world.ants.tick % 20 == 0:
		_check_encounters()


func _speed(cr: Dictionary, d: Dictionary) -> float:
	return float(d.get("speed", 10)) / (1.0 + 0.2 * cr["attached"])


func _move(cr: Dictionary, to: Vector2, spd: float, dt: float) -> void:
	var p: Vector2 = cr["pos"]
	var dv := to - p
	if dv.length() < 0.5:
		return
	cr["heading"] = lerp_angle(cr["heading"], dv.angle(), minf(1.0, 6.0 * dt))
	var np := p + Vector2(cos(cr["heading"]), sin(cr["heading"])) * spd * dt
	if cr["space"] == AntSim.SPACE_SURFACE:
		var s: SurfaceWorld = world.surface
		if s.is_blocked(np.x, np.y) and cr["size"] < 100.0:
			cr["heading"] += 1.2
			return
		np = np.clamp(Vector2(20, 20), s.size - Vector2(20, 20))
	elif cr["space"] == AntSim.SPACE_HOUSE:
		if not world.house.passable(np):
			cr["heading"] += 1.5
			return
	cr["pos"] = np


func _wander(cr: Dictionary, d: Dictionary, dt: float, rng: RandomNumberGenerator, spd_mult: float = 0.5) -> void:
	if cr["pos"].distance_to(cr["goal"]) < 20.0 or rng.randf() < 0.002:
		cr["goal"] = cr["pos"] + Vector2(rng.randf_range(100, 600), 0).rotated(rng.randf() * TAU)
	_move(cr, cr["goal"], _speed(cr, d) * spd_mult, dt)


func _flee_edge(cr: Dictionary, d: Dictionary, dt: float) -> void:
	var p: Vector2 = cr["pos"]
	var s: SurfaceWorld = world.surface
	var to := Vector2(0 if p.x < s.size.x * 0.5 else s.size.x, p.y)
	_move(cr, to, _speed(cr, d) * 1.2, dt)
	if p.x < 60 or p.x > s.size.x - 60:
		cr["leave"] = true


func _hunter(cr: Dictionary, d: Dictionary, dt: float, rng: RandomNumberGenerator) -> void:
	var ants: AntSim = world.ants
	if cr["hp"] < cr["max_hp"] * 0.35 or cr["life"] > 600.0 or not world.surface_open() and world.ants.tick % 2 == 0:
		cr["state"] = "flee"
	if cr["state"] == "flee":
		_flee_edge(cr, d, dt)
		return
	if cr["state"] == "eat":
		cr["timer"] -= dt
		if cr["timer"] <= 0.0:
			cr["state"] = "hunt"
		return
	if _fear_musk(cr):
		cr["state"] = "flee"
		return
	if ants.tick % 20 == cr["id"] % 20:
		var best := -1
		var best_score := INF
		for j in ants.ants_near(cr["space"], cr["pos"], 500.0, 40):
			var score: float = ants.pos[j].distance_to(cr["pos"]) + ants.count_in_cell(j) * 120.0
			if score < best_score:
				best_score = score
				best = j
		cr["target"] = best
	var t: int = cr["target"]
	if t >= 0 and ants.is_alive(t) and ants.space_of(t) == cr["space"]:
		_move(cr, ants.pos[t], _speed(cr, d), dt)
		cr["state"] = "hunt"
	else:
		_wander(cr, d, dt, rng)


func _raider(cr: Dictionary, d: Dictionary, dt: float, rng: RandomNumberGenerator) -> void:
	if cr["hp"] < cr["max_hp"] * 0.3 or cr["life"] > 700.0:
		_flee_edge(cr, d, dt)
		return
	var s: SurfaceWorld = world.surface
	var t: int = cr["target"]
	if not s.foods.has(t) or world.ants.tick % 100 == cr["id"] % 100:
		t = -1
		var bd := 2500.0
		for f in s.foods.values():
			if f["space"] == 0 and f["weight"] <= 0.0:
				var dd: float = f["pos"].distance_to(cr["pos"])
				if dd < bd:
					bd = dd
					t = f["id"]
		cr["target"] = t
	if t >= 0:
		var f: Dictionary = s.foods[t]
		if cr["pos"].distance_to(f["pos"]) < f["radius"] + 8.0:
			s.take_food(t, 4.0 * dt)
		else:
			_move(cr, f["pos"], _speed(cr, d), dt)
	else:
		_wander(cr, d, dt, rng)


func _swooper(cr: Dictionary, d: Dictionary, dt: float, rng: RandomNumberGenerator) -> void:
	cr["timer"] -= dt
	match cr["state"]:
		"circle":
			if cr["timer"] <= 0.0:
				# Pick the busiest open trail: the surface ant with the most neighbours.
				var ants: AntSim = world.ants
				var best := -1
				var best_n := 2
				for k in 40:
					if ants.n == 0:
						break
					var j := rng.randi() % ants.n
					if ants.is_alive(j) and ants.layer[j] == AntSim.LAYER_SURFACE and ants.faction[j] == 0:
						var cnt := ants.count_in_cell(j)
						if cnt > best_n and not world.surface.in_shade(ants.pos[j]):
							best_n = cnt
							best = j
				if best < 0:
					cr["leave"] = cr["life"] > 40.0
					cr["timer"] = 5.0
					return
				cr["pos"] = ants.pos[best]
				cr["state"] = "shadow"
				cr["timer"] = 3.0
				Events.telegraph.emit("bird", cr["pos"], AntSim.SPACE_SURFACE, 3.0)
		"shadow":
			if cr["timer"] <= 0.0:
				var ants: AntSim = world.ants
				var killed := 0
				for j in ants.ants_near(AntSim.SPACE_SURFACE, cr["pos"], 45.0, 30):
					ants.kill(j, "bird")
					killed += 1
				Events.sfx.emit("swoop", cr["pos"], AntSim.SPACE_SURFACE)
				if killed > 0:
					Events.alert.emit("bird", "A %s snatched %d ants off a busy trail!" % [d.get("name", "bird"), killed], cr["pos"], AntSim.SPACE_SURFACE)
				cr["state"] = "leave"
				cr["timer"] = 1.0
		_:
			if cr["timer"] <= 0.0:
				cr["leave"] = true


func _burrower(cr: Dictionary, d: Dictionary, dt: float, rng: RandomNumberGenerator) -> void:
	if cr["space"] < AntSim.SPACE_NEST0:
		_ambient(cr, d, dt, rng)
		return
	var g: NestGrid = world.nests[cr["space"] - AntSim.SPACE_NEST0]
	cr["heading"] += rng.randf_range(-1.0, 1.0) * dt
	var p: Vector2 = cr["pos"] + Vector2(cos(cr["heading"]), sin(cr["heading"])) * float(d.get("speed", 6)) * dt
	var sz := g.size_mm()
	if p.x < 8 or p.y < 40 or p.x > sz.x - 8 or p.y > sz.y - 8:
		cr["heading"] += PI
		return
	var c_old := g.cell_at(cr["pos"])
	cr["pos"] = p
	var c := g.cell_at(p)
	if c != c_old and c >= 0 and g.solidity[c] == 0 and rng.randf() < 0.35 and c / g.w > 2:
		# The worm's passage collapses the tunnel behind it.
		if g.fill(c, "rubble"):
			world.on_cells_filled(cr["space"] - AntSim.SPACE_NEST0, PackedInt32Array([c]), "earthworm")
	if cr["life"] > 300.0:
		cr["leave"] = true


func _farmable(cr: Dictionary, d: Dictionary, dt: float, rng: RandomNumberGenerator) -> void:
	_wander(cr, d, dt, rng, 0.2)
	if world.ants.tick % 20 == cr["id"] % 20:
		var near: PackedInt32Array = world.ants.ants_near(cr["space"], cr["pos"], 40.0, 4)
		for j in near:
			if world.ants.faction[j] == 0:
				cr["tended"] = 60.0
				break
	cr["tended"] = maxf(cr["tended"] - dt, 0.0)
	var col = world.colonies[0]
	if col.has_unlock("behaviour:aphid_ranching") and cr["tended"] > 0.0:
		cr["produce"] += dt
		if cr["produce"] >= 20.0:
			cr["produce"] = 0.0
			world.surface.add_food("honeydew", cr["pos"] + Vector2(rng.randf_range(-6, 6), rng.randf_range(-6, 6)), 0, 1.0, Clock.tick, Clock.ticks_per_hour)
			world.stats["honeydew"] = world.stats.get("honeydew", 0) + 1
	if cr["life"] > 2400.0:
		cr["leave"] = true


func _mount(cr: Dictionary, d: Dictionary, dt: float, rng: RandomNumberGenerator) -> void:
	if not cr["tame"]:
		_wander(cr, d, dt, rng, 0.3)
		if cr["life"] > 1800.0:
			cr["leave"] = true
		return
	var s: SurfaceWorld = world.surface
	var home: Vector2 = world.nests[0].surface_pos
	var carrying: int = cr["carrying"]
	if carrying >= 0 and s.foods.has(carrying):
		# Haul a huge load home alone.
		_move(cr, home, float(d.get("speed", 30)) * 1.2, dt)
		s.move_food(carrying, cr["pos"] + Vector2(cos(cr["heading"]), sin(cr["heading"])) * cr["size"] * 0.4)
		if cr["pos"].distance_to(home) < 40.0:
			var f: Dictionary = s.foods[carrying]
			world.colonies[0].add_store(f["type"], f["amount"], world.nests[0])
			s.remove_food(carrying)
			cr["carrying"] = -1
		return
	cr["carrying"] = -1
	if world.rally_active(0):
		_move(cr, world.rally_point(0), float(d.get("speed", 30)), dt)
	else:
		var best := -1
		var bd := 1500.0
		for f in s.foods.values():
			if f["space"] == 0 and f["weight"] > 0.0:
				var dd: float = f["pos"].distance_to(cr["pos"])
				if dd < bd:
					bd = dd
					best = f["id"]
		if best >= 0:
			var f: Dictionary = s.foods[best]
			_move(cr, f["pos"], float(d.get("speed", 30)), dt)
			if cr["pos"].distance_to(f["pos"]) < cr["size"] * 0.6:
				cr["carrying"] = best
				world.ants.release_haulers(best)
		elif cr["pos"].distance_to(home) > 300.0:
			_move(cr, home, float(d.get("speed", 30)) * 0.6, dt)
		else:
			_wander(cr, d, dt, rng, 0.2)
	# Smash rival ants.
	cr["bite"] -= dt
	if cr["bite"] <= 0.0:
		cr["bite"] = float(d.get("attack_interval", 1.0))
		for j in world.ants.ants_near(cr["space"], cr["pos"], cr["size"] * 0.7, 6):
			if world.ants.faction[j] != 0:
				world.ants.kill(j, "beetle")


func _ambient(cr: Dictionary, d: Dictionary, dt: float, rng: RandomNumberGenerator) -> void:
	if float(d.get("speed", 0)) <= 0.0:
		if cr["life"] > 900.0:
			cr["leave"] = true
		return
	if cr["behaviour"] == "ambient_flyer":
		var p: Vector2 = cr["pos"] + Vector2(cos(cr["heading"]), sin(cr["heading"])) * float(d.get("speed", 100)) * dt
		cr["heading"] += sin(cr["life"] * 2.0 + cr["id"]) * dt
		cr["pos"] = p
		var s: SurfaceWorld = world.surface
		if cr["space"] == AntSim.SPACE_SURFACE and (p.x < 0 or p.y < 0 or p.x > s.size.x or p.y > s.size.y):
			cr["leave"] = true
	else:
		_wander(cr, d, dt, rng, 0.6)
	if cr["life"] > 600.0:
		cr["leave"] = true


func _fear_musk(cr: Dictionary) -> bool:
	if not world.colonies[0].has_unlock("behaviour:fear_musk"):
		return false
	var ph: PheromoneField = world.pher[cr["space"]]
	return ph.sample(cr["pos"].x, cr["pos"].y, PheromoneField.ALARM) > 40.0


## Grapple combat: attach ants, take damage, bite, shake off.
func _grapple(cr: Dictionary, d: Dictionary, dt: float, rng: RandomNumberGenerator) -> void:
	var ants: AntSim = world.ants
	var id: int = cr["id"]
	var reach: float = cr["size"] * 0.55 + 4.0
	var near := ants.ants_near(cr["space"], cr["pos"], reach, 48)
	var attached := 0
	var dmg := 0.0
	var hostile: bool = cr["behaviour"] in ["hunter", "raider"]
	var ph: PheromoneField = world.pher[cr["space"]]
	for j in near:
		var col = world.colonies[ants.home[j]]
		var ci: int = ants.caste[j]
		if ants.state[j] == AntSim.FIGHT and ants.target[j] == id:
			attached += 1
			dmg += col.c_attack[ci]
			ants.hold_at(j, cr["pos"] + Vector2(reach * 0.8, 0).rotated(j * 2.399))
		elif ants.state[j] != AntSim.HAUL and ants.state[j] != AntSim.FIGHT and ants.job[j] != AntSim.J_QUEEN:
			var aggressive: bool = ci == 1 or ci == 4 or ants.job[j] == AntSim.J_PATROL or ants.job[j] == AntSim.J_RALLY
			var defend: bool = hostile and rng.randf() < 0.25 * dt * 20.0 * 0.15
			if aggressive or defend or cr["behaviour"] == "farmable" and false:
				ants.attach(j, id)
				attached += 1
				dmg += col.c_attack[ci]
				if col.has_unlock("behaviour:trap_jaw") and (ci == 1 or ci == 4):
					cr["hp"] -= 8.0
	cr["attached"] = attached
	if attached > 0:
		var col0 = world.colonies[0]
		var mult := 1.3 if col0.has_unlock("behaviour:formic_spray") else 1.0
		cr["hp"] -= dmg * dt * mult
		if col0.has_unlock("behaviour:decapitate") and cr["size"] < 15.0 and rng.randf() < 0.02 * dt * attached:
			cr["hp"] = 0.0
		ph.deposit_spread(cr["pos"].x, cr["pos"].y, PheromoneField.ALARM, 40.0 * dt * 20.0 * col0.mult("combat.alarm_radius"))
		if ants.tick % 40 == 0:
			Events.sfx.emit("fight", cr["pos"], cr["space"])
	elif hostile and cr["state"] == "hunt":
		ph.deposit(cr["pos"].x, cr["pos"].y, PheromoneField.ALARM, 4.0)
	if not hostile and cr["behaviour"] != "burrower":
		return
	# Bite.
	cr["bite"] -= dt
	if cr["bite"] <= 0.0 and float(d.get("damage", 0)) > 0.0:
		cr["bite"] = float(d.get("attack_interval", 1.0))
		var victim := -1
		for j in near:
			if ants.state[j] == AntSim.FIGHT and ants.target[j] == id:
				victim = j
				break
		if victim < 0 and cr["behaviour"] == "hunter":
			var t: int = cr["target"]
			if t >= 0 and ants.is_alive(t) and ants.pos[t].distance_to(cr["pos"]) < reach + 4.0:
				victim = t
		if victim >= 0:
			var vcol = world.colonies[ants.home[victim]]
			ants.damage(victim, float(d.get("damage", 5)) * vcol.mult("combat.damage_taken"), cr["kind"])
			Events.sfx.emit("bite", cr["pos"], cr["space"])
			if not ants.is_alive(victim) and cr["behaviour"] == "hunter" and attached == 0:
				cr["state"] = "eat"
				cr["timer"] = 8.0
	# Shake off.
	cr["shake"] -= dt
	if cr["shake"] <= 0.0 and attached > 0:
		cr["shake"] = 1.5
		for j in near:
			if ants.state[j] == AntSim.FIGHT and ants.target[j] == id:
				var grip: float = world.colonies[ants.home[j]].c_grip[ants.caste[j]]
				if rng.randf() < 0.35 / grip:
					ants.detach(j, cr["pos"])


func _die(cr: Dictionary) -> void:
	var d: Dictionary = defs[cr["kind"]]
	var col = world.colonies[0]
	col.kills[cr["kind"]] = col.kills.get(cr["kind"], 0) + 1
	Events.creature_killed.emit(cr["kind"], cr["pos"])
	var loot: float = float(d.get("loot", 0)) * col.mult("creature.loot")
	if loot > 0.0 and cr["space"] <= AntSim.SPACE_HOUSE:
		world.surface.add_carcass(cr["kind"], cr["pos"], loot, float(d.get("weight", 1)), cr["space"], Clock.tick, Clock.ticks_per_hour)
	elif loot > 0.0:
		col.add_store("protein", loot, world.nests[cr["space"] - AntSim.SPACE_NEST0])


func feed_mount(id: int) -> String:
	var cr: Dictionary = by_id.get(id, {})
	if cr.is_empty() or cr["behaviour"] != "mount":
		return "Nothing to feed."
	if cr["tame"]:
		return "Already your loyal steed."
	if not world.colonies[0].spend({"sugar": 20.0}):
		return "Needs 20 sugar."
	cr["fed"] += 1
	if cr["fed"] >= 3:
		cr["tame"] = true
		world.stats["mount"] = true
		Events.toast.emit("The rhinoceros beetle is yours! Your champion climbs aboard.")
		Events.hint.emit("beetle_mount")
		return "Tamed!"
	return "Fed (%d/3)" % cr["fed"]


func _check_encounters() -> void:
	var ants: AntSim = world.ants
	for cr in list:
		var k: String = cr["kind"]
		if world.field_guide.has(k):
			continue
		var near := ants.ants_near(cr["space"], cr["pos"], cr["size"] * 0.5 + 150.0, 4)
		for j in near:
			if ants.faction[j] == 0:
				world.discover(k)
				break


func serialize() -> Dictionary:
	return {"list": list, "next_id": next_id}


func deserialize(d: Dictionary) -> void:
	list.clear()
	by_id.clear()
	for cr in d["list"]:
		list.append(cr)
		by_id[cr["id"]] = cr
	next_id = d["next_id"]
