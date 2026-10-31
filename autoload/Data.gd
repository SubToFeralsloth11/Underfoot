extends Node
## Loads every data/*.json (and data/campaign/*.json) at boot.
## Bad JSON is a hard error: it is pushed, recorded in `errors`, and asserts in debug.

const DATA_DIR := "res://data"
const CAMPAIGN_DIR := "res://data/campaign"

var db: Dictionary = {}
var campaign: Dictionary = {}
var errors: PackedStringArray = []


func _ready() -> void:
	reload()


func reload() -> void:
	db.clear()
	campaign.clear()
	errors.clear()
	for f in _list_json(DATA_DIR):
		db[f.get_basename()] = load_json(DATA_DIR + "/" + f)
	for f in _list_json(CAMPAIGN_DIR):
		campaign[f.get_basename()] = load_json(CAMPAIGN_DIR + "/" + f)


func table(name: String) -> Dictionary:
	var t: Variant = db.get(name, {})
	return t if t is Dictionary else {}


func load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		_fail("Missing data file: %s" % path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		_fail("Bad JSON in %s line %d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return {}
	return json.data


func _fail(msg: String) -> void:
	errors.append(msg)
	push_error(msg)
	assert(false, msg)


func _list_json(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for f in dir.get_files():
		# Exported builds may list remapped files; JSON stays as-is.
		if f.ends_with(".json"):
			out.append(f)
	out.sort()
	return out
