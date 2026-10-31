extends GutTest
## Unit tests: brood stages, feeding, diet, starvation of larvae, queen egg budget.

const SPRING := {"egg_rate": 1.0}

var g: NestGrid
var col: Colony
var rng := RandomNumberGenerator.new()


func before_each() -> void:
	g = NestGrid.new()
	var r := RandomNumberGenerator.new()
	r.seed = 3
	g.generate_nest(r, Vector2i(64, 48))  # starter cavity = queen chamber (50 cells)
	col = Colony.new()
	col.stores = {"sugar": 100.0, "protein": 100.0, "seeds": 0.0, "fungus": 0.0, "water": 20.0, "leaf": 0.0, "poison": 0.0}
	rng.seed = 1


func _brood(stage: int, caste: String = "", fed: int = 0, protein: int = 0) -> Dictionary:
	return {"stage": stage, "age": 0.0, "caste": caste, "fed": fed, "protein": protein, "hunger": 0.0, "chamber": 0, "sick": 0.0, "royal": false}


func _hour(nursing_ticks: float = 0.0) -> Array:
	col.nursing_power = nursing_ticks
	return col.on_hour(g, SPRING, {}, rng, Data.table("nest")["env"])


func _set_counts(workers: int) -> void:
	var arr := PackedInt32Array()
	arr.resize(col.caste_names.size())
	arr[col.caste_index("worker")] = workers
	arr[col.caste_index("queen")] = 1
	col.counts = arr


func test_development_speed_peaks_at_25_to_30_degrees() -> void:
	assert_eq(Colony.dev_speed(27.0), 1.5)
	assert_lt(Colony.dev_speed(14.0), Colony.dev_speed(22.0))
	assert_lt(Colony.dev_speed(22.0), Colony.dev_speed(27.0))
	assert_lt(Colony.dev_speed(36.0), Colony.dev_speed(29.0))
	assert_gt(Colony.dev_speed(0.0), 0.0, "cold slows brood but never freezes it completely")


func test_egg_larva_pupa_adult_timeline_follows_temperature() -> void:
	col.queen_alive = false  # no new eggs: follow a single brood item
	col.brood.append(_brood(Colony.STAGE_EGG))
	var speed := Colony.dev_speed(g.chamber_avg(0, "temperature"))
	var stage_hours := {}
	var hatched: Array = []
	for hour in range(1, 200):
		hatched = _hour(Clock.ticks_per_hour)  # one full-time nurse
		if hatched.size() > 0:
			stage_hours["adult"] = hour
			break
		var st: int = col.brood[0]["stage"]
		if not stage_hours.has(st):
			stage_hours[st] = hour
	assert_eq(stage_hours.get(Colony.STAGE_LARVA, -1), int(ceil(Colony.EGG_HOURS / speed)), "egg hatches after 8 h of development")
	var larva_h: int = stage_hours[Colony.STAGE_PUPA] - stage_hours[Colony.STAGE_LARVA]
	assert_eq(larva_h, int(ceil(Colony.LARVA_MIN_HOURS / speed)), "a well-fed larva pupates after its minimum growth time")
	assert_eq(int(stage_hours["adult"]) - int(stage_hours[Colony.STAGE_PUPA]), int(ceil(Colony.PUPA_HOURS / speed)))
	assert_eq(hatched, ["worker"])
	assert_eq(col.hatched, 1)
	assert_eq(col.brood.size(), 0)


func test_unfed_larva_dies() -> void:
	col.queen_alive = false
	col.brood.append(_brood(Colony.STAGE_LARVA, "worker"))
	for hour in int(Colony.LARVA_STARVE):
		_hour(0.0)
	assert_eq(col.brood.size(), 1, "still alive after %d hungry hours" % int(Colony.LARVA_STARVE))
	_hour(0.0)
	assert_eq(col.brood.size(), 0, "starved")
	assert_eq(col.deaths.get("brood_starved", 0), 1)


func test_claustral_queen_feeds_first_brood_herself() -> void:
	col.egg_rate = 0.0
	for k in 3:
		col.brood.append(_brood(Colony.STAGE_LARVA, "worker"))
	for hour in 30:
		_hour(0.0)
	assert_eq(col.deaths.get("brood_starved", 0), 0, "with no workers the queen keeps her first larvae alive")


func test_soldier_larva_needs_protein() -> void:
	col.queen_alive = false
	col.stores["protein"] = 0.0
	col.brood.append(_brood(Colony.STAGE_LARVA, "soldier"))
	var out: Array = []
	for hour in 200:
		out.append_array(_hour(Clock.ticks_per_hour))
	assert_eq(out, ["worker"], "a sugar-fed soldier larva grows into a worker")
	col.stores["protein"] = 100.0
	col.brood.append(_brood(Colony.STAGE_LARVA, "soldier"))
	out.clear()
	for hour in 200:
		out.append_array(_hour(Clock.ticks_per_hour))
	assert_eq(out, ["soldier"], "with protein it becomes a soldier")


func test_queen_holds_eggs_when_food_cannot_cover_upkeep() -> void:
	_set_counts(40)  # 40 workers eat 40 x 0.5 + queen 4 = 24 per day
	col.stores = {"sugar": 20.0, "protein": 0.0, "seeds": 0.0, "fungus": 0.0, "water": 20.0, "leaf": 500.0, "poison": 0.0}
	for hour in 6:
		_hour(0.0)
	assert_eq(col.brood.size(), 0, "no eggs while edible food is below a day of upkeep (leaves don't count)")
	col.stores["sugar"] = 200.0
	for hour in 6:
		_hour(0.0)
	assert_gt(col.brood.size(), 0, "lays again once fed")


func test_adults_eat_before_larvae() -> void:
	_set_counts(20)
	col.queen_alive = false
	# Adult upkeep = 20 workers x 0.5 + queen 4 = 14: exactly one day's meals in store.
	col.stores = {"sugar": 14.0, "protein": 0.0, "seeds": 0.0, "fungus": 0.0, "water": 20.0, "leaf": 0.0, "poison": 0.0}
	for k in 5:
		col.brood.append(_brood(Colony.STAGE_LARVA, "worker"))
	_hour(Clock.ticks_per_hour * 4.0)
	assert_eq(col.stores["sugar"], 14.0, "nurses don't feed larvae from the adults' next meal")
	col.stores["sugar"] = 40.0
	_hour(Clock.ticks_per_hour * 4.0)
	assert_lt(col.stores["sugar"], 40.0, "surplus food goes to the larvae")


func test_upkeep_starvation_count() -> void:
	_set_counts(8)
	col.stores = {"sugar": 6.0, "protein": 0.0, "seeds": 0.0, "fungus": 0.0, "water": 0.0, "leaf": 0.0, "poison": 0.0}
	# Need = 8 workers x 0.5 + queen 4 = 8; 2 short; 1.0 per ant -> 2 starve.
	assert_eq(col.on_day({"upkeep": 1.0}, 1.0), 2)
	assert_eq(col.stores["sugar"], 0.0)
	col.stores["sugar"] = 50.0
	assert_eq(col.on_day({"upkeep": 1.0}, 1.0), 0)
	assert_almost_eq(col.stores["sugar"], 42.0, 0.001)
