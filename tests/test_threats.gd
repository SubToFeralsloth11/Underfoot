extends GutTest
## Phase 6: grapple combat, rain vs trails, the rival colony.

const H := preload("res://tests/helpers.gd")


func after_each() -> void:
	H.done()


func _spider_fight(seed_value: int, caste: String) -> bool:
	var w := H.test_world(seed_value, {"workers": 0}, {"nest": true, "surface": true})
	var p := w.surface.entrance + Vector2(700, 0)
	var id := w.creatures.spawn("wolf_spider", p, World.SPACE_SURFACE)
	var col := w.colonies[0]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for k in 20:  # the swarm is on the spider (within grappling reach)
		w.ants.spawn(0, col.caste_index(caste), p + Vector2(rng.randf_range(2.0, 10.0), 0).rotated(rng.randf() * TAU), AntSim.LAYER_SURFACE, 0)
	H.advance(30 * Clock.TICK_HZ)
	var killed: bool = not w.creatures.exists(id) and int(col.kills.get("wolf_spider", 0)) == 1
	gut.p("%s seed %d: spider %s, %d of 20 ants left" % [caste, seed_value, "killed" if killed else "survived (hp %.0f)" % w.creatures.get_c(id).get("hp", 0.0), H.count_caste(w, 0, caste)])
	if killed:
		var loot := false
		for f in w.surface.foods.values():
			loot = loot or f.get("creature", "") == "wolf_spider"
		assert_true(loot, "a killed spider leaves a carcass to haul home")
	H.done()
	return killed


func test_twenty_soldiers_kill_a_wolf_spider_twenty_workers_mostly_dont() -> void:
	var soldier_wins := 0
	var worker_wins := 0
	for s in range(1, 7):
		if _spider_fight(s, "soldier"):
			soldier_wins += 1
		if _spider_fight(s, "worker"):
			worker_wins += 1
	assert_gte(soldier_wins, 5, "soldiers kill the spider (%d/6)" % soldier_wins)
	assert_lte(worker_wins, 1, "workers mostly don't (%d/6)" % worker_wins)


func _trail_cells(w: World) -> int:
	var ph := w.pher[World.SPACE_SURFACE]
	var e := w.surface.entrance
	var n := 0
	for y in range(int((e.y - 1000) * ph.inv_cell), int((e.y + 1000) * ph.inv_cell)):
		for x in range(int((e.x - 1000) * ph.inv_cell), int((e.x + 1000) * ph.inv_cell)):
			if ph.sample_cell(y * ph.w + x, PheromoneField.FOOD) > 5.0:
				n += 1
	return n


func test_rain_erases_trails_and_ants_reestablish_them() -> void:
	var w := H.test_world(1, {"workers": 20, "scouts": 3}, {"nest": true, "surface": true})
	H.advance(H.hours(5))
	var before := _trail_cells(w)
	w.weather.schedule("rain", Clock.tick, 1.0, 1.0)
	H.advance(H.hours(1) - 1)
	assert_gt(w.weather.rain, 0.9, "still raining")
	var during := _trail_cells(w)
	H.advance(H.hours(5))
	assert_eq(w.weather.rain, 0.0)
	var after := _trail_cells(w)
	gut.p("FOOD trail cells near the nest: before rain %d, end of rain %d, 5 h later %d" % [before, during, after])
	assert_gt(before, 20, "foraging laid food trails")
	assert_lt(during, before * 0.2, "an hour of heavy rain washed them out")
	assert_gt(after, before * 0.5, "ants re-established them")


func test_slow_rival_wins_if_ignored_for_three_weeks() -> void:
	var w := H.test_world(3, {"workers": 20, "soldiers": 2, "scouts": 2, "nurses": 3}, {"nest": true, "surface": true, "rival": true})
	assert_eq(w.difficulty, "normal")
	var result := []
	var cb := func(won: bool, reason: String): result.append([won, reason])
	Events.game_over.connect(cb)
	var raids := [0]
	var acb := func(kind: String, _t, _p, _s):
		if kind == "raid":
			raids[0] += 1
	Events.alert.connect(acb)
	var day := 0
	for d in 21:
		day = d + 1
		H.advance(H.hours(24))
		if w.over:
			break
	Events.game_over.disconnect(cb)
	Events.alert.disconnect(acb)
	gut.p("rival raids: %d, game over on day %d: %s; player pop %d, rival pop %d" % [raids[0], day, result, w.colonies[0].population(), w.colonies[1].population()])
	assert_gt(raids[0], 0, "the rival raided")
	assert_true(w.over, "the rival killed the queen within 3 in-game weeks")
	assert_eq(result.size(), 1)
	if result.size() == 1:
		assert_false(result[0][0], "it is a loss for the player")
	assert_false(w.colonies[0].queen_alive)
