extends GutTest
## Phase 1: digging, chambers, brood, collapse, nest-scale performance.

const H := preload("res://tests/helpers.gd")


func after_each() -> void:
	H.done()


func test_founding_colony_digs_three_chambers_and_hatches_workers() -> void:
	var w := H.test_world(11, {"workers": 5})
	var g := w.nests[0]
	var col := w.colonies[0]
	var ex := g.entrance_x
	var workers_before := H.count_caste(w, 0, "worker")
	assert_eq(workers_before, 5)
	assert_true(col.queen_alive)
	# Starter cavity (rows 10-14) is the queen chamber; dig a nursery to the right and a store to the left.
	assert_gt(w.dig_rect(0, Vector2i(ex + 5, 12), Vector2i(ex + 12, 13), true), 0, "corridor marked")
	assert_eq(w.chamber_rect(0, Vector2i(ex + 13, 10), Vector2i(ex + 20, 14), "nursery"), "")
	assert_gt(w.dig_rect(0, Vector2i(ex - 12, 12), Vector2i(ex - 6, 13), true), 0, "corridor marked")
	assert_eq(w.chamber_rect(0, Vector2i(ex - 21, 10), Vector2i(ex - 13, 14), "food_store"), "")
	var seen := Vector3i.ZERO
	var dug_hour := -1
	var hatch_hour := -1
	for hour in 96:
		H.advance(Clock.ticks_per_hour)
		var bc := col.brood_counts()
		seen = Vector3i(maxi(seen.x, bc.x), maxi(seen.y, bc.y), maxi(seen.z, bc.z))
		if dug_hour < 0 and g.count_ok_chambers("queen") == 1 and g.count_ok_chambers("nursery") == 1 and g.count_ok_chambers("food_store") == 1:
			dug_hour = hour
		if hatch_hour < 0 and col.hatched > 0:
			hatch_hour = hour
		if dug_hour >= 0 and hatch_hour >= 0:
			break
	gut.p("chambers dug by hour %d, first hatch at hour %d, brood peak %s" % [dug_hour, hatch_hour, seen])
	assert_between(dug_hour, 0, 24, "workers dig all three chambers within a day")
	assert_eq(g.marks, 0, "every marked cell was dug")
	assert_gt(seen.x, 0, "queen laid eggs")
	assert_gt(seen.y, 0, "eggs became larvae")
	assert_gt(seen.z, 0, "larvae pupated")
	assert_between(hatch_hour, 0, 95, "first adult hatched within 4 days")
	assert_gt(H.count_caste(w, 0, "worker") + H.count_caste(w, 0, "soldier") + H.count_caste(w, 0, "scout") + H.count_caste(w, 0, "nurse"), workers_before, "new ants joined the colony")
	assert_gt(g.mound, 0.0, "spoil was carried to the surface mound")


## A sealed test pocket: `soil` everywhere around a 12-wide, 4-tall chamber at rows 30-33.
func _span_grid(soil: String) -> NestGrid:
	var g := NestGrid.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	g.generate_nest(rng, Vector2i(64, 64))
	for y in range(26, 41):
		for x in range(4, 31):
			g.set_soil(y * g.w + x, soil)
	H.excavate_rect(g, Vector2i(10, 30), Vector2i(21, 33))
	return g


func _collapses(g: NestGrid, checks: int) -> PackedInt32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for k in checks:
		var filled := g.collapse_check(rng, 1.0, 1.0)
		if filled.size() > 0:
			return filled
	return PackedInt32Array()


func test_twelve_wide_sand_chamber_collapses() -> void:
	var g := _span_grid("sand")
	var filled := _collapses(g, 20)
	assert_gte(filled.size(), 12, "a cave-in happened")
	for x in range(10, 22):
		var c := 30 * g.w + x
		assert_true(c in filled, "top-row cell %d caved in" % x)
		assert_false(g.is_open(c))
		assert_eq(g.soil(c)["id"], "rubble")
	for c in filled:
		assert_between(c / g.w, 30, 33, "only the chamber's own cells fill")


func test_same_span_in_clay_holds() -> void:
	var g := _span_grid("clay")
	assert_eq(_collapses(g, 500).size(), 0, "clay spans 20 cells")
	for c in H.rect_cells(g, Vector2i(10, 30), Vector2i(21, 33)):
		assert_true(g.is_open(c))


func test_pillar_or_root_ceiling_saves_a_sand_span() -> void:
	var g := _span_grid("sand")
	assert_true(g.fill(30 * g.w + 15, "pillar"), "pillar placed in the top row")
	assert_eq(_collapses(g, 500).size(), 0, "a pillar splits the span into 5 + 6")
	var g2 := _span_grid("sand")
	for x in range(10, 22):
		g2.set_soil(29 * g2.w + x, "root")
	assert_eq(_collapses(g2, 500).size(), 0, "roots in the ceiling support it")


func test_wider_clay_span_eventually_collapses() -> void:
	var g := _span_grid("clay")
	H.excavate_rect(g, Vector2i(22, 30), Vector2i(29, 33))  # 20 -> 20 wide: still holds
	assert_eq(_collapses(g, 200).size(), 0)
	for y in range(26, 41):
		for x in range(31, 40):
			g.set_soil(y * g.w + x, "clay")
	H.excavate_rect(g, Vector2i(30, 30), Vector2i(33, 33))  # 24 wide > clay's 20
	var filled := _collapses(g, 200)
	assert_gte(filled.size(), 24)
	for x in range(10, 34):
		assert_true(30 * g.w + x in filled, "the whole 24-wide ceiling row fell")


func test_500_ants_in_nest_tick_within_budget() -> void:
	var w := H.test_world(3, {"workers": 500})
	assert_eq(w.ants.alive, 501)
	H.advance(100)
	var t0 := Time.get_ticks_usec()
	var ticks := 300
	H.advance(ticks)
	var avg := (Time.get_ticks_usec() - t0) / 1000.0 / ticks
	gut.p("500 nest ants: avg tick %.2f ms" % avg)
	assert_lt(avg, 8.0, "500 nest ants fit well inside a 60 fps frame")
	assert_gt(w.ants.alive, 495, "nobody died of the test setup")
