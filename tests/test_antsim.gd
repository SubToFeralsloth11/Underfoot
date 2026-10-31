extends GutTest
## Phase 2: ant simulation at scale, collision with soil, determinism.

const H := preload("res://tests/helpers.gd")


func after_each() -> void:
	H.done()


func test_10k_ants_across_nest_and_surface_tick_within_25ms() -> void:
	var w := H.make_world("sandbox", {"seed": 7, "workers": 0, "soldiers": 0, "scouts": 0, "nurses": 0, "flags": {"rival": false, "house": false, "creatures": false, "weather": false}})
	var g := w.nests[0]
	ColonyAI.plan_template(g, true)
	var worker := w.colonies[0].caste_index("worker")
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	# A 10k colony born underground; the job quotas then send ~3/4 out to forage.
	for i in 10000:
		var c: int = g.open_list[rng.randi() % g.open_list.size()]
		w.ants.spawn(0, worker, g.center(c), AntSim.LAYER_NEST, 0)
	assert_eq(w.ants.alive, 10001)
	H.advance(400)
	var ticks := 100
	var t0 := Time.get_ticks_usec()
	H.advance(ticks)
	var avg := (Time.get_ticks_usec() - t0) / 1000.0 / ticks
	var nest_n := 0
	var surf_n := 0
	for i in w.ants.n:
		if w.ants.is_alive(i):
			if w.ants.layer[i] == AntSim.LAYER_NEST:
				nest_n += 1
			else:
				surf_n += 1
	gut.p("10k ants: avg sim tick %.2f ms (nest %d, surface %d)" % [avg, nest_n, surf_n])
	assert_gt(nest_n, 1500, "thousands still underground")
	assert_gt(surf_n, 5000, "thousands out on the surface")
	assert_lte(avg, 25.0, "sim tick budget at 10k ants")


func test_ants_never_stand_inside_solid_soil() -> void:
	var w := H.test_world(4, {"workers": 50, "nurses": 4}, {"nest": true, "surface": true})
	var g := w.nests[0]
	var ex := g.entrance_x
	# Keep the grid changing: dig orders, plus a worm that collapses tunnels behind it.
	w.dig_rect(0, Vector2i(ex - 20, 44), Vector2i(ex + 20, 47), true)
	w.dig_rect(0, Vector2i(ex, 37), Vector2i(ex, 44), true)
	w.creatures.spawn("earthworm", g.center(g.chambers[g.chamber_of_type("nursery")]["cells"][0]), AntSim.SPACE_NEST0)
	var violations := 0
	var checked := 0
	var filled_seen := 0
	var opened := g.open_list.size()
	for t in 3000:
		var before := g.solidity.duplicate()
		Clock.advance()
		var sol := g.solidity
		for i in w.ants.n:
			if not w.ants.is_alive(i) or w.ants.layer[i] != AntSim.LAYER_NEST:
				continue
			var c := g.cell_at(w.ants.pos[i])
			checked += 1
			if c < 0:
				violations += 1
			elif sol[c] != 0:
				if before[c] == 0:
					filled_seen += 1  # filled under the ant this very tick: it is moved out next tick
				else:
					violations += 1
					if violations < 5:
						gut.p("ant %d in solid cell %d (job %s) at tick %d" % [i, c, AntSim.JOB_NAMES[w.ants.job[i]], t])
	gut.p("checked %d ant-ticks, %d inside freshly filled cells, open cells %d -> %d" % [checked, filled_seen, opened, g.open_list.size()])
	assert_gt(checked, 50000, "plenty of underground movement checked")
	assert_gt(g.open_list.size(), opened + 50, "the grid changed while ants moved")
	assert_eq(violations, 0, "no ant ever stood inside solid soil")


func _determinism_run(seed_value: int) -> Array:
	var w := H.test_world(seed_value, {"workers": 12, "soldiers": 2, "scouts": 2, "nurses": 2}, {"nest": true, "surface": true, "creatures": true, "weather": true})
	var ex := w.nests[0].entrance_x
	for t in 12000:
		if t == 200:
			for k in 10:
				w.paint(World.SPACE_SURFACE, w.surface.entrance + Vector2(40.0 * k, -30.0 * k), "trail")
		if t == 400:
			w.dig_rect(0, Vector2i(ex - 10, 40), Vector2i(ex + 10, 41), true)
		Clock.advance()
	return [w.ants.state_hash(), w.state_hash(), w.ants.alive, w.colonies[0].deaths, w.colonies[0].hatched]


func test_same_seed_and_inputs_give_identical_state_after_10_minutes() -> void:
	var a := _determinism_run(21)
	H.done()
	var b := _determinism_run(21)
	H.done()
	var c := _determinism_run(22)
	gut.p("hashes: %s / %s / other seed %s" % [a, b, c])
	assert_eq(a[0], b[0], "identical ant positions/states")
	assert_eq(a[1], b[1], "identical full world state")
	assert_ne(a[1], c[1], "a different seed gives a different world (the hash is meaningful)")
