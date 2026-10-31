class_name CastePanel
extends RefCounted
## Caste ratio sliders. Nurses feed larvae the matching diet:
## protein-heavy makes soldiers/majors, sugar-heavy makes scouts/minims.


static func open(parent: Control) -> Control:
	var w = Game.world
	var col: Colony = w.colonies[0]
	var m := UITheme.modal(parent, "Castes", Vector2(560, 420))
	var v: VBoxContainer = m[1]
	var intro := UITheme.label("Set the target mix. Larvae are assigned the caste furthest below its target, and nurses feed them its diet. Without enough protein in stores, would-be soldiers grow up as workers.", 13, UITheme.MUTED)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size.x = 520
	v.add_child(intro)
	var grid := GridContainer.new()
	grid.columns = 4
	v.add_child(grid)
	for h in ["Caste", "Target", "Now", "Diet"]:
		grid.add_child(UITheme.label(h, 13, UITheme.AMBER))
	for c in col.producible_castes():
		var ci := col.caste_index(c)
		var d: Dictionary = col.caste_defs[ci]
		var name_l := UITheme.label(c.capitalize())
		name_l.tooltip_text = "HP %d  speed %.1f  attack %.1f  dig %.1f  carry %.1f  upkeep %.1f/day" % [col.c_hp[ci], d["speed"], col.c_attack[ci], col.c_dig[ci], col.c_carry[ci], col.c_food[ci]]
		name_l.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(name_l)
		var s := HSlider.new()
		s.min_value = 0
		s.max_value = 100
		s.step = 1
		s.custom_minimum_size.x = 220
		s.value = float(col.caste_targets.get(c, 0.0)) * 100.0
		s.value_changed.connect(func(val):
			for pc in w.player_colonies():
				pc.caste_targets[c] = val / 100.0)
		grid.add_child(s)
		var now := 0
		for pc in w.player_colonies():
			now += pc.counts[ci]
		grid.add_child(UITheme.label(str(now)))
		grid.add_child(UITheme.label("%d%% protein" % int(float(d["diet"]) * 100), 13, UITheme.MUTED))
	var b := col.brood_counts()
	v.add_child(UITheme.label("Brood: %d eggs, %d larvae, %d pupae.  Larvae in progress by caste: %s" % [b.x, b.y, b.z, _brood_castes(col)], 13))
	return m[0]


static func _brood_castes(col: Colony) -> String:
	var d := {}
	for br in col.brood:
		if br["stage"] >= Colony.STAGE_LARVA:
			d[br["caste"]] = d.get(br["caste"], 0) + 1
	var parts: PackedStringArray = []
	for k in d.keys():
		parts.append("%s %d" % [k, d[k]])
	return ", ".join(parts) if parts.size() > 0 else "none"
