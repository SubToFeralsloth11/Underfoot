class_name Minimap
extends Control
## Whole-yard overview: ground, nests, threats, ant density and the camera frame.
## Click to jump the surface camera there.

var _tex: ImageTexture
var _dots_timer := 0.0
var _ants := PackedVector2Array()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var w = Game.world
	var s: SurfaceWorld = w.surface
	var dw := s.w / 4
	var dh := s.h / 4
	var img := Image.create(dw, dh, false, Image.FORMAT_RGBA8)
	for y in dh:
		for x in dw:
			var i := (y * 4) * s.w + x * 4
			var c: Color = SurfaceView.GROUND_COLORS[s.ground[i]]
			if s.blocked[i] != 0:
				c = Color("#3a3028")
			elif s.shade[i] != 0:
				c = c.darkened(0.2)
			img.set_pixel(x, y, c)
	_tex = ImageTexture.create_from_image(img)


func _process(delta: float) -> void:
	_dots_timer -= delta
	if _dots_timer <= 0.0:
		_dots_timer = 0.5
		var ants: AntSim = Game.world.ants
		_ants = PackedVector2Array()
		var step := maxi(1, ants.n / 600)
		for i in range(0, ants.n, step):
			if ants.state[i] != AntSim.DEAD and ants.layer[i] == 1:
				_ants.append(ants.pos[i])
	queue_redraw()


func _draw() -> void:
	var w = Game.world
	var s: SurfaceWorld = w.surface
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, Color("#140e0a"))
	draw_texture_rect(_tex, r, false)
	var k := size / s.size
	for p in _ants:
		draw_rect(Rect2(p * k, Vector2(1.5, 1.5)), Color(0.1, 0.05, 0.02))
	for g in w.nests:
		var friendly: bool = g.owner >= 0 and w.colonies[g.owner].faction == 0
		draw_circle(g.surface_pos * k, 4.0, UITheme.AMBER if friendly else UITheme.DANGER)
	for cr in w.creatures.list:
		if cr["space"] == 0 and cr["behaviour"] in ["hunter", "raider", "mount", "swooper"]:
			draw_circle(cr["pos"] * k, 2.5, Color(1, 0.3, 0.2) if cr["behaviour"] != "mount" else Color(0.4, 0.8, 1))
	for f in s.foods.values():
		if f["space"] == 0:
			draw_rect(Rect2(f["pos"] * k - Vector2(1, 1), Vector2(2, 2)), Color(0.95, 0.85, 0.3))
	var main = get_tree().current_scene
	if main and main.has_method("surface_camera_rect"):
		var cr2: Rect2 = main.surface_camera_rect()
		draw_rect(Rect2(cr2.position * k, cr2.size * k), Color(1, 1, 1, 0.8), false, 1.0)
	draw_rect(r, UITheme.BORDER, false, 2.0)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		var main = get_tree().current_scene
		var s: SurfaceWorld = Game.world.surface
		if main and main.has_method("jump_to"):
			main.jump_to(e.position / size * s.size, AntSim.SPACE_SURFACE)
		accept_event()
