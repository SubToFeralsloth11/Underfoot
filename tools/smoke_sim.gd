extends SceneTree
## Headless smoke: build a sandbox world and run N ticks, printing timings.
## godot --headless --path . -s tools/smoke_sim.gd -- [ticks] [mode]

func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var ticks := int(args[0]) if args.size() > 0 else 600
	var mode := args[1] if args.size() > 1 else "sandbox"
	var game = root.get_node("Game")
	var clock = root.get_node("Clock")
	var w = load("res://sim/World.gd").new()
	var t0 := Time.get_ticks_msec()
	w.setup(mode, {"seed": 42, "chapter": "chapter_2"})
	print("setup ms: ", Time.get_ticks_msec() - t0)
	game.world = w
	var worst := 0.0
	var total := 0.0
	for i in ticks:
		var a := Time.get_ticks_usec()
		clock.advance()
		var dtms := (Time.get_ticks_usec() - a) / 1000.0
		total += dtms
		worst = maxf(worst, dtms)
		if i % 200 == 0:
			var lay := [0, 0, 0]
			var jobs := {}
			var states := {}
			for k in w.ants.n:
				if w.ants.state[k] == 8 or w.ants.home[k] != 0:
					continue
				lay[w.ants.layer[k]] += 1
				var jn: String = w.ants.JOB_NAMES[w.ants.job[k]]
				jobs[jn] = jobs.get(jn, 0) + 1
				var sn: String = w.ants.STATE_NAMES[w.ants.state[k]]
				states[sn] = states.get(sn, 0) + 1
			print("  layers=", lay, " jobs=", jobs, " states=", states, " marks=", w.nests[0].marks, " open=", w.nests[0].open_list.size())
			var col = w.colonies[0]
			print("t=%d ants=%d pop=%d brood=%s stores=%s foods=%d creatures=%d avg=%.2fms" % [i, w.ants.alive, col.population(), col.brood_counts(), _short(col.stores), w.surface.foods.size(), w.creatures.list.size(), total / (i + 1)])
	print("avg tick ms: %.2f worst %.2f" % [total / ticks, worst])
	var col = w.colonies[0]
	print("harvested: ", col.harvested, " deaths: ", col.deaths, " hatched: ", col.hatched)
	quit()


func _short(d: Dictionary) -> String:
	var s := ""
	for k in d.keys():
		s += "%s:%d " % [k.substr(0, 3), int(d[k])]
	return s
