extends GutTest
## Phase 7: winter, aphid ranching, satellite nests.

const H := preload("res://tests/helpers.gd")


func after_each() -> void:
	H.done()


func _winter(stores: Dictionary) -> World:
	var start := {"workers": 20, "season": "winter", "day": 1, "hour": 6, "stores": stores}
	var w := H.test_world(12, start, {"nest": true, "surface": true, "seasons": true})
	assert_eq(Clock.season(), "winter")
	assert_false(w.surface_open(), "winter closes the surface")
	var guard := 0
	while Clock.season() == "winter" and guard < 8 * Clock.hours_per_day:
		H.advance(Clock.ticks_per_hour)
		guard += 1
	assert_eq(Clock.season(), "spring", "made it to spring")
	return w


func test_winter_kills_an_unprepared_colony_but_not_a_stocked_one() -> void:
	var bare := _winter({"sugar": 0.0, "protein": 0.0, "seeds": 0.0, "fungus": 0.0})
	var bare_pop := bare.colonies[0].population()
	var bare_brood := bare.colonies[0].brood.size()
	H.done()
	var stocked := _winter({"sugar": 120.0, "protein": 30.0, "seeds": 20.0, "fungus": 0.0})
	var col := stocked.colonies[0]
	gut.p("spring: unprepared colony %d ants (%d brood); stocked colony %d ants, %.0f food left, deaths %s" % [bare_pop, bare_brood, col.population(), col.edible_total(), col.deaths])
	assert_eq(bare_pop, 0, "no stores: every worker starved")
	assert_eq(bare_brood, 0, "and no brood to rebuild from")
	assert_gte(col.population(), 18, "a stocked colony comes through winter")
	assert_true(col.queen_alive)


func _aphid_run(with_trait: bool, near_nest: bool) -> int:
	var w := H.test_world(13, {"workers": 20 if near_nest else 0}, {"nest": true, "surface": true})
	if with_trait:
		assert_true(w.colonies[0].unlock_trait("aphid_ranching", true))
	var p := w.surface.entrance + (Vector2(30, 0) if near_nest else Vector2(3000, 0))
	var id := w.creatures.spawn("aphid", p, World.SPACE_SURFACE)
	H.advance(90 * Clock.TICK_HZ)
	assert_true(w.creatures.exists(id), "nobody ate the aphid")
	var dew := 0
	for f in w.surface.foods.values():
		if f["kind"] == "honeydew":
			assert_eq(f["type"], "sugar")
			dew += 1
	var made := int(w.stats.get("honeydew", 0))
	assert_gte(made, dew, "honeydew drops are counted")
	H.done()
	return made


func test_aphid_ranching_makes_tended_aphids_produce_honeydew() -> void:
	var ranched := _aphid_run(true, true)
	var untrained := _aphid_run(false, true)
	var untended := _aphid_run(true, false)
	gut.p("honeydew in 90 s: ranching + tended %d, no trait %d, trait but untended %d" % [ranched, untrained, untended])
	assert_gte(ranched, 2, "tended aphids drip sugar with Aphid Ranching")
	assert_eq(untrained, 0, "no honeydew without the trait")
	assert_eq(untended, 0, "no honeydew when no ants tend them")


func test_satellite_nest_raises_its_own_brood_and_trades_with_the_main_nest() -> void:
	var w := H.test_world(14, {"workers": 30, "nurses": 4, "stores": {"sugar": 150.0, "protein": 100.0}}, {"nest": true, "surface": true, "satellites": true})
	w.colonies[0].charters = 1
	var ents := [w.nests[0].surface_pos]
	var site := Vector2.INF
	for k in 64:
		var p := w.surface.entrance + Vector2(1500.0 + 40.0 * (k % 8), 0).rotated(k * 0.7)
		if w.surface.valid_nest_site(p, ents):
			site = p
			break
	assert_ne(site, Vector2.INF, "found open soil for a daughter nest")
	assert_eq(w.found_satellite(site), "")
	assert_eq(w.colonies.size(), 2)
	var sat := w.colonies[1]
	assert_true(sat.is_satellite)
	assert_true(sat.queen_alive)
	assert_eq(w.colonies[0].charters, 0, "the charter was spent")
	var brood_peak := 0
	for h in 72:
		H.advance(Clock.ticks_per_hour)
		brood_peak = maxi(brood_peak, sat.brood.size())
		if sat.hatched > 0 and int(w.stats.get("trades", 0)) > 0:
			break
	gut.p("satellite: brood peak %d, hatched %d, population %d; trade deliveries %d" % [brood_peak, sat.hatched, sat.population(), int(w.stats.get("trades", 0))])
	assert_gt(brood_peak, 0, "the satellite queen lays")
	assert_gt(sat.hatched, 0, "satellite brood hatches into adults")
	assert_gt(int(w.stats.get("trades", 0)), 0, "workers carried food between the nests")
	assert_gt(sat.population(), 0, "the satellite has its own workers")
