extends GutTest
## Phase 4: caste targets steer the hatch mix; starvation kills oldest first.

const H := preload("res://tests/helpers.gd")


func after_each() -> void:
	H.done()


func _mix(w: World) -> Dictionary:
	var col := w.colonies[0]
	var larvae := {}
	var pupae := {}
	for b in col.brood:
		if b["stage"] == Colony.STAGE_LARVA:
			larvae[b["caste"]] = larvae.get(b["caste"], 0) + 1
		elif b["stage"] == Colony.STAGE_PUPA:
			pupae[b["caste"]] = pupae.get(b["caste"], 0) + 1
	return {"larvae": larvae, "pupae": pupae, "soldiers": H.count_caste(w, 0, "soldier"), "hatched": col.hatched}


func _caste_run(targets: Dictionary) -> Array:
	var w := H.test_world(8, {"workers": 20, "nurses": 4, "stores": {"sugar": 250.0, "protein": 250.0}}, {"nest": true})
	w.colonies[0].caste_targets = targets  # the caste panel writes this dictionary
	H.advance(H.hours(48))
	var day2 := _mix(w)
	H.advance(H.hours(24))
	var day3 := _mix(w)
	return [day2, day3]


func test_caste_targets_change_the_population_mix_within_two_days() -> void:
	var workers_only := _caste_run({"worker": 1.0, "soldier": 0.0, "scout": 0.0, "nurse": 0.0})
	H.done()
	var soldier_heavy := _caste_run({"worker": 0.3, "soldier": 0.7, "scout": 0.0, "nurse": 0.0})
	gut.p("workers-only day2 %s day3 %s" % workers_only)
	gut.p("soldier-heavy day2 %s day3 %s" % soldier_heavy)
	var d2: Dictionary = soldier_heavy[0]
	var in_progress := 0
	var soldiers_in_progress := 0
	for part in ["larvae", "pupae"]:
		for c in d2[part].keys():
			in_progress += int(d2[part][c])
			if c == "soldier":
				soldiers_in_progress += int(d2[part][c])
	# Within 2 days: the brood the caste panel shows is mostly soldiers and the first are pupating.
	assert_gt(float(soldiers_in_progress) / maxf(in_progress, 1), 0.5, "most larvae/pupae in progress are soldiers by day 2")
	assert_gt(int(d2["pupae"].get("soldier", 0)), 0, "soldier pupae by day 2")
	assert_eq(workers_only[0]["larvae"].get("soldier", 0) + workers_only[0]["pupae"].get("soldier", 0), 0, "no soldier brood with the slider at zero")
	# Adults follow as the spring-cool brood finishes (~2.5 days at 12-17 C).
	assert_gt(soldier_heavy[1]["soldiers"], 0, "soldiers walk the nest by day 3")
	assert_eq(workers_only[1]["soldiers"], 0)


func test_cutting_off_food_starves_oldest_ants_first() -> void:
	var w := H.test_world(9, {"workers": 0, "stores": {"sugar": 0.0, "protein": 0.0, "water": 0.0}}, {"nest": true})
	var col := w.colonies[0]
	var worker := col.caste_index("worker")
	var g := w.nests[0]
	var order := []  # oldest first
	for k in 8:
		order.append(w.ants.spawn(0, worker, g.center(g.chambers[0]["cells"][k]), AntSim.LAYER_NEST, 0))
		H.advance(30)
	# 8 workers + queen 4 = 12 food/day; 6 sugar -> 6 short at 1.5 per ant -> the 4 oldest starve.
	col.stores["sugar"] = 6.0
	var dead_order := []
	var cb := func(cause: String, _p, _s):
		if cause == "starvation":
			dead_order.append(cause)
	Events.ant_died.connect(cb)
	var day := Clock.hours_per_day * Clock.ticks_per_hour
	var to_midnight := day - (Clock.tick + Clock.offset_ticks) % day
	H.advance(to_midnight)
	Events.ant_died.disconnect(cb)
	assert_eq(Clock.hour_of_day(), 0, "reached midnight upkeep")
	assert_eq(dead_order.size(), 4, "four ants starved")
	for k in 8:
		if k < 4:
			assert_false(w.ants.is_alive(order[k]), "old ant %d starved" % k)
		else:
			assert_true(w.ants.is_alive(order[k]), "young ant %d survived" % k)
	assert_true(col.queen_alive, "the queen is fed last")
	assert_eq(int(col.deaths.get("starvation", 0)), 4)
