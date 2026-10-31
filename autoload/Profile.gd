extends Node
## Player profile persisted across games: campaign progress, Field Guide
## discoveries and which tutorial hints have already been shown.

const PATH := "user://profile.json"

var chapters_done: Dictionary = {}
var guide: Dictionary = {}
var hints_seen: Dictionary = {}


func _ready() -> void:
	load_profile()
	Events.discovered.connect(func(id):
		if not guide.has(id):
			guide[id] = true
			save_profile())
	Events.chapter_completed.connect(func(id):
		chapters_done[id] = true
		save_profile())


func load_profile() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if d is Dictionary:
		chapters_done = d.get("chapters_done", {})
		guide = d.get("guide", {})
		hints_seen = d.get("hints_seen", {})


func save_profile() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"chapters_done": chapters_done, "guide": guide, "hints_seen": hints_seen}, "  "))


## True the first time a hint id is requested; records it.
func take_hint(id: String) -> bool:
	if hints_seen.has(id):
		return false
	hints_seen[id] = true
	save_profile()
	return true


func reset_hints() -> void:
	hints_seen.clear()
	save_profile()


func chapter_unlocked(id: String) -> bool:
	if id == "chapter_1":
		return true
	for k in Data.campaign.keys():
		var c: Dictionary = Data.campaign[k]
		if c.get("next", "") == id:
			return chapters_done.has(k)
	return false
