class_name HouseAI
extends RefCounted
## The house: meal crumbs, the cat, the homeowner and an escalation meter driven by
## ant sightings. Level 5 summons the Exterminator: fog the rooms, trace the trail
## back to the nest, dig for the queen.

var world
var cfg: Dictionary = {}
var esc_cfg: Dictionary = {}
var meter := 0.0
var level := 0
var max_level := 0
var person_room := "away"
var person_pos := Vector2.ZERO
var cat_pos := Vector2.ZERO
var cat_goal := Vector2.ZERO
var cat_sleeping := false
var cat_swat := 0.0
var sprays: Array[Dictionary] = []  # {pos, radius, until}
var baits_placed := false
var wipe_timer := 0.0
var last_wipe_hour := -99

# Exterminator.
var ext_phase := ""  # "", warn, fog, trace, dig, done
var ext_timer := 0.0
var ext_pos := Vector2.ZERO
var ext_heading := 0.0
var ext_fog_room := ""
var ext_dig_depth := 0.0
var ext_dig_x := 0.0
var ext_defeated := false
var ext_started := false
var queen_relocating := 0.0
var relocate_target := -1


func _init(w = null) -> void:
	world = w
	cfg = Data.table("house")
	esc_cfg = cfg.get("escalation", {})


func setup() -> void:
	var hg: NestGrid = world.house
	person_pos = _room_floor("kitchen")
	cat_pos = _room_floor("living")
	cat_goal = cat_pos
	var ws: Dictionary = cfg.get("water_spot", {})
	if not ws.is_empty():
		var c: Array = ws["cell"]
		world.surface.add_food(ws["food"], hg.center(int(c[1]) * hg.w + int(c[0])), AntSim.SPACE_HOUSE, 1.0, Clock.tick, Clock.ticks_per_hour)


func _room_rect(room: String) -> Rect2:
	var r: Array = cfg["rooms"].get(room, {}).get("rect", [6, 40, 88, 45])
	var hg: NestGrid = world.house
	return Rect2(r[0] * hg.cell, r[1] * hg.cell, r[2] * hg.cell, r[3] * hg.cell)


func _room_floor(room: String) -> Vector2:
	var r := _room_rect(room)
	return Vector2(r.position.x + r.size.x * 0.5, r.end.y - world.house.cell * 0.5)


func _scheduled_room(hour: int) -> String:
	for s in cfg.get("schedule", []):
		var a := int(s["from"])
		var b := int(s["to"])
		if (a < b and hour >= a and hour < b) or (a > b and (hour >= a or hour < b)):
			return s["room"]
	return "away"


func on_hour(hour: int) -> void:
	if world.house == null:
		return
	person_room = _scheduled_room(hour)
	meter = maxf(meter - float(esc_cfg.get("decay_per_hour", 3.0)), 0.0)
	_update_level()
	var rng: RandomNumberGenerator = world.rng_house
	var hg: NestGrid = world.house
	if hour in cfg.get("meals", []) and person_room != "away":
		for spot in cfg.get("food_spots", []):
			if not spot.get("meal", false):
				continue
			var foods: Array = spot["foods"]
			var c: Array = spot["cell"]
			var amt := 0.5 if level >= 2 else 1.0
			world.surface.add_food(foods[rng.randi() % foods.size()], hg.center(int(c[1]) * hg.w + int(c[0])), AntSim.SPACE_HOUSE, amt, Clock.tick, Clock.ticks_per_hour)
	if hour == 6:
		for spot in cfg.get("food_spots", []):
			if spot.get("pantry", false) and level < 2:
				var c: Array = spot["cell"]
				world.surface.add_food("crumb_pile", hg.center(int(c[1]) * hg.w + int(c[0])), AntSim.SPACE_HOUSE, 0.6, Clock.tick, Clock.ticks_per_hour)
	# Level 1: wipe the counter (erase scent + crumbs in the kitchen).
	if level >= 1 and person_room == "kitchen" and hour - last_wipe_hour >= int(esc_cfg.get("wipe_interval_hours", 3)):
		last_wipe_hour = hour
		var r := _room_rect("kitchen")
		var ph: PheromoneField = world.pher[AntSim.SPACE_HOUSE]
		ph.erase(r.get_center(), r.size.length() * 0.5, [0, 1, 3, 4])
		for f in world.surface.foods_in_space(AntSim.SPACE_HOUSE):
			if r.has_point(f["pos"]) and f["type"] != "poison" and f["type"] != "water":
				world.surface.remove_food(f["id"])
		Events.toast.emit("The homeowner wiped the counter. Kitchen trails erased.")
	# Level 3: bait traps.
	if level >= 3 and not baits_placed:
		baits_placed = true
		for i in int(esc_cfg.get("bait_count", 3)):
			var spot: Dictionary = cfg["food_spots"][i % cfg["food_spots"].size()]
			var c: Array = spot["cell"]
			world.surface.add_food("bait", hg.center(int(c[1]) * hg.w + int(c[0]) + 3), AntSim.SPACE_HOUSE, 1.0, Clock.tick, Clock.ticks_per_hour)
		Events.alert.emit("bait", "Bait traps placed! Poison carried home will sicken the brood.", _room_floor("kitchen"), AntSim.SPACE_HOUSE)
	var keep: Array[Dictionary] = []
	for s in sprays:
		if s["until"] > Clock.tick:
			keep.append(s)
	sprays = keep


func _update_level() -> void:
	var th: Array = esc_cfg.get("thresholds", [10, 30, 60, 100, 150])
	var lv := 0
	for i in th.size():
		if meter >= float(th[i]):
			lv = i + 1
	if ext_defeated:
		lv = mini(lv, 2)
	if lv != level:
		var up := lv > level
		level = lv
		max_level = maxi(max_level, level)
		Events.escalation_changed.emit(level)
		if up:
			Events.hint.emit("escalation")
		if level >= 5 and not ext_started:
			start_exterminator()


func add_escalation(amount: float) -> void:
	meter += amount
	_update_level()


func step(dt: float) -> void:
	if world.house == null:
		return
	var ants: AntSim = world.ants
	var hg: NestGrid = world.house
	# Homeowner moves to the scheduled room.
	if person_room != "away":
		person_pos = person_pos.move_toward(_room_floor(person_room), 900.0 * dt)
		if ants.tick % 20 == 0:
			var rdef: Dictionary = cfg["rooms"].get(person_room, {})
			if rdef.get("lit", false):
				var seen := 0
				var room_rect := _room_rect(person_room)
				for j in ants.ants_near(AntSim.SPACE_HOUSE, person_pos, float(esc_cfg.get("sight_radius_mm", 1400.0)), 200):
					if ants.faction[j] == 0 and room_rect.has_point(ants.pos[j]):
						seen += 1
				if seen > 0:
					var mult: float = float(world.diff.get("escalation", 1.0)) * world.colonies[0].mult("house.escalation")
					meter += seen * float(esc_cfg.get("per_ant_seen_hour", 1.0)) * 20.0 / Clock.ticks_per_hour * mult
					_update_level()
					if level >= 4 and ants.tick % 400 == 0:
						_spray(person_pos + Vector2(world.rng_house.randf_range(-400, 400), 0))
	# Cat.
	var h := Clock.hour_f()
	cat_sleeping = false
	for win in cfg["cat"].get("sleep", []):
		if h >= float(win[0]) and h < float(win[1]):
			cat_sleeping = true
	var cc: Dictionary = cfg["cat"]
	if cat_sleeping:
		var sb: Array = cc.get("sunbeam", [160, 84])
		cat_pos = cat_pos.move_toward(hg.center(int(sb[1]) * hg.w + int(sb[0])), float(cc.get("speed", 160)) * dt)
	else:
		if cat_pos.distance_to(cat_goal) < 30.0:
			var rooms: Array = cc.get("rooms", ["kitchen"])
			var r := _room_rect(rooms[world.rng_house.randi() % rooms.size()])
			cat_goal = Vector2(world.rng_house.randf_range(r.position.x + 100, r.end.x - 100), r.end.y - hg.cell * 0.5)
		cat_pos = cat_pos.move_toward(cat_goal, float(cc.get("speed", 160)) * dt)
		cat_swat -= dt
		if cat_swat <= 0.0:
			cat_swat = float(cc.get("swat_interval", 1.2))
			var victims := ants.ants_near(AntSim.SPACE_HOUSE, cat_pos, float(cc.get("swat_radius_mm", 70.0)), int(cc.get("swat_kills", 4)))
			for j in victims:
				ants.kill(j, "cat")
			if victims.size() > 0:
				Events.sfx.emit("cat_swat", cat_pos, AntSim.SPACE_HOUSE)
				world.discover("house_cat")
	if person_room != "away" and ants.tick % 100 == 0:
		for j in ants.ants_near(AntSim.SPACE_HOUSE, person_pos, 1500.0, 1):
			world.discover("homeowner")
	_step_exterminator(dt)
	if queen_relocating > 0.0:
		queen_relocating -= dt
		if queen_relocating <= 0.0:
			world.finish_queen_relocation(relocate_target)


func _spray(p: Vector2) -> void:
	sprays.append({"pos": p, "radius": float(esc_cfg.get("spray_radius_mm", 300.0)), "until": Clock.tick + int(float(esc_cfg.get("spray_hours", 6)) * Clock.ticks_per_hour)})
	Events.sfx.emit("spray_hiss", p, AntSim.SPACE_HOUSE)


## Damage per second at p in the house (spray clouds + exterminator fog).
func hazard_damage(p: Vector2) -> float:
	var d := 0.0
	for s in sprays:
		if p.distance_to(s["pos"]) < s["radius"]:
			d += float(esc_cfg.get("spray_damage", 4.0))
	if ext_phase == "fog" and ext_fog_room != "" and _room_rect(ext_fog_room).grow(40.0).has_point(p):
		d += float(cfg["exterminator"].get("fog_damage", 2.5))
	return d


# ---------------------------------------------------------------- exterminator

func start_exterminator() -> void:
	ext_started = true
	ext_phase = "warn"
	ext_timer = 30.0
	Events.telegraph.emit("exterminator", _room_floor("kitchen"), AntSim.SPACE_HOUSE, 30.0)
	Events.alert.emit("exterminator", "The homeowner made a phone call. THE EXTERMINATOR is coming.", _room_floor("kitchen"), AntSim.SPACE_HOUSE)
	Events.hint.emit("exterminator")
	Events.sfx.emit("exterminator", Vector2.ZERO, AntSim.SPACE_HOUSE)
	world.discover("exterminator")


func _step_exterminator(dt: float) -> void:
	if ext_phase == "" or ext_phase == "done":
		return
	var ec: Dictionary = cfg["exterminator"]
	ext_timer -= dt
	match ext_phase:
		"warn":
			if ext_timer <= 0.0:
				ext_phase = "fog"
				ext_timer = float(ec.get("fog_seconds", 240))
				Events.toast.emit("Phase 1: Fogging the house, room by room.")
		"fog":
			var rooms := ["kitchen", "pantry", "living", "bathroom"]
			var total := float(ec.get("fog_seconds", 240))
			var idx := clampi(int((1.0 - ext_timer / total) * rooms.size()), 0, rooms.size() - 1)
			if ext_fog_room != rooms[idx]:
				ext_fog_room = rooms[idx]
				Events.telegraph.emit("fog", _room_floor(ext_fog_room), AntSim.SPACE_HOUSE, 3.0)
				Events.sfx.emit("spray_hiss", Vector2.ZERO, AntSim.SPACE_HOUSE)
			if ext_timer <= 0.0:
				ext_fog_room = ""
				ext_phase = "trace"
				ext_timer = float(ec.get("trace_seconds", 300))
				var gaps: Array = world.surface.house_gaps
				ext_pos = (gaps[0] if gaps.size() > 0 else Vector2(world.surface.size.x * 0.5, 1300)) + Vector2(0, 150)
				ext_heading = PI * 0.5
				Events.toast.emit("Phase 2: He's following your trails back to the nest!")
				Events.telegraph.emit("exterminator", ext_pos, AntSim.SPACE_SURFACE, 3.0)
		"trace":
			_trace(dt, ec)
			if ext_timer <= 0.0 or ext_pos.distance_to(world.nests[0].surface_pos) < 120.0:
				if _queen_hidden():
					_win_exterminator("He lost the trail. The colony is safe!")
					return
				ext_phase = "dig"
				ext_timer = float(ec.get("dig_seconds", 360))
				ext_dig_depth = 0.0
				var g: NestGrid = world.nests[0]
				ext_dig_x = float(g.entrance_x)
				Events.toast.emit("Phase 3: He's DIGGING. Protect the queen!")
				Events.telegraph.emit("dig", world.nests[0].surface_pos, AntSim.SPACE_SURFACE, 3.0)
		"dig":
			_dig(dt, ec)
			if ext_timer <= 0.0:
				_win_exterminator("The exterminator gives up and drives away!")


func _trace(dt: float, ec: Dictionary) -> void:
	var ph: PheromoneField = world.pher[AntSim.SPACE_SURFACE]
	var target: Vector2 = world.nests[0].surface_pos
	var best := ext_heading
	var best_s := -1.0
	for k in 5:
		var a := ext_heading + (k - 2) * 0.4
		var q := ext_pos + Vector2(cos(a), sin(a)) * 150.0
		var s := ph.sample(q.x, q.y, PheromoneField.FOOD) + ph.sample(q.x, q.y, PheromoneField.HOME) + ph.sample(q.x, q.y, PheromoneField.PLAYER)
		if s > best_s:
			best_s = s
			best = a
	ext_heading = lerp_angle(ext_heading, best, 2.0 * dt)
	ext_heading = lerp_angle(ext_heading, (target - ext_pos).angle(), 0.35 * dt)
	ext_pos += Vector2(cos(ext_heading), sin(ext_heading)) * float(ec.get("speed", 120.0)) * dt
	ext_pos = ext_pos.clamp(Vector2(50, 1250), world.surface.size - Vector2(50, 50))
	var ants: AntSim = world.ants
	if ants.tick % 10 == 0:
		for j in ants.ants_near(AntSim.SPACE_SURFACE, ext_pos, float(ec.get("spray_radius_mm", 200.0)), 60):
			ants.kill(j, "exterminator")
		ph.erase(ext_pos, 120.0, [0, 1, 4])


func _dig(dt: float, ec: Dictionary) -> void:
	var g: NestGrid = world.nests[0]
	var col = world.colonies[0]
	var ants: AntSim = world.ants
	var qx := ext_dig_x
	if col.queen_ant >= 0 and ants.is_alive(col.queen_ant) and ants.layer[col.queen_ant] == AntSim.LAYER_NEST and ants.inside[col.queen_ant] == 0:
		qx = ants.pos[col.queen_ant].x / g.cell
	ext_dig_x = move_toward(ext_dig_x, qx, 0.25 * dt)
	var before := int(ext_dig_depth)
	ext_dig_depth += float(ec.get("dig_cells_per_second", 0.9)) * dt
	var after := int(ext_dig_depth)
	if after > before:
		world.exterminator_dig(int(ext_dig_x), after)


func _queen_hidden() -> bool:
	return world.colonies[0].queen_ant < 0 and queen_relocating > 0.0


func _win_exterminator(msg: String) -> void:
	ext_phase = "done"
	ext_defeated = true
	meter = 0.0
	level = 0
	Events.escalation_changed.emit(0)
	Events.toast.emit(msg)
	Events.alert.emit("victory", msg, Vector2.ZERO, AntSim.SPACE_SURFACE)
	world.stats["exterminator_defeated"] = true


func serialize() -> Dictionary:
	var out := {}
	for k in ["meter", "level", "max_level", "person_room", "person_pos", "cat_pos", "cat_goal", "cat_swat", "sprays", "baits_placed", "last_wipe_hour",
			"ext_phase", "ext_timer", "ext_pos", "ext_heading", "ext_fog_room", "ext_dig_depth", "ext_dig_x", "ext_defeated", "ext_started", "queen_relocating", "relocate_target"]:
		out[k] = get(k)
	return out


func deserialize(d: Dictionary) -> void:
	for k in d.keys():
		if k == "sprays":
			sprays.clear()
			for s in d[k]:
				sprays.append(s)
		else:
			set(k, d[k])
