class_name UITheme
extends RefCounted
## Earthy palette (soil browns, leaf greens, warning amber) + small widget helpers.

const BG := Color("#1e1610")
const PANEL := Color("#2b2018")
const PANEL_LIGHT := Color("#3b2c20")
const BORDER := Color("#6b4a2b")
const TEXT := Color("#efe4d0")
const MUTED := Color("#b8a58a")
const LEAF := Color("#7fb046")
const AMBER := Color("#f0a830")
const DANGER := Color("#e0503a")
const WATER := Color("#5aa0d8")

static var _theme: Theme


static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font_size = 15
	var panel := _box(PANEL, BORDER, 2, 6)
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "Panel", panel)
	var btn := _box(PANEL_LIGHT, BORDER, 1, 5)
	var btn_h := _box(Color("#4d3a28"), AMBER, 1, 5)
	var btn_p := _box(Color("#5a4430"), LEAF, 2, 5)
	var btn_d := _box(Color("#241a12"), Color("#3a2c20"), 1, 5)
	for k in ["normal", "focus"]:
		t.set_stylebox(k, "Button", btn)
	t.set_stylebox("hover", "Button", btn_h)
	t.set_stylebox("pressed", "Button", btn_p)
	t.set_stylebox("disabled", "Button", btn_d)
	t.set_stylebox("hover_pressed", "Button", btn_p)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", LEAF.lightened(0.4))
	t.set_color("font_disabled_color", "Button", Color("#6a5a4a"))
	t.set_color("font_color", "Label", TEXT)
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_constant("separation", "HBoxContainer", 6)
	t.set_constant("separation", "VBoxContainer", 4)
	var sl := StyleBoxFlat.new()
	sl.bg_color = Color("#140e0a")
	sl.content_margin_top = 3
	sl.content_margin_bottom = 3
	t.set_stylebox("slider", "HSlider", sl)
	var pb_bg := _box(Color("#140e0a"), BORDER, 1, 3)
	var pb_fill := _box(LEAF, LEAF, 0, 3)
	t.set_stylebox("background", "ProgressBar", pb_bg)
	t.set_stylebox("fill", "ProgressBar", pb_fill)
	t.set_color("font_color", "ProgressBar", TEXT)
	var le := _box(Color("#140e0a"), BORDER, 1, 4)
	t.set_stylebox("normal", "LineEdit", le)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_stylebox("panel", "TooltipPanel", _box(Color("#140e0a"), AMBER, 1, 4))
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_stylebox("normal", "OptionButton", btn)
	t.set_stylebox("hover", "OptionButton", btn_h)
	t.set_stylebox("pressed", "OptionButton", btn_p)
	t.set_color("font_color", "OptionButton", TEXT)
	t.set_stylebox("panel", "PopupMenu", _box(PANEL, BORDER, 1, 4))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_stylebox("panel", "TabContainer", panel)
	_theme = t
	return t


static func _box(bg: Color, border: Color, bw: int, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_corner_radius_all(radius)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 5
	s.content_margin_bottom = 5
	return s


static func label(text: String, size: int = 15, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func button(text: String, cb: Callable, tooltip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tooltip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func():
		Audio.play("ui_click", -8.0)
		cb.call())
	return b


static func panel(min_size: Vector2 = Vector2.ZERO) -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = min_size
	return p


static func vbox(sep: int = 4) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func hbox(sep: int = 6) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


## A centered modal window: dark backdrop + panel. Returns [root, content_vbox].
static func modal(parent: Node, title: String, size: Vector2) -> Array:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	var p := panel(size)
	p.set_anchors_preset(Control.PRESET_CENTER)
	p.offset_left = -size.x * 0.5
	p.offset_right = size.x * 0.5
	p.offset_top = -size.y * 0.5
	p.offset_bottom = size.y * 0.5
	p.size = size
	root.add_child(p)
	var v := vbox(8)
	p.add_child(v)
	var head := hbox()
	var tl := label(title, 22, AMBER)
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(tl)
	head.add_child(button("✕", func(): root.queue_free(), "Close (Esc)"))
	v.add_child(head)
	parent.add_child(root)
	Audio.play("ui_open", -6.0)
	return [root, v]
