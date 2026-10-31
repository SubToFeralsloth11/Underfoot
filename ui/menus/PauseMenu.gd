class_name PauseMenu
extends RefCounted
## Pause menu: resume, save/load slots, settings, quit to menu.


static func open(parent: Control) -> Control:
	var m := UITheme.modal(parent, "Paused", Vector2(420, 460))
	var root: Control = m[0]
	var v: VBoxContainer = m[1]
	v.add_child(UITheme.button("Resume", func(): root.queue_free()))
	for slot in ["1", "2", "3"]:
		var meta := Save.slot_meta(slot)
		var h := UITheme.hbox()
		var lbl := UITheme.label("Slot %s: %s" % [slot, meta.get("label", "empty")], 13, UITheme.MUTED)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(lbl)
		h.add_child(UITheme.button("Save", func():
			Save.save_game(slot)
			root.queue_free()))
		var lb := UITheme.button("Load", func(): Save.load_game(slot))
		lb.disabled = meta.is_empty()
		h.add_child(lb)
		v.add_child(h)
	var auto := Save.slot_meta("auto")
	var al := UITheme.button("Load autosave (%s)" % auto.get("label", "none"), func(): Save.load_game("auto"))
	al.disabled = auto.is_empty()
	v.add_child(al)
	v.add_child(UITheme.button("Settings", func(): SettingsMenu.open(parent)))
	v.add_child(UITheme.button("Restart", func(): Game.restart()))
	v.add_child(UITheme.button("Main menu", func(): Game.to_menu()))
	return root
