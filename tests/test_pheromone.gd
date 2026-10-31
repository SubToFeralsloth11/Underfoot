extends GutTest
## Unit tests: pheromone decay, rain acceleration, caps, diffusion, steering, persistence.

const H := preload("res://tests/helpers.gd")


func _field() -> PheromoneField:
	return PheromoneField.new(1000.0, 1000.0, 25.0, 2)


func _advance(f: PheromoneField, seconds: float) -> void:
	for i in int(seconds * Clock.TICK_HZ):
		f.advance(Clock.DT)


func test_decay_follows_per_channel_rates() -> void:
	var f := _field()
	var dec: Dictionary = Data.table("pheromones")["decay_per_second"]
	f.deposit(500, 500, PheromoneField.FOOD, 100.0)
	f.deposit(500, 500, PheromoneField.PLAYER, 100.0)
	f.deposit(500, 500, PheromoneField.ALARM, 100.0)
	_advance(f, 30.0)
	assert_almost_eq(f.sample(500, 500, PheromoneField.FOOD), 100.0 * exp(-float(dec["FOOD"]) * 30.0), 0.05)
	assert_almost_eq(f.sample(500, 500, PheromoneField.PLAYER), 100.0 * exp(-float(dec["PLAYER"]) * 30.0), 0.05)
	assert_almost_eq(f.sample(500, 500, PheromoneField.ALARM), 100.0 * exp(-float(dec["ALARM"]) * 30.0), 0.05)
	assert_gt(f.sample(500, 500, PheromoneField.PLAYER), f.sample(500, 500, PheromoneField.FOOD), "player trails outlast food trails")
	assert_gt(f.sample(500, 500, PheromoneField.FOOD), f.sample(500, 500, PheromoneField.ALARM), "alarm fades fastest")


func test_redeposit_adds_to_the_decayed_value_and_caps() -> void:
	var f := _field()
	f.deposit(100, 100, PheromoneField.HOME, 50.0)
	_advance(f, 10.0)
	var decayed := f.sample(100, 100, PheromoneField.HOME)
	f.deposit(100, 100, PheromoneField.HOME, 50.0)
	assert_almost_eq(f.sample(100, 100, PheromoneField.HOME), decayed + 50.0, 0.01)
	for i in 20:
		f.deposit(100, 100, PheromoneField.HOME, 50.0)
	assert_almost_eq(f.sample(100, 100, PheromoneField.HOME), f.max_value, 0.01, "values cap at max_value")


func test_rain_rate_mult_erases_trails_without_touching_cells() -> void:
	var dry := _field()
	var wet := _field()
	for f in [dry, wet]:
		f.deposit(300, 300, PheromoneField.FOOD, 200.0)
	wet.rate_mult = float(Data.table("pheromones")["rain_decay_mult"])
	_advance(dry, 10.0)
	_advance(wet, 10.0)
	assert_gt(dry.sample(300, 300, PheromoneField.FOOD), 150.0, "ten dry seconds barely fade a trail")
	assert_lt(wet.sample(300, 300, PheromoneField.FOOD), 1.0, "ten seconds of heavy rain wipe it")


func test_factions_have_separate_channels() -> void:
	var f := _field()
	f.deposit(200, 200, PheromoneField.ch(1, PheromoneField.FOOD), 80.0)
	assert_eq(f.sample(200, 200, PheromoneField.FOOD), 0.0, "rival food scent is invisible to faction 0")
	assert_almost_eq(f.sample(200, 200, PheromoneField.ch(1, PheromoneField.FOOD)), 80.0, 0.001)


func test_spread_deposit_conserves_amount_and_reaches_neighbours() -> void:
	var f := _field()
	f.deposit_spread(512, 512, PheromoneField.FOOD, 100.0)
	var total := 0.0
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			total += f.sample(512 + dx * 25, 512 + dy * 25, PheromoneField.FOOD)
	assert_almost_eq(total, 100.0, 0.01)
	assert_gt(f.sample(537, 512, PheromoneField.FOOD), 0.0)
	assert_eq(f.sample(537, 537, PheromoneField.FOOD), 0.0, "no diagonal spread")


func test_erase_brush_and_out_of_bounds() -> void:
	var f := _field()
	f.brush(Vector2(500, 500), 100.0, PheromoneField.PLAYER, 50.0)
	assert_gt(f.sample(500, 500, PheromoneField.PLAYER), f.sample(580, 500, PheromoneField.PLAYER), "brush falls off toward the edge")
	assert_eq(f.sample(700, 500, PheromoneField.PLAYER), 0.0)
	f.erase(Vector2(500, 500), 120.0, [PheromoneField.PLAYER])
	assert_eq(f.sample(500, 500, PheromoneField.PLAYER), 0.0)
	f.deposit(-60, 20, PheromoneField.FOOD, 10.0)
	assert_eq(f.sample(-60, 20, PheromoneField.FOOD), 0.0)


func test_steer_turns_toward_the_stronger_side_and_avoids_alarm() -> void:
	var f := _field()
	var p := Vector2(500, 500)
	# Heading east (0 rad); antennae 60 mm out so left/forward/right land in different cells.
	var left := p + Vector2(cos(-0.6), sin(-0.6)) * 60.0
	f.deposit(left.x, left.y, PheromoneField.FOOD, 50.0)
	assert_eq(f.steer(p, 0.0, 60.0, 0.6, PheromoneField.FOOD, -1, 0.0, 0.0), -1.0)
	var right := p + Vector2(cos(0.6), sin(0.6)) * 60.0
	f.deposit(right.x, right.y, PheromoneField.FOOD, 80.0)
	assert_eq(f.steer(p, 0.0, 60.0, 0.6, PheromoneField.FOOD, -1, 0.0, 0.0), 1.0)
	f.deposit(right.x, right.y, PheromoneField.ALARM, 60.0)
	assert_eq(f.steer(p, 0.0, 60.0, 0.6, PheromoneField.FOOD, -1, 0.0, 4.0), -1.0, "alarm on the right pushes it left")
	var empty := _field()
	assert_eq(empty.steer(p, 0.0, 60.0, 0.6, PheromoneField.FOOD, -1, 0.0, 0.0), 0.0, "no scent: keep going")


func test_serialize_round_trip_keeps_decay_clock() -> void:
	var f := _field()
	f.deposit(250, 250, PheromoneField.FOOD, 120.0)
	_advance(f, 5.0)
	var g := PheromoneField.new()
	g.deserialize(f.serialize())
	_advance(f, 20.0)
	_advance(g, 20.0)
	assert_almost_eq(g.sample(250, 250, PheromoneField.FOOD), f.sample(250, 250, PheromoneField.FOOD), 0.0001)
