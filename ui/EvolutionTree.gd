class_name EvolutionTree
extends RefCounted
## Five branches of traits. Spend trait points from nuptial flights and new years.

const BRANCHES := ["jaws", "chemistry", "agriculture", "architecture", "swarm"]


static func open(parent: Control) -> Control:
	var m := UITheme.modal(parent, "Evolution", Vector2(1100, 600))
	_fill(m[1], m[0])
	return m[0]


static func _fill(v: VBoxContainer, root: Control) -> void:
	var w = Game.world
	var col: Colony = w.colonies[0]
	while v.get_child_count() > 1:
		var c := v.get_child(1)
		v.remove_child(c)
		c.queue_free()
	v.add_child(UITheme.label("Trait points: %d   (earn them from nuptial flights and each new year)" % col.trait_points, 15, UITheme.LEAF))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(1080, 510)
	v.add_child(scroll)
	var cols := UITheme.hbox(8)
	scroll.add_child(cols)
	var traits := Data.table("traits")
	for br in BRANCHES:
		var cv := UITheme.vbox(6)
		cv.custom_minimum_size.x = 205
		cols.add_child(cv)
		cv.add_child(UITheme.label(br.capitalize(), 18, UITheme.AMBER))
		var ids: Array = []
		for id in traits.keys():
			if traits[id]["branch"] == br:
				ids.append(id)
		ids.sort_custom(func(a, b): return int(traits[a].get("tier", 1)) < int(traits[b].get("tier", 1)) or (int(traits[a].get("tier", 1)) == int(traits[b].get("tier", 1)) and a < b))
		for id in ids:
			var t: Dictionary = traits[id]
			var have: bool = col.traits.has(id)
			var can: bool = col.can_unlock(id)
			var b := UITheme.button("%s%s  (%d)" % ["* " if have else "", t["name"], int(t.get("cost", 1))], func():
				if w.colonies[0].unlock_trait(id):
					for pc in w.player_colonies():
						if pc.index != 0 and not pc.traits.has(id):
							pc.unlock_trait(id, true)
					Events.trait_unlocked.emit(id)
					_fill(v, root))
			b.custom_minimum_size = Vector2(200, 0)
			b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			var req: PackedStringArray = []
			for r in t.get("requires", []):
				req.append(traits.get(r, {}).get("name", r))
			b.tooltip_text = "%s\nTier %d%s" % [t.get("desc", ""), int(t.get("tier", 1)), ("\nRequires: " + ", ".join(req)) if req.size() > 0 else ""]
			b.disabled = not can and not have
			if have:
				b.add_theme_color_override("font_color", UITheme.LEAF)
				b.add_theme_color_override("font_disabled_color", UITheme.LEAF)
				b.disabled = true
			cv.add_child(b)
