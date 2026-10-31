extends GutTest
## Phase 3: zero-input foraging, player trails around obstacles, group hauling.

const H := preload("res://tests/helpers.gd")


func after_each() -> void:
	H.done()


func _harvest_total(col: Colony) -> float:
	var t := 0.0
	for k in col.harvested.keys():
		t += col.harvested[k]
	return t


func test_zero_input_colony_harvests_nearest_food_within_3_hours() -> void:
	for s in [1, 2, 3]:
		var w := H.test_world(s, {"workers": 20, "scouts": 3}, {"nest": true, "surface": true})
		var col := w.colonies[0]
		var nearest := []
		var foods: Array = w.surface.foods.values()
		foods.sort_custom(func(a, b): return a["pos"].distance_to(w.surface.entrance) < b["pos"].distance_to(w.surface.entrance))
		for f in foods.slice(0, 2):
			nearest.append([f["id"], f["amount"]])
		var first_out := -1
		var first_harvest := -1
		for t in H.hours(6):
			Clock.advance()
			if first_out < 0:
				for i in w.ants.n:
					if w.ants.is_alive(i) and w.ants.layer[i] == AntSim.LAYER_SURFACE:
						first_out = t
						break
			if first_harvest < 0 and _harvest_total(col) > 0.0:
				first_harvest = t
				break
		var taken := 0.0
		for e in nearest:
			taken += e[1] - (w.surface.foods[e[0]]["amount"] if w.surface.foods.has(e[0]) else 0.0)
		gut.p("seed %d: foragers out at tick %d, first harvest at tick %d (%.1f h after)" % [s, first_out, first_harvest, (first_harvest - first_out) / float(Clock.ticks_per_hour)])
		assert_between(first_out, 0, 200, "foragers leave the nest promptly")
		assert_between(first_harvest - first_out, 0, H.hours(3), "seed %d harvests within 3 in-game hours of going out" % s)
		assert_gt(taken, 0.0, "the food came from one of the two nearest sources")
		H.done()


## A small paved yard: nest at the bottom, a wall straight ahead, a chip just beyond it.
func _wall_yard() -> Dictionary:
	return {
		"id": "test_wall", "name": "Wall", "size_mm": [8000, 8000], "entrance": [4000, 6000], "rival_entrance": [7000, 7500],
		"house_gaps": [], "ground_noise": {"dirt": 0.99, "frequency": 0.0006},
		"ground_patches": [{"type": "paving", "rect": [2500, 4500, 3000, 2500]}],
		"objects": [{"type": "brick", "shape": "rect", "pos": [4000, 5800], "size": [500, 80], "block": true}],
		"flowers": [], "foods": [{"food": "dropped_chip", "pos": [4000, 5550]}],
	}


const DETOUR := [Vector2(4000, 6000), Vector2(4420, 6030), Vector2(4420, 5640), Vector2(4000, 5550)]


func _trail_run(paint: bool) -> Vector2i:
	var w := H.test_world(5, {"workers": 30}, {"nest": true, "surface": true}, {"yard": _wall_yard()})
	var food_id: int = w.surface.foods.keys()[0]
	var food_pos: Vector2 = w.surface.foods[food_id]["pos"]
	if paint:
		for k in DETOUR.size() - 1:
			var a: Vector2 = DETOUR[k]
			var b: Vector2 = DETOUR[k + 1]
			var steps := int(a.distance_to(b) / 40.0)
			for s in steps + 1:
				w.paint(World.SPACE_SURFACE, a.lerp(b, float(s) / steps), "trail")
	var detour := {}
	var reached := {}
	for t in 600:
		Clock.advance()
		for i in w.ants.n:
			if not w.ants.is_alive(i) or w.ants.layer[i] != AntSim.LAYER_SURFACE:
				continue
			var p: Vector2 = w.ants.pos[i]
			if p.x > 4300 and p.y > 5600 and p.y < 5950:
				detour[i] = true
			if p.distance_to(food_pos) < 60.0 or w.ants.carry[i] != AntSim.ITEM_NONE and w.ants.carry[i] != AntSim.ITEM_SPOIL:
				reached[i] = true
	return Vector2i(detour.size(), reached.size())


func test_painted_trail_reroutes_traffic_around_an_obstacle_within_30s() -> void:
	var control := _trail_run(false)
	H.done()
	var trail := _trail_run(true)
	gut.p("30 s after painting: ants on the detour %d (control %d), ants reaching the food %d (control %d)" % [trail.x, control.x, trail.y, control.y])
	assert_gte(trail.x, 2 * control.x + 5, "the painted detour carries traffic")
	assert_gt(trail.y, control.y, "more ants get round the wall to the food")
	assert_gte(trail.y, 3, "ants reach the food via the detour within 30 s")


func _haul_test(haulers: int) -> float:
	var w := H.test_world(6, {"workers": 0}, {"nest": true, "surface": true})
	w.script_spawn("dead_beetle", 1, "far")
	var fid := -1
	for f in w.surface.foods.values():
		if f.get("creature", "") == "dead_beetle":
			fid = f["id"]
	assert_gt(fid, 0, "dead beetle spawned")
	assert_eq(w.surface.foods[fid]["weight"], 8.0, "a dead beetle weighs as much as 8 workers can pull")
	var start: Vector2 = w.surface.foods[fid]["pos"]
	var worker := w.colonies[0].caste_index("worker")
	for k in haulers:
		var a := w.ants.spawn(0, worker, start + Vector2(14, 0).rotated(k * TAU / haulers), AntSim.LAYER_SURFACE, 0)
		w.ants.set_haul(a, fid)
	H.advance(200)
	var moved: float = w.surface.foods[fid]["pos"].distance_to(start) if w.surface.foods.has(fid) else INF
	var home := w.nests[0].surface_pos
	if w.surface.foods.has(fid):
		assert_lte(w.surface.foods[fid]["pos"].distance_to(home), start.distance_to(home) + 1.0, "never dragged away from home")
	return moved


func test_dead_beetle_needs_eight_ants_to_move() -> void:
	var with7 := _haul_test(7)
	H.done()
	var with8 := _haul_test(8)
	H.done()
	var with12 := _haul_test(12)
	gut.p("beetle moved: 7 ants %.1f mm, 8 ants %.1f mm, 12 ants %.1f mm in 10 s" % [with7, with8, with12])
	assert_almost_eq(with7, 0.0, 0.01, "7 workers can't budge it")
	assert_gt(with8, 50.0, "8 workers drag it home")
	assert_gt(with12, with8, "more haulers pull faster")
