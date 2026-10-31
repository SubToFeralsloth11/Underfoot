extends GutTest
## Phase 8: house escalation and the Exterminator boss.

const H := preload("res://tests/helpers.gd")


func after_each() -> void:
	H.done()


func _house_world(hour: int, workers: int = 10) -> World:
	return H.test_world(31, {"workers": workers, "hour": hour}, {"nest": true, "surface": true, "house": true})


## Put `n` ants on the kitchen floor (as if they came in through the wall gap).
func _ants_in_kitchen(w: World, n: int) -> void:
	var hg := w.house
	var cells := []
	for c in hg.open_list:
		if hg.room_at(c) == "kitchen":
			cells.append(c)
	var worker := w.colonies[0].caste_index("worker")
	for k in n:
		w.ants.spawn(0, worker, hg.center(cells[(k * 7919) % cells.size()]), AntSim.LAYER_HOUSE, 0)


func _baits(w: World) -> int:
	var n := 0
	for f in w.surface.foods_in_space(World.SPACE_HOUSE):
		if f["kind"] == "bait":
			n += 1
	return n


func test_careful_foraging_keeps_escalation_low_greedy_triggers_traps() -> void:
	# Greedy: a crowd raids the kitchen while the homeowner is cooking (07:00-09:00).
	var greedy := _house_world(7)
	_ants_in_kitchen(greedy, 100)
	H.advance(H.hours(3))
	var g_level := greedy.house_ai.max_level
	var g_baits := _baits(greedy)
	H.done()
	# Careful: the same crowd, but while the house is empty (09:00-12:00).
	var away := _house_world(9)
	_ants_in_kitchen(away, 100)
	H.advance(H.hours(3))
	var a_level := away.house_ai.max_level
	H.done()
	# Careful: a few scouts while the homeowner is in the kitchen.
	var few := _house_world(7)
	_ants_in_kitchen(few, 4)
	H.advance(H.hours(3))
	var f_level := few.house_ai.max_level
	var f_baits := _baits(few)
	gut.p("max escalation: greedy %d (%d baits), crowd while away %d, few scouts %d" % [g_level, g_baits, a_level, f_level])
	assert_gte(g_level, 3, "a crowd in plain sight escalates to traps")
	assert_gt(g_baits, 0, "bait traps placed in the house")
	assert_lte(a_level, 1, "foraging while nobody is home stays quiet")
	assert_lte(f_level, 1, "a handful of ants barely registers")
	assert_eq(f_baits, 0)


func _run_exterminator(w: World, max_seconds: float, on_tick: Callable = Callable()) -> Dictionary:
	var result := {}
	var cb := func(won: bool, reason: String):
		result["won"] = won
		result["reason"] = reason
	Events.game_over.connect(cb)
	w.house_ai.add_escalation(200.0)
	assert_true(w.house_ai.ext_started, "level 5 summons the exterminator")
	var start := Clock.tick
	var phases := {}
	while Clock.tick - start < int(max_seconds * Clock.TICK_HZ):
		Clock.advance()
		phases[w.house_ai.ext_phase] = true
		if on_tick.is_valid():
			on_tick.call()
		if w.over or w.house_ai.ext_phase == "done":
			break
	Events.game_over.disconnect(cb)
	result["seconds"] = (Clock.tick - start) * Clock.DT
	result["phases"] = phases.keys()
	return result


func test_exterminator_phase_durations_total_10_to_20_minutes() -> void:
	var ec: Dictionary = Data.table("house")["exterminator"]
	var total := 30.0 + float(ec["fog_seconds"]) + float(ec["trace_seconds"]) + float(ec["dig_seconds"])
	assert_between(total, 600.0, 1200.0, "warning + fog + trace + dig budget")


func test_exterminator_lost_when_he_digs_out_the_queen() -> void:
	var w := _house_world(10)
	var r := _run_exterminator(w, 1500.0)
	gut.p("loss run: %s" % r)
	assert_true(w.over, "game over")
	assert_eq(r.get("won", true), false, "Events.game_over(false)")
	assert_string_contains(String(r.get("reason", "")), "exterminator")
	assert_true("dig" in r["phases"], "he dug for her")
	assert_false(w.colonies[0].queen_alive)


func test_exterminator_won_by_keeping_the_queen_out_of_his_dig() -> void:
	var w := _house_world(10)
	var g := w.nests[0]
	var ex := g.entrance_x
	# A back tunnel to a far queen chamber at the edge of the nest.
	H.excavate_rect(g, Vector2i(ex + 5, 13), Vector2i(ex + 112, 13))
	H.excavate_rect(g, Vector2i(ex + 113, 11), Vector2i(ex + 120, 15))
	assert_eq(w.chamber_rect(0, Vector2i(ex + 113, 11), Vector2i(ex + 120, 15), "queen"), "")
	H.advance(120 * Clock.TICK_HZ)
	var qa := w.colonies[0].queen_ant
	assert_gt(w.ants.pos[qa].x / g.cell, float(ex + 100), "the queen walked to her new chamber")
	var r := _run_exterminator(w, 1500.0)
	gut.p("survival run: %s" % r)
	assert_false(w.over, "the colony survives")
	assert_true(w.colonies[0].queen_alive)
	assert_true(w.stats.get("exterminator_defeated", false), "he gives up")
	assert_true("fog" in r["phases"] and "trace" in r["phases"] and "dig" in r["phases"], "all three phases happened")
	assert_between(r["seconds"], 600.0, 1200.0, "the fight lasts 10-20 minutes")


func test_exterminator_won_by_relocating_the_queen_to_a_hidden_satellite() -> void:
	var w := _house_world(10, 20)
	w.colonies[0].charters = 1
	var site := H.find_nest_site(w, 2500.0)
	assert_ne(site, Vector2.INF, "found a hidden site")
	assert_eq(w.found_satellite(site), "")
	var moved := [false]
	var relocate := func():
		if not moved[0] and w.house_ai.ext_phase == "fog":
			moved[0] = true
			assert_eq(w.start_queen_relocation(1), "")
	var r := _run_exterminator(w, 1500.0, relocate)
	gut.p("relocation run: %s" % r)
	assert_true(moved[0])
	assert_false(w.over, "losing the main nest's queen slot is not a game over")
	assert_true(w.stats.get("exterminator_defeated", false))
	assert_true(w.colonies[1].queen_alive, "the queen lives on in the satellite")
	assert_false(w.queen_relocating, "relocation finished")
