extends GutTest
## Phase 0: the suite runs, data loads cleanly, the clock ticks the world.

const H := preload("res://tests/helpers.gd")


func after_each() -> void:
	H.done()


func test_data_tables_load_without_errors() -> void:
	assert_eq(Data.errors.size(), 0, "Data errors: %s" % [Data.errors])
	for t in ["castes", "chambers", "creatures", "difficulty", "foods", "house", "nest", "pheromones", "seasons", "soils", "traits", "builds"]:
		assert_false(Data.table(t).is_empty(), "table %s loaded" % t)
	for c in ["chapter_1", "chapter_2", "chapter_3", "chapter_4", "chapter_5", "yard_01"]:
		assert_true(Data.campaign.has(c), "campaign file %s loaded" % c)


func test_clock_advances_world_and_fires_hours() -> void:
	var w := H.test_world(1, {"workers": 2})
	var hours := [0]
	var cb := func(_h): hours[0] += 1
	Events.hour_passed.connect(cb)
	H.advance(Clock.ticks_per_hour * 2)
	Events.hour_passed.disconnect(cb)
	assert_eq(Clock.tick, Clock.ticks_per_hour * 2)
	assert_eq(w.ants.tick, Clock.ticks_per_hour * 2, "world stepped every tick")
	assert_eq(hours[0], 2, "two hour signals")
	assert_eq(Clock.hour_of_day(), 8, "started at 06:00")
