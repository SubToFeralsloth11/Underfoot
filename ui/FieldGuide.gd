class_name FieldGuide
extends RefCounted
## Catalogue of backyard species, unlocked on first encounter (persists in the profile).


class Portrait extends Control:
	var def: Dictionary = {}
	var known := false

	func _ready() -> void:
		custom_minimum_size = Vector2(96, 96)

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color("#3a2c20"))
		draw_rect(Rect2(Vector2.ZERO, size), UITheme.BORDER, false, 2.0)
		if def.is_empty():
			return
		var t := Time.get_ticks_msec() / 1000.0
		var plan: String = def.get("body", {}).get("plan", "insect")
		var sz := size.x * (0.55 if plan in ["worm", "myriapod"] else 0.7)
		if known:
			ArtGen.draw_bug(self, def, size * 0.5, -PI * 0.5, sz, t * 0.4)
		else:
			ArtGen.draw_bug(self, {"body": {"plan": plan, "color": "#1a120c", "accent": "#100a06", "segments": def.get("body", {}).get("segments", 3), "legs": def.get("body", {}).get("legs", 6)}}, size * 0.5, -PI * 0.5, sz, 0.0)
			draw_string(ThemeDB.fallback_font, size * 0.5 + Vector2(-6, 8), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 28, UITheme.AMBER)


static func open(parent: Control) -> Control:
	var defs := Data.table("creatures")
	var known := 0
	for k in defs.keys():
		if Profile.guide.has(k):
			known += 1
	var m := UITheme.modal(parent, "Field Guide  (%d / %d)" % [known, defs.size()], Vector2(1000, 600))
	var v: VBoxContainer = m[1]
	var h := UITheme.hbox(10)
	v.add_child(h)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, 520)
	h.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 5
	scroll.add_child(grid)
	var detail := UITheme.vbox(6)
	detail.custom_minimum_size = Vector2(400, 520)
	h.add_child(detail)
	var big := Portrait.new()
	big.custom_minimum_size = Vector2(220, 220)
	detail.add_child(big)
	var info := RichTextLabel.new()
	info.bbcode_enabled = true
	info.custom_minimum_size = Vector2(400, 280)
	detail.add_child(info)
	var ids := defs.keys()
	ids.sort_custom(func(a, b): return String(defs[a].get("category", "")) + a < String(defs[b].get("category", "")) + b)
	for id in ids:
		var d: Dictionary = defs[id]
		var is_known: bool = Profile.guide.has(id)
		var cell := UITheme.vbox(2)
		var p := Portrait.new()
		p.def = d
		p.known = is_known
		p.mouse_filter = Control.MOUSE_FILTER_STOP
		p.gui_input.connect(func(e):
			if e is InputEventMouseButton and e.pressed:
				big.def = d
				big.known = is_known
				if is_known:
					info.text = "[b][color=#f0a830]%s[/color][/b]\n[i]%s[/i] - %s\n\n%s\n\n[color=#b8a58a]HP %s   speed %s mm/s   bite %s   size %s mm\nBehaviour: %s   Found: %s[/color]" % [d.get("name", id), d.get("latin", ""), d.get("category", ""), d.get("guide", ""), str(d.get("hp", "?")), str(d.get("speed", "?")), str(d.get("damage", "?")), str(d.get("size", "?")), d.get("behaviour", ""), d.get("layer", "")]
				else:
					info.text = "[b]???[/b]\nNot yet encountered. Send ants out to meet the neighbours.")
		cell.add_child(p)
		cell.add_child(UITheme.label(d.get("name", id) if is_known else "???", 11, UITheme.TEXT if is_known else UITheme.MUTED))
		grid.add_child(cell)
	return m[0]
