class_name RainFX
extends Control
## Screen-space rain streaks and splash ripples; intensity 0..1.

var intensity := 0.0
var _drops: Array = []
var _ripples: Array = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size = get_viewport().get_visible_rect().size
	get_viewport().size_changed.connect(func(): size = get_viewport().get_visible_rect().size)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	var sz := size
	var want := int(intensity * 260)
	while _drops.size() < want:
		_drops.append([Vector2(randf() * sz.x, randf() * sz.y), randf_range(700, 1100)])
	while _drops.size() > want:
		_drops.pop_back()
	for d in _drops:
		d[0].y += d[1] * delta
		d[0].x -= d[1] * delta * 0.15
		if d[0].y > sz.y or randf() < 0.01:
			if randf() < 0.3:
				_ripples.append([d[0], 0.0])
			d[0] = Vector2(randf() * sz.x * 1.1, -10.0)
	var keep: Array = []
	for r in _ripples:
		r[1] += delta
		if r[1] < 0.5:
			keep.append(r)
	_ripples = keep
	if intensity > 0.0 or _ripples.size() > 0:
		queue_redraw()


func _draw() -> void:
	var c := Color(0.75, 0.85, 1.0, 0.35)
	for d in _drops:
		draw_line(d[0], d[0] + Vector2(-3, 14), c, 1.2)
	for r in _ripples:
		draw_arc(r[0], 3.0 + r[1] * 20.0, 0, TAU, 12, Color(0.8, 0.9, 1.0, 0.5 - r[1]), 1.0)
