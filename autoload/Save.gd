extends Node
## Binary save/load: user://saves/slot_N.ufs, gzip-compressed store_var.
## Autosaves every in-game dawn (06:00) to the "auto" slot.

const VERSION := 2
const DIR := "user://saves"
const AUTOSAVE_HOUR := 6

var autosave_enabled := true


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	Events.hour_passed.connect(_on_hour)


func slot_path(slot: String) -> String:
	return "%s/slot_%s.ufs" % [DIR, slot]


func _on_hour(h: int) -> void:
	if autosave_enabled and h == AUTOSAVE_HOUR and Game.world != null and Game.state == Game.State.PLAYING and Game.world.mode != "test":
		save_game("auto")


func snapshot() -> Dictionary:
	return {
		"version": VERSION,
		"clock": {"tick": Clock.tick, "offset": Clock.offset_ticks},
		"meta": {"label": Clock.label(), "mode": Game.world.mode, "population": Game.world.colony_population(), "saved": Time.get_datetime_string_from_system()},
		"world": Game.world.serialize(),
	}


func save_game(slot: String) -> bool:
	if Game.world == null:
		return false
	var f := FileAccess.open_compressed(slot_path(slot), FileAccess.WRITE, FileAccess.COMPRESSION_GZIP)
	if f == null:
		push_error("Save failed: %s" % FileAccess.get_open_error())
		return false
	f.store_var(snapshot(), false)
	f.close()
	Events.toast.emit("Saved (%s)" % slot)
	return true


func read_slot(slot: String) -> Dictionary:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_GZIP)
	if f == null:
		return {}
	var d: Variant = f.get_var(false)
	return d if d is Dictionary else {}


## Restore a snapshot into a fresh World and the Clock. Returns the world.
func restore(d: Dictionary) -> World:
	d = migrate(d)
	if d.is_empty():
		return null
	Clock.tick = int(d["clock"]["tick"])
	Clock.offset_ticks = int(d["clock"]["offset"])
	var w := World.new()
	w.deserialize(d["world"])
	return w


func load_game(slot: String) -> bool:
	var d := read_slot(slot)
	if d.is_empty():
		Events.toast.emit("No save in slot %s" % slot)
		return false
	var w := restore(d)
	if w == null:
		return false
	Game.load_world(w)
	Events.toast.emit("Loaded (%s)" % slot)
	return true


func slot_meta(slot: String) -> Dictionary:
	var d := read_slot(slot)
	return d.get("meta", {})


## Upgrade older save dictionaries step by step to VERSION.
func migrate(d: Dictionary) -> Dictionary:
	var v := int(d.get("version", 1))
	if v > VERSION:
		push_error("Save is from a newer version (%d)" % v)
		return {}
	while v < VERSION:
		match v:
			1:
				d = _migrate_1_to_2(d)
		v += 1
		d["version"] = v
	return d


## v1 stored the clock as flat "tick"/"offset" keys and pheromone fields without
## per-entry decay stamps (values were stored already decayed to "now").
func _migrate_1_to_2(d: Dictionary) -> Dictionary:
	d["clock"] = {"tick": d.get("tick", 0), "offset": d.get("offset", 0)}
	d.erase("tick")
	d.erase("offset")
	for p in d["world"].get("pher", []):
		if not p.has("stamp"):
			var stamp := PackedFloat32Array()
			stamp.resize(p["val"].size())
			stamp.fill(p.get("clock", 0.0))
			p["stamp"] = stamp
	return d


## Produce a v1-format copy of a snapshot (used to test migration).
func downgrade_to_v1(d: Dictionary) -> Dictionary:
	var out := d.duplicate(true)
	out["version"] = 1
	out["tick"] = out["clock"]["tick"]
	out["offset"] = out["clock"]["offset"]
	out.erase("clock")
	for p in out["world"].get("pher", []):
		var val: PackedFloat32Array = p["val"]
		var stamp: PackedFloat32Array = p["stamp"]
		var k: PackedFloat32Array = p["k"]
		var cells: int = p["w"] * p["h"]
		var clk: float = p["clock"]
		for ch in k.size():
			var kk := k[ch]
			for c in cells:
				var i := ch * cells + c
				if val[i] != 0.0:
					val[i] = val[i] * exp(-kk * (clk - stamp[i]))
		p["val"] = val
		p.erase("stamp")
	return out
