extends GutTest
## Unit tests: trait costs/prerequisites, multipliers, unlocks reaching the sim.

const H := preload("res://tests/helpers.gd")


func after_each() -> void:
	H.done()


func test_cost_and_prerequisites() -> void:
	var col := Colony.new()
	col.trait_points = 1
	assert_false(col.can_unlock("serrated_mandibles"), "needs Trap-jaw first")
	assert_false(col.can_unlock("majors"), "costs 2")
	assert_true(col.unlock_trait("trap_jaw"))
	assert_eq(col.trait_points, 0)
	assert_false(col.unlock_trait("thick_cuticle"), "no points left")
	assert_false(col.unlock_trait("trap_jaw", true), "can't take a trait twice")


func test_multipliers_stack_on_caste_stats() -> void:
	var col := Colony.new()
	var s := col.caste_index("soldier")
	var wk := col.caste_index("worker")
	var base_attack := col.c_attack[s]
	var base_hp := col.c_hp[wk]
	col.unlock_trait("trap_jaw", true)
	assert_almost_eq(col.c_attack[s], base_attack * 1.3, 0.001)
	assert_almost_eq(col.c_attack[wk], 1.0, 0.001, "worker attack untouched by a soldier trait")
	col.unlock_trait("iron_grip", true)
	col.unlock_trait("decapitate", true)
	assert_almost_eq(col.c_attack[s], base_attack * 1.3 * 1.2, 0.001, "multipliers multiply")
	col.unlock_trait("thick_cuticle", true)
	assert_almost_eq(col.c_hp[wk], base_hp * 1.2, 0.001)
	assert_almost_eq(col.mult("combat.damage_taken"), 0.9, 0.001)
	assert_true(col.has_unlock("behaviour:decapitate"))


func test_caste_unlock_makes_majors_producible() -> void:
	var col := Colony.new()
	assert_false(col.producible_castes().has("major"))
	col.unlock_trait("thick_cuticle", true)
	col.unlock_trait("majors", true)
	assert_true(col.producible_castes().has("major"))


func test_chamber_unlock_gates_fungus_garden() -> void:
	var w := H.test_world(1, {"workers": 2})
	var ex := w.nests[0].entrance_x
	assert_ne(w.chamber_rect(0, Vector2i(ex + 20, 20), Vector2i(ex + 29, 23), "fungus"), "", "locked without Leafcutter")
	w.colonies[0].unlock_trait("leafcutter", true)
	assert_eq(w.chamber_rect(0, Vector2i(ex + 20, 20), Vector2i(ex + 29, 23), "fungus"), "")


func test_long_scent_makes_trails_last_twice_as_long() -> void:
	var samples := []
	for with_trait in [false, true]:
		var w := H.test_world(1, {"workers": 0}, {"nest": true, "surface": true})
		if with_trait:
			w.colonies[0].unlock_trait("long_scent", true)
		var p := w.surface.entrance + Vector2(1500, 0)
		H.advance(20)
		w.pher[World.SPACE_SURFACE].deposit(p.x, p.y, PheromoneField.FOOD, 200.0)
		H.advance(45 * Clock.TICK_HZ)
		samples.append(w.pher[World.SPACE_SURFACE].sample(p.x, p.y, PheromoneField.FOOD))
		H.done()
	var k: float = Data.table("pheromones")["decay_per_second"]["FOOD"]
	assert_almost_eq(samples[0], 200.0 * exp(-k * 45.0), 0.5)
	assert_almost_eq(samples[1], 200.0 * exp(-k * 0.5 * 45.0), 0.5, "Long Scent halves trail decay")


func test_leaves_are_only_harvested_by_leafcutters() -> void:
	var carried := []
	for with_trait in [false, true]:
		var w := H.test_world(2, {"workers": 0}, {"nest": true, "surface": true})
		if with_trait:
			w.colonies[0].unlock_trait("leafcutter", true)
		var p := w.surface.entrance + Vector2(800, 0)
		w.surface.add_food("leaf_litter", p, World.SPACE_SURFACE)
		var a := w.ants.spawn(0, w.colonies[0].caste_index("worker"), p, AntSim.LAYER_SURFACE, 0)
		H.advance(4)
		carried.append(AntSim.ITEM_NAMES[w.ants.carry[a]])
		H.done()
	assert_eq(carried[0], "", "without Leafcutter a forager walks past leaf litter")
	assert_eq(carried[1], "leaf", "leafcutters pick it up")
