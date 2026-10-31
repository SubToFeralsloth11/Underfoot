extends SceneTree
## Scripted 30 s trailer: one ant -> huge colony -> exterminator.
## Record with Movie Maker:
##   godot --path . --write-movie /tmp/underfoot_trailer.avi --fixed-fps 30 --resolution 1280x720 -s tools/trailer.gd
## then: ffmpeg -i /tmp/underfoot_trailer.avi -c:v libx264 -pix_fmt yuv420p docs/trailer.mp4

const FPS := 30.0
var game
var clock
var main


func _initialize() -> void:
	_run()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _caption(text: String) -> void:
	main.hud._on_toast(text)


func _run() -> void:
	await process_frame
	game = root.get_node("Game")
	clock = root.get_node("Clock")
	# Shot 1 (0-7 s): the first burrow.
	game.new_game("campaign", {"chapter": "chapter_1", "seed": 77})
	await _frames(3)
	main = current_scene
	main.hud.dialog_panel.visible = false
	main.hud.hint_panel.visible = false
	clock.speed = 4.0
	main.nest_view.camera.zoom = Vector2.ONE * 5.0
	main.nest_view.camera.position = game.world.nests[0].chambers[0]["center"]
	_caption("One queen. Five workers.")
	var g = game.world.nests[0]
	game.world.dig_rect(0, Vector2i(g.entrance_x - 14, 18), Vector2i(g.entrance_x + 14, 22), true)
	await _frames(int(FPS * 3.5))
	main.nest_view.camera.zoom = Vector2.ONE * 2.0
	_caption("Dig.")
	await _frames(int(FPS * 3.5))
	# Shot 2 (7-17 s): a big colony on the lawn.
	game.new_game("sandbox", {"seed": 4242, "workers": 400, "soldiers": 60, "scouts": 30, "nurses": 30, "flags": {"house": true}})
	await _frames(3)
	main = current_scene
	main.hud.dialog_panel.visible = false
	main.hud.hint_panel.visible = false
	clock.running = false
	for i in 1800:
		clock.advance()
	clock.running = true
	clock.speed = 2.0
	main.set_view("surface")
	main.surface_view.camera.zoom = Vector2.ONE * 3.0
	_caption("Forage. Follow the scent.")
	for i in int(FPS * 5):
		main.surface_view.camera.zoom = main.surface_view.camera.zoom * 0.988
		await process_frame
	main.surface_view.show_scent = true
	_caption("Ants follow pheromones, not orders.")
	await _frames(int(FPS * 5))
	main.surface_view.show_scent = false
	# Shot 3 (17-30 s): the house and the exterminator.
	main.set_view("house")
	_caption("One day, the whole house.")
	await _frames(int(FPS * 5))
	game.world.house_ai.add_escalation(200.0)
	main.set_view("house")
	_caption("...and they WILL call the Exterminator.")
	await _frames(int(FPS * 4))
	main.set_view("surface")
	main.surface_view.camera.position = game.world.nests[0].surface_pos
	main.surface_view.camera.zoom = Vector2.ONE * 0.5
	_caption("UNDERFOOT")
	await _frames(int(FPS * 4))
	quit()
