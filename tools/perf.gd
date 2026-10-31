extends SceneTree
## Perf probe: N ants split across nest and surface, measure the sim tick.
## godot --headless --path . -s tools/perf.gd -- [ants] [ticks]

func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var count := int(args[0]) if args.size() > 0 else 10000
	var ticks := int(args[1]) if args.size() > 1 else 200
	var game = root.get_node("Game")
	var clock = root.get_node("Clock")
	var w = load("res://sim/World.gd").new()
	w.setup("sandbox", {"seed": 7, "workers": 0, "soldiers": 0, "scouts": 0, "nurses": 0, "flags": {"rival": false, "house": false, "creatures": false, "weather": false}})
	game.world = w
	var g = w.nests[0]
	var col = w.colonies[0]
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for i in count:
		var where := args[2] if args.size() > 2 else "mix"
		if where == "nest" or (where == "mix" and i % 2 == 0):
			var c: int = g.open_list[rng.randi() % g.open_list.size()]
			w.ants.spawn(0, col.caste_index("worker"), g.center(c), 0, 0)
		else:
			var a: int = w.ants.spawn(0, col.caste_index("worker"), w.surface.entrance + Vector2(rng.randf_range(-3000, 3000), rng.randf_range(-3000, 3000)).clamp(Vector2(100, 1400), w.surface.size - Vector2(100, 100)), 1, 0)
			w.ants.job[a] = 4
			w.ants.state[a] = 1
	print("ants alive: ", w.ants.alive)
	var total := 0.0
	var ant_total := 0.0
	var worst := 0.0
	for t in ticks:
		var t0 := Time.get_ticks_usec()
		clock.advance()
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		total += ms
		worst = maxf(worst, ms)
	var t1 := Time.get_ticks_usec()
	for t in 20:
		w.ants.step(0.05)
	ant_total = (Time.get_ticks_usec() - t1) / 1000.0 / 20.0
	print("ants=%d  avg tick %.2f ms  worst %.2f ms  ant step alone %.2f ms" % [w.ants.alive, total / ticks, worst, ant_total])
	quit()
