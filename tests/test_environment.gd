extends GutTest
## Phase 5: air (vents) and water (sumps) in the nest cellular automaton.

const H := preload("res://tests/helpers.gd")
const CH_W := 10
const CH_H := 5


## A nest with the starter shaft + cavity, a 1-wide shaft down to `depth` and a
## 10x5 chamber there (clay all around). Returns [grid, chamber index].
func _nest(depth: int, rows: int = 128) -> Array:
	var g := NestGrid.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 2
	g.generate_nest(rng, Vector2i(64, rows))
	var ex := g.entrance_x
	for y in range(15, mini(depth + CH_H + 6, rows)):
		for x in range(ex - 6, ex + CH_W + 8):
			g.set_soil(y * g.w + x, "clay")
	H.excavate_rect(g, Vector2i(ex, 15), Vector2i(ex, depth - 1))
	H.excavate_rect(g, Vector2i(ex, depth), Vector2i(ex + CH_W - 1, depth + CH_H - 1))
	var ch := g.assign_chamber(H.rect_cells(g, Vector2i(ex, depth), Vector2i(ex + CH_W - 1, depth + CH_H - 1)), "nursery")
	return [g, ch]


func _settle_air(g: NestGrid, ch: int, ants: int, updates: int) -> float:
	var cells: PackedInt32Array = g.chambers[ch]["cells"]
	for k in ants:
		g.occupy(cells[k])  # resting ants breathe here every update
	var env := NestEnvironment.new()
	for k in updates * env.divisor:
		env.step(g, 0, 15.0, 0.0, null)
	return g.chamber_avg(ch, "air")


func _open_vent(g: NestGrid, depth: int) -> void:
	var vc := (depth) * g.w + g.entrance_x + 7  # top row of the chamber, away from the entrance shaft
	for y in range(1, depth):
		g.set_soil(y * g.w + g.entrance_x + 7, "loam")  # no surprise boulder in the shaft
	g.mark_vent(vc)
	var opened := 0
	for y in range(depth - 1, -1, -1):
		var c := y * g.w + g.entrance_x + 7
		if g.dig_mark[c] == 1:
			assert_true(g.dig(c, 999.0))
			opened += 1
	assert_gt(opened, depth - 5, "vent shaft dug to the surface")


func test_deep_nest_without_vent_suffocates_and_one_vent_fixes_it() -> void:
	var lethal := float(Data.table("nest")["env"]["air_lethal"])
	var shallow: Array = _nest(25)
	var air_shallow := _settle_air(shallow[0], shallow[1], 30, 25000)
	var deep: Array = _nest(50)
	var air_deep := _settle_air(deep[0], deep[1], 30, 25000)
	var vented: Array = _nest(50)
	_open_vent(vented[0], 50)
	var air_vented := _settle_air(vented[0], vented[1], 30, 25000)
	gut.p("chamber air with 30 ants: depth 25 cells %.1f, depth 50 cells %.1f, depth 50 + vent %.1f (lethal < %.0f)" % [air_shallow, air_deep, air_vented, lethal])
	assert_gt(air_shallow, 70.0, "a shallow chamber breathes through the entrance")
	assert_lt(air_deep, lethal, "below ~50 cells (200 mm) the colony suffocates without a vent")
	assert_gt(air_vented, 70.0, "one vent shaft brings the deep chamber back to healthy air")


func _rain(g: NestGrid, hours: float, rain: float) -> void:
	var env := NestEnvironment.new()
	for k in int(hours * Clock.ticks_per_hour):
		env.step(g, 0, 15.0, rain, null)


func test_heavy_rain_floods_a_chamber_unless_it_has_a_sump() -> void:
	var dry_env := NestEnvironment.new()
	var plain: Array = _nest(40, 64)
	var sumped: Array = _nest(40, 64)
	var sg: NestGrid = sumped[0]
	var ex := sg.entrance_x
	var sump_rect := [Vector2i(ex - 1, 45), Vector2i(ex + 2, 46)]  # right under where the shaft drips in
	H.excavate_rect(sg, sump_rect[0], sump_rect[1])
	sg.assign_chamber(H.rect_cells(sg, sump_rect[0], sump_rect[1]), "sump")
	_rain(plain[0], 4.0, 1.0)
	_rain(sumped[0], 4.0, 1.0)
	var f_plain := dry_env.flooded_fraction(plain[0], plain[1])
	var f_sump := dry_env.flooded_fraction(sg, sumped[1])
	gut.p("after 4 h of heavy rain: flooded fraction without sump %.2f, with sump %.2f" % [f_plain, f_sump])
	assert_gt(f_plain, 0.2, "heavy rain floods the chamber")
	var floor_wet := 0
	for x in range(ex, ex + CH_W):
		if plain[0].moisture[44 * plain[0].w + x] > float(Data.table("nest")["env"]["flood_level"]):
			floor_wet += 1
	assert_eq(floor_wet, CH_W, "the whole chamber floor is under water")
	var flood_level := float(Data.table("nest")["env"]["flood_level"])
	for x in range(ex + 1, ex + CH_W):
		assert_lt(sg.moisture[44 * sg.w + x], flood_level, "with a sump the floor at x+%d is dry" % (x - ex))
	# Only the drip line under the entrance shaft (1 of 10 columns) stays wet.
	assert_lte(f_sump, 1.0 / CH_W + 0.001, "the sump drains the chamber")
	_rain(plain[0], 6.0, 0.0)
	assert_gt(dry_env.flooded_fraction(plain[0], plain[1]), 0.1, "clay holds the flood long after the rain stops")
