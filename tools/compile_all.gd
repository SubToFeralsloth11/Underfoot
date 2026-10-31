extends SceneTree
## Load every project script so parse/compile errors surface headless.

func _initialize() -> void:
	await process_frame
	var bad := 0
	for dir in ["res://autoload", "res://sim", "res://view", "res://view/FX", "res://ui", "res://ui/menus", "res://"]:
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for f in d.get_files():
			if f.ends_with(".gd"):
				var path: String = dir.path_join(f)
				var s = load(path)
				if s == null or not s.can_instantiate():
					print("FAILED: ", path)
					bad += 1
	print("compile check done, failures: ", bad)
	quit(1 if bad > 0 else 0)
