extends SceneTree
## Windowed visual smoke test: start a game, fast-forward, capture each view.
## godot --path . -s tools/capture.gd -- <out_dir> [mode] [ticks] [chapter]

var out := "/tmp/uf_shots"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else out
	var mode := args[1] if args.size() > 1 else "sandbox"
	var ticks := int(args[2]) if args.size() > 2 else 1200
	var chapter := args[3] if args.size() > 3 else "chapter_2"
	DirAccess.make_dir_recursive_absolute(out)
	_run(mode, ticks, chapter)


func _shot(name: String) -> void:
	for i in 4:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [out, name])
	print("saved ", name)


func _run(mode: String, ticks: int, chapter: String) -> void:
	await process_frame
	var game = root.get_node("Game")
	var clock = root.get_node("Clock")
	if mode == "menu":
		change_scene_to_file("res://ui/menus/MainMenu.tscn")
		await create_timer(1.5).timeout
		await _shot("menu")
		quit()
		return
	game.new_game(mode, {"seed": 4242, "chapter": chapter, "workers": 120, "soldiers": 20, "scouts": 10, "nurses": 12})
	await create_timer(0.5).timeout
	clock.running = false
	var w = game.world
	var t0 := Time.get_ticks_msec()
	for i in ticks:
		clock.advance()
	print("advanced %d ticks in %d ms; ants %d" % [ticks, Time.get_ticks_msec() - t0, w.ants.alive])
	var main = current_scene
	main.hud.dialog_panel.visible = false
	main.set_view("nest")
	main.nest_view.focus_default()
	await _shot("nest")
	main.nest_view.camera.zoom *= 3.0
	await _shot("nest_zoom")
	main.nest_view.focus_default()
	main.toggle_overlay("air")
	await _shot("nest_air")
	main.toggle_overlay("air")
	if w.flags.get("surface", false):
		main.set_view("surface")
		main.surface_view.camera.zoom = Vector2.ONE * 1.2
		await _shot("surface")
		main.surface_view.camera.zoom = Vector2.ONE * 4.0
		await _shot("surface_close")
		main.surface_view.show_scent = true
		main.surface_view.camera.zoom = Vector2.ONE * 0.6
		await create_timer(0.5).timeout
		await _shot("surface_scent")
		main.surface_view.show_scent = false
		main.surface_view.camera.zoom = Vector2.ONE * 0.07
		main.surface_view.camera.position = w.surface.size * 0.5
		await _shot("surface_far")
	if main.house_view:
		main.set_view("house")
		await _shot("house")
	main.open_evolution()
	await _shot("evolution")
	main.open_guide()
	await _shot("guide")
	quit()
