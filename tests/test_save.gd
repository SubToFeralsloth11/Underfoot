extends GutTest
## Phase 10: save/load round trips and v1 -> v2 migration.

const H := preload("res://tests/helpers.gd")


func after_each() -> void:
	H.done()


func _big_world() -> World:
	var w := H.make_world("sandbox", {"seed": 7, "workers": 0, "soldiers": 0, "scouts": 0, "nurses": 0, "flags": {"rival": false, "house": false, "creatures": false, "weather": false}})
	var g := w.nests[0]
	ColonyAI.plan_template(g, true)
	var worker := w.colonies[0].caste_index("worker")
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in 10000:
		w.ants.spawn(0, worker, g.center(g.open_list[rng.randi() % g.open_list.size()]), AntSim.LAYER_NEST, 0)
	return w


func test_save_at_10k_ants_and_load_back_identical() -> void:
	var w := _big_world()
	H.advance(200)
	gut.p("10k world after 200 ticks: %d alive, deaths %s" % [w.ants.alive, w.colonies[0].deaths])
	assert_gt(w.ants.alive, 9000)
	var before := w.state_hash()
	var snap := Save.snapshot()
	var w2 := Save.restore(snap)
	assert_not_null(w2)
	assert_eq(w2.state_hash(), before, "restored world hashes identically")
	assert_eq(w2.ants.alive, w.ants.alive)
	# Through the real file path too (gzip + store_var).
	assert_true(Save.save_game("gut_test"))
	var w3 := Save.restore(Save.read_slot("gut_test"))
	assert_eq(w3.state_hash(), before, "saved file loads back identically")
	DirAccess.remove_absolute(Save.slot_path("gut_test"))


func test_loaded_game_continues_exactly_like_the_original() -> void:
	var w := H.test_world(17, {"workers": 25, "soldiers": 3, "scouts": 3, "nurses": 3}, {"nest": true, "surface": true, "creatures": true, "weather": true, "rival": true})
	H.advance(3000)
	var snap := Save.snapshot()
	var t0 := Clock.tick
	var off := Clock.offset_ticks
	H.advance(2000)
	var original := w.state_hash()
	var w2 := Save.restore(snap)
	assert_eq(Clock.tick, t0, "clock restored")
	assert_eq(Clock.offset_ticks, off)
	Game.world = w2
	H.advance(2000)
	assert_eq(w2.state_hash(), original, "a loaded game plays out exactly as if never saved")


func test_v1_save_loads_after_migration() -> void:
	var w := H.test_world(18, {"workers": 25, "scouts": 3}, {"nest": true, "surface": true})
	H.advance(2500)
	for k in 12:
		w.paint(World.SPACE_SURFACE, w.surface.entrance + Vector2(-60.0 * k, 50.0 * k), "trail")
	H.advance(100)
	var snap := Save.snapshot()
	var v1 := Save.downgrade_to_v1(snap)
	assert_eq(v1["version"], 1)
	assert_false(v1.has("clock"), "v1 layout: flat tick/offset")
	assert_false(v1["world"]["pher"][0].has("stamp"), "v1 pheromones carry no decay stamps")
	var w2 := Save.restore(v1)
	assert_not_null(w2, "migrated v1 save loads")
	assert_eq(w2.ants.state_hash(), w.ants.state_hash(), "ants identical after migration")
	assert_eq(var_to_bytes(w2.ants.serialize()), var_to_bytes(w.ants.serialize()))
	var ph_a := w.pher[World.SPACE_SURFACE]
	var ph_b := w2.pher[World.SPACE_SURFACE]
	var compared := 0
	var worst := 0.0
	for ch in [PheromoneField.FOOD, PheromoneField.HOME, PheromoneField.PLAYER]:
		for c in ph_a.cells:
			var va := ph_a.sample_cell(c, ch)
			if va > 0.01:
				compared += 1
				worst = maxf(worst, absf(ph_b.sample_cell(c, ch) - va) / va)
	gut.p("compared %d scented cells, worst relative error %.6f" % [compared, worst])
	assert_gt(compared, 100, "there were trails to compare")
	assert_lt(worst, 0.001, "pheromone values survive the migration")
	# And the migrated world keeps decaying like the original.
	for k in 200:
		ph_a.advance(Clock.DT)
		ph_b.advance(Clock.DT)
	var p := w.surface.entrance + Vector2(-300, 250)
	assert_almost_eq(ph_b.sample(p.x, p.y, PheromoneField.PLAYER), ph_a.sample(p.x, p.y, PheromoneField.PLAYER), 0.01)
