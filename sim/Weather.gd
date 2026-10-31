class_name Weather
extends RefCounted
## Rain, heat waves, the sprinkler and the lawnmower, scheduled from seasons.json.
## Every event is telegraphed `telegraph_seconds` ahead with an on-map marker.

const MOWER_BAND := 250.0
const MOWER_SPEED := 600.0  # mm per second

var world
var events: Array[Dictionary] = []  # {kind, start, end, intensity, warned, pos}
var rain := 0.0
var heatwave := false
var sprinkler_active := false
var mower_active := false
var mower_x := 0.0
var speed_mult := 1.0
var telegraph_ticks := 600
var _erase_timer := 0.0


func _init(w = null) -> void:
	world = w
	telegraph_ticks = int(float(Data.table("seasons").get("telegraph_seconds", 30)) * Clock.TICK_HZ)


func season_def() -> Dictionary:
	return Data.table("seasons").get(Clock.season(), {})


## Roll today's events (called at midnight).
func on_day() -> void:
	if not world.flags.get("weather", false):
		return
	var rng: RandomNumberGenerator = world.rng_weather
	var ev: Dictionary = season_def().get("events", {})
	var chance_mult: float = float(world.diff.get("event_chance", 1.0)) * world.year_ramp()
	var day_start := Clock.tick + (Clock.ticks_per_hour * Clock.hours_per_day - (Clock.tick + Clock.offset_ticks) % (Clock.ticks_per_hour * Clock.hours_per_day)) % (Clock.ticks_per_hour * Clock.hours_per_day)
	for kind in ["rain", "heatwave", "sprinkler", "mower"]:
		var e: Dictionary = ev.get(kind, {})
		var ch: float = float(e.get("chance", 0.0)) * (chance_mult if kind != "sprinkler" else 1.0)
		if rng.randf() >= ch:
			continue
		var hour := 0
		var hours := 1.0
		var intensity := 1.0
		match kind:
			"rain":
				hour = rng.randi_range(1, 20)
				var hr: Array = e.get("hours", [2, 5])
				hours = rng.randf_range(hr[0], hr[1])
				var it: Array = e.get("intensity", [0.5, 1.0])
				intensity = rng.randf_range(it[0], it[1])
			"heatwave":
				hour = 10
				var hr2: Array = e.get("hours", [5, 7])
				hours = rng.randf_range(hr2[0], hr2[1])
			"sprinkler":
				var sp: Dictionary = world.surface.sprinkler
				if sp.is_empty():
					continue
				hour = int(sp.get("hour", 7))
				hours = float(sp.get("hours", 1))
			"mower":
				hour = rng.randi_range(9, 16)
				hours = world.surface.size.x / MOWER_SPEED / (Clock.ticks_per_hour * Clock.DT) + 0.2
		schedule(kind, day_start + hour * Clock.ticks_per_hour, hours, intensity)


func schedule(kind: String, start_tick: int, hours: float, intensity: float = 1.0) -> void:
	var pos := Vector2.ZERO
	var s: SurfaceWorld = world.surface
	match kind:
		"sprinkler":
			pos = s.sprinkler.get("pos", s.size * 0.5)
		"mower":
			pos = Vector2(0, s.size.y * 0.5)
		_:
			pos = world.nests[0].surface_pos
	events.append({"kind": kind, "start": start_tick, "end": start_tick + int(hours * Clock.ticks_per_hour), "intensity": intensity, "warned": false, "pos": pos})


## Start an event right now (campaign scripts, sandbox buttons); still telegraphed.
func trigger(kind: String, hours: float) -> void:
	schedule(kind, Clock.tick + telegraph_ticks, hours, 1.0)


func step(dt: float) -> void:
	var t := Clock.tick
	rain = 0.0
	heatwave = false
	sprinkler_active = false
	var mower_now := false
	var keep: Array[Dictionary] = []
	for e in events:
		if not e["warned"] and t >= e["start"] - telegraph_ticks:
			e["warned"] = true
			Events.telegraph.emit(e["kind"], e["pos"], AntSim.SPACE_SURFACE, float(e["start"] - t) / Clock.TICK_HZ)
			Events.alert.emit(e["kind"], _warning_text(e["kind"]), e["pos"], AntSim.SPACE_SURFACE)
			Events.hint.emit(e["kind"] if e["kind"] in ["rain", "mower"] else "rain")
		if t >= e["start"] and t < e["end"]:
			match e["kind"]:
				"rain": rain = maxf(rain, e["intensity"])
				"heatwave":
					var h := Clock.hour_f()
					heatwave = h >= 11.0 and h <= 16.0
				"sprinkler": sprinkler_active = true
				"mower":
					mower_now = true
					mower_x = float(t - e["start"]) * Clock.DT * MOWER_SPEED
					if mower_x > world.surface.size.x + MOWER_BAND:
						e["end"] = t
		if t < e["end"]:
			keep.append(e)
	events = keep
	mower_active = mower_now
	speed_mult = 1.0 - 0.3 * rain
	var surf_ph: PheromoneField = world.pher[AntSim.SPACE_SURFACE]
	surf_ph.rate_mult = 1.0 + rain * (float(Data.table("pheromones").get("rain_decay_mult", 40.0)) - 1.0)
	_erase_timer -= dt
	if _erase_timer <= 0.0:
		_erase_timer = 5.0
		if sprinkler_active:
			var sp: Dictionary = world.surface.sprinkler
			surf_ph.erase(sp["pos"], float(sp.get("radius", 2000)), [0, 1, 5, 6])
	if mower_active:
		_mow()


func _warning_text(kind: String) -> String:
	match kind:
		"rain": return "Rain clouds gathering - trails will wash away and low chambers may flood."
		"heatwave": return "Heat wave coming - the open surface will be deadly at midday."
		"sprinkler": return "The sprinkler is about to switch on!"
		"mower": return "LAWNMOWER INCOMING - clear the grass!"
	return kind


func _mow() -> void:
	var s: SurfaceWorld = world.surface
	for f in s.foods.values():
		if f["space"] == 0 and absf(f["pos"].x - mower_x) < MOWER_BAND and _mowable(f["pos"]):
			s.remove_food(f["id"])
	for cr in world.creatures.list:
		if cr["space"] == 0 and absf(cr["pos"].x - mower_x) < MOWER_BAND and _mowable(cr["pos"]) and cr["behaviour"] not in ["swooper", "ambient_flyer"]:
			cr["hp"] = 0.0


func _mowable(p: Vector2) -> bool:
	var s: SurfaceWorld = world.surface
	var g := s.ground_at(p)
	return (g == SurfaceWorld.G_GRASS or g == SurfaceWorld.G_DIRT) and not s.is_blocked(p.x, p.y) and not s.in_shade(p)


func mower_kills(p: Vector2) -> bool:
	return mower_active and absf(p.x - mower_x) < MOWER_BAND and _mowable(p)


func surface_temp() -> float:
	var s := season_def()
	var t := lerpf(float(s.get("temp_night", 10)), float(s.get("temp_day", 20)), Clock.daylight())
	if heatwave:
		t += 12.0
	return t - rain * 3.0


func surface_open() -> bool:
	return bool(season_def().get("surface_open", true))


func in_sprinkler(p: Vector2) -> bool:
	if not sprinkler_active:
		return false
	var sp: Dictionary = world.surface.sprinkler
	return p.distance_to(sp["pos"]) < float(sp.get("radius", 2000))


## Rain intensity reaching a nest (global rain or the sprinkler over its entrance).
func rain_at(p: Vector2) -> float:
	return maxf(rain, 0.8 if in_sprinkler(p) else 0.0)


## Damage per second for an ant at p on a layer.
func hazard_damage(p: Vector2, lyr: int, col) -> float:
	if lyr != AntSim.LAYER_SURFACE:
		return 0.0
	var d := 0.0
	if heatwave and not world.surface.in_shade(p):
		d += 0.9 / col.mult("env.heat_resist")
	var t := surface_temp()
	if t < 3.0:
		d += (3.0 - t) * 0.08 / col.mult("env.cold_resist")
	if in_sprinkler(p) and not col.has_unlock("behaviour:raft") and not col.has_unlock("behaviour:living_bridges"):
		d += 0.35 / col.mult("env.flood_resist")
	return d


func hazard_name(lyr: int) -> String:
	if lyr == AntSim.LAYER_HOUSE:
		return "pesticide"
	if heatwave:
		return "heatstroke"
	if sprinkler_active:
		return "drowned"
	return "cold"


func upcoming() -> Array:
	var out := []
	for e in events:
		if e["start"] > Clock.tick:
			out.append({"kind": e["kind"], "in_seconds": float(e["start"] - Clock.tick) / Clock.TICK_HZ, "pos": e["pos"], "warned": e["warned"]})
	return out


func serialize() -> Dictionary:
	return {"events": events, "mower_x": mower_x, "erase_timer": _erase_timer}


func deserialize(d: Dictionary) -> void:
	events.clear()
	for e in d["events"]:
		events.append(e)
	mower_x = d["mower_x"]
	_erase_timer = d.get("erase_timer", 0.0)
