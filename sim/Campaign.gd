class_name Campaign
extends RefCounted
## Runs a chapter script: objectives, timed/triggered events, completion.

var world
var chapter: Dictionary = {}
var done: Dictionary = {}
var fired: Dictionary = {}
var completed := false
var start_kills: Dictionary = {}
var start_harvest: Dictionary = {}
var survived_seasons: Dictionary = {}
var days_survived := 0


func _init(w = null, chapter_data: Dictionary = {}) -> void:
	world = w
	chapter = chapter_data


func active() -> bool:
	return not chapter.is_empty()


func objectives() -> Array:
	return chapter.get("objectives", [])


func step() -> void:
	if not active() or completed:
		return
	if Clock.tick % 20 != 0:
		return
	for o in objectives():
		if done.has(o["id"]):
			continue
		var p := progress(o)
		if p.x >= p.y:
			done[o["id"]] = true
			Events.objective_completed.emit(o["id"])
			Events.toast.emit("Objective complete: %s" % o.get("text", o["id"]))
			_fire_matching({"objective": o["id"]})
	if done.size() >= objectives().size() and objectives().size() > 0:
		completed = true
		Events.chapter_completed.emit(chapter.get("id", ""))


func on_start() -> void:
	_fire_matching({"start": true})


func on_hour(hour: int) -> void:
	if not active():
		return
	var day: int = Clock.day_index() - world.start_day_index + 1
	var evs: Array = chapter.get("events", [])
	for i in evs.size():
		if fired.has(i):
			continue
		var at: Dictionary = evs[i].get("at", {})
		if at.has("day") and int(at["day"]) <= day and int(at.get("hour", 0)) <= hour or at.has("day") and int(at["day"]) < day:
			fired[i] = true
			_run(evs[i])


func on_day() -> void:
	days_survived += 1


func on_season_end(season: String) -> void:
	survived_seasons[season] = true


func _fire_matching(at_match: Dictionary) -> void:
	var evs: Array = chapter.get("events", [])
	for i in evs.size():
		if fired.has(i):
			continue
		var at: Dictionary = evs[i].get("at", {})
		var ok := true
		for k in at_match.keys():
			if not at.has(k) or at[k] != at_match[k]:
				ok = false
		if ok:
			fired[i] = true
			_run(evs[i])


func _run(ev: Dictionary) -> void:
	var p: Dictionary = ev.get("params", {})
	match ev.get("type", ""):
		"hint":
			Events.hint.emit(p.get("id", ""))
		"dialog":
			Events.dialog.emit(p.get("speaker", ""), p.get("text", ""))
		"spawn":
			world.script_spawn(p.get("creature", "wolf_spider"), int(p.get("count", 1)), p.get("near", "random"))
		"weather":
			world.weather.trigger(p.get("kind", "rain"), float(p.get("hours", 2)))
		"food":
			world.script_food(p.get("food", "dropped_chip"), int(p.get("count", 1)), p.get("near", "random"))
		"escalation":
			if world.house_ai:
				var th: Array = world.house_ai.esc_cfg.get("thresholds", [10, 30, 60, 100, 150])
				var lvl := clampi(int(p.get("level", 1)), 1, th.size())
				world.house_ai.meter = maxf(world.house_ai.meter, float(th[lvl - 1]))
				world.house_ai.add_escalation(0.0)
		"season":
			var s: String = p.get("season", "spring")
			var si := Clock.season_names.find(s)
			if si >= 0:
				# Jump the calendar to the first hour of that season (same year).
				var d := (Clock.year() - 1) * Clock.days_per_season * Clock.season_names.size() + si * Clock.days_per_season
				Clock.offset_ticks = d * Clock.hours_per_day * Clock.ticks_per_hour - Clock.tick + 6 * Clock.ticks_per_hour
				Events.season_changed.emit(s)
		"trait_points":
			world.colonies[0].trait_points += int(p.get("amount", 1))
			Events.toast.emit("+%d trait points" % int(p.get("amount", 1)))


## Returns Vector2(current, target).
func progress(o: Dictionary) -> Vector2:
	var p: Dictionary = o.get("params", {})
	var col: Colony = world.colonies[0]
	match o.get("type", ""):
		"chambers":
			var t: String = p.get("type", "")
			var n := 0
			for c in world.player_colonies():
				n += world.nests[c.nest].count_ok_chambers(t)
			return Vector2(n, int(p.get("count", 1)))
		"population":
			var caste: String = p.get("caste", "")
			var n := 0
			for c in world.player_colonies():
				n += c.population() if caste == "" else c.counts[c.caste_index(caste)]
			return Vector2(n, int(p.get("count", 1)))
		"hatched":
			var n := 0
			for c in world.player_colonies():
				n += c.hatched
			return Vector2(n, int(p.get("count", 1)))
		"stores":
			var r: String = p.get("resource", "sugar")
			var n := 0.0
			for c in world.player_colonies():
				n += c.stores.get(r, 0.0)
			return Vector2(n, float(p.get("amount", 1)))
		"harvested":
			var r: String = p.get("resource", "sugar")
			var n := 0.0
			for c in world.player_colonies():
				n += c.harvested.get(r, 0.0)
			return Vector2(n - float(start_harvest.get(r, 0.0)), float(p.get("amount", 1)))
		"kills":
			var k: String = p.get("creature", "")
			return Vector2(int(col.kills.get(k, 0)) - int(start_kills.get(k, 0)), int(p.get("count", 1)))
		"survive_days":
			return Vector2(days_survived, int(p.get("days", 1)))
		"survive_season":
			return Vector2(1 if survived_seasons.has(p.get("season", "winter")) else 0, 1)
		"rival_destroyed":
			return Vector2(1 if world.stats.get("rival_destroyed", false) else 0, 1)
		"reach_house":
			return Vector2(1 if world.stats.get("reached_house", false) else 0, 1)
		"traits":
			return Vector2(col.traits.size() - int(world.start_traits), int(p.get("count", 1)))
		"satellites":
			return Vector2(int(world.stats.get("satellites", 0)), int(p.get("count", 1)))
		"exterminator_defeated":
			return Vector2(1 if world.stats.get("exterminator_defeated", false) else 0, 1)
		"flight":
			return Vector2(mini(int(world.stats.get("flights", 0)), 1), 1)
	return Vector2(0, 1)


func serialize() -> Dictionary:
	return {"chapter_id": chapter.get("id", ""), "done": done, "fired": fired, "completed": completed, "start_kills": start_kills,
		"start_harvest": start_harvest, "survived_seasons": survived_seasons, "days_survived": days_survived}


func deserialize(d: Dictionary) -> void:
	chapter = Data.campaign.get(d["chapter_id"], {})
	done = d["done"]
	fired = d["fired"]
	completed = d["completed"]
	start_kills = d["start_kills"]
	start_harvest = d["start_harvest"]
	survived_seasons = d["survived_seasons"]
	days_survived = d["days_survived"]
