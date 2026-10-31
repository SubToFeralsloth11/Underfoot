class_name ColonyAI
extends RefCounted
## Automation for non-player-controlled colonies: the rival colony (same rules as
## the player, data-driven difficulty) and the starting layout of satellite nests.


## Mark a standard nest layout (nursery, food store, midden, vent) below the starter
## queen chamber. `instant` opens the cells immediately (pre-established rival nest).
static func plan_template(g: NestGrid, instant: bool) -> void:
	var ex := g.entrance_x
	var cfg: Dictionary = Data.table("nest")["starter"]
	var top := int(cfg["shaft_depth"]) + int(cfg["cavity"][1])
	var rects := [
		[Vector2i(ex, top), Vector2i(ex, top + 14), ""],
		[Vector2i(ex - 12, top + 10), Vector2i(ex + 12, top + 10), ""],
		[Vector2i(ex - 12, top + 7), Vector2i(ex - 4, top + 11), "nursery"],
		[Vector2i(ex + 4, top + 7), Vector2i(ex + 12, top + 11), "food_store"],
		[Vector2i(ex, top + 14), Vector2i(ex, top + 22), ""],
		[Vector2i(ex - 5, top + 20), Vector2i(ex + 5, top + 23), "midden"],
		[Vector2i(ex + 18, 0), Vector2i(ex + 18, top + 10), ""],
		[Vector2i(ex + 12, top + 10), Vector2i(ex + 18, top + 10), ""],
	]
	for r in rects:
		var a: Vector2i = r[0]
		var b: Vector2i = r[1]
		a = a.clamp(Vector2i(0, 0), Vector2i(g.w - 1, g.h - 1))
		b = b.clamp(Vector2i(0, 0), Vector2i(g.w - 1, g.h - 1))
		var type: String = r[2]
		var cells := PackedInt32Array()
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
				var c := y * g.w + x
				if instant:
					if g.can_dig(c):
						g.dig(c, 999.0)
				else:
					g.set_mark(c, true)
				cells.append(c)
		if type != "":
			g.assign_chamber(cells, type)


## Hourly decisions for the rival colony.
static func on_hour(world, col: Colony) -> void:
	if not col.alive or not col.queen_alive:
		return
	var season: Dictionary = Data.table("seasons").get(Clock.season(), {})
	var aggression := float(season.get("rival_aggression", 0.5)) * float(world.diff.get("rival_raid", 1.0))
	col.egg_rate = 1.2 * float(world.diff.get("rival_growth", 1.0)) * world.year_ramp()
	col.caste_targets = {"worker": 0.6, "soldier": 0.3 + 0.1 * aggression, "scout": 0.1, "nurse": 0.12}
	# Keep the rival fed enough to grow: it forages with the same rules, plus a trickle.
	col.add_store("sugar", 1.5 * float(world.diff.get("rival_growth", 1.0)), world.nests[col.nest])
	col.add_store("protein", 0.8 * float(world.diff.get("rival_growth", 1.0)), world.nests[col.nest])
	var r: Dictionary = world.rally[col.faction]
	if r["active"]:
		return
	var soldiers: int = col.counts[col.caste_index("soldier")]
	var days_since: float = (Clock.tick - int(r.get("last", -999999))) / float(Clock.ticks_per_hour * 24)
	var interval := 3.5 / maxf(aggression, 0.05)
	if aggression > 0.0 and soldiers >= 6 and days_since >= interval and world.flags.get("rival", false):
		var target_nest: int = world.weakest_player_nest()
		if target_nest >= 0:
			world.set_rally(col.faction, world.nests[target_nest].surface_pos, 4.0)
			r["last"] = Clock.tick
			Events.alert.emit("raid", "Red ants are marching on your nest! (%d soldiers)" % soldiers, world.nests[target_nest].surface_pos, AntSim.SPACE_SURFACE)
			Events.hint.emit("rival")
