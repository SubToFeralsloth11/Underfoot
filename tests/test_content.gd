extends GutTest
## Phase 9: every campaign chapter boots and its objectives evaluate; Endless yards are seeded.

const H := preload("res://tests/helpers.gd")
const OBJECTIVES := ["chambers", "population", "hatched", "stores", "harvested", "kills", "survive_days", "survive_season", "rival_destroyed", "reach_house", "traits", "satellites", "exterminator_defeated", "flight"]
const EVENTS := ["hint", "dialog", "spawn", "weather", "food", "escalation", "season", "trait_points"]


func after_each() -> void:
	H.done()


func _chapters() -> Array:
	var out := []
	for k in Data.campaign.keys():
		if String(k).begins_with("chapter_"):
			out.append(k)
	out.sort()
	return out


func test_every_chapter_sets_up_and_its_objectives_evaluate() -> void:
	var chapters := _chapters()
	assert_eq(chapters.size(), 5, "five campaign chapters")
	for id in chapters:
		var ch: Dictionary = Data.campaign[id]
		assert_true(Data.campaign.has(ch.get("yard", "")), "%s yard %s exists" % [id, ch.get("yard", "")])
		for e in ch.get("events", []):
			assert_true(e.get("type", "") in EVENTS, "%s event type %s is handled" % [id, e.get("type", "")])
			var p: Dictionary = e.get("params", {})
			if e["type"] == "spawn":
				assert_true(Data.table("creatures").has(p.get("creature", "wolf_spider")), "%s spawns a known creature" % id)
			if e["type"] == "food":
				assert_true(Data.table("foods").has(p.get("food", "dropped_chip")), "%s drops a known food" % id)
		for t in ch.get("start", {}).get("traits", []):
			assert_true(Data.table("traits").has(t), "%s starts with known trait %s" % [id, t])
		var w := H.make_world("campaign", {"chapter": id, "seed": 3, "difficulty": "normal"})
		assert_true(w.campaign.active(), "%s campaign active" % id)
		assert_gt(w.campaign.objectives().size(), 0)
		assert_true(w.colonies[0].queen_alive)
		assert_gt(H.ants_of(w, 0).size(), 1, "%s has a colony" % id)
		var ids := {}
		for o in w.campaign.objectives():
			assert_true(o.get("type", "") in OBJECTIVES, "%s objective %s has a handled type (%s)" % [id, o.get("id", "?"), o.get("type", "")])
			assert_false(ids.has(o["id"]), "objective ids are unique")
			ids[o["id"]] = true
			var pr := w.campaign.progress(o)
			assert_gt(pr.y, 0.0, "%s/%s has a target" % [id, o["id"]])
		H.advance(H.hours(2))
		assert_false(w.over, "%s survives its first two hours untouched" % id)
		for o in w.campaign.objectives():
			var pr := w.campaign.progress(o)
			assert_gte(pr.x, 0.0)
		gut.p("%s: %d objectives, %d ants after 2 h, %d events fired" % [id, w.campaign.objectives().size(), w.colonies[0].population(), w.campaign.fired.size()])
		H.done()


func test_chapter_one_dig_objectives_complete_when_chambers_are_built() -> void:
	var w := H.make_world("campaign", {"chapter": "chapter_1", "seed": 3, "difficulty": "normal"})
	var completed := []
	var cb := func(oid: String): completed.append(oid)
	Events.objective_completed.connect(cb)
	var g := w.nests[0]
	var ex := g.entrance_x
	H.excavate_rect(g, Vector2i(ex + 5, 12), Vector2i(ex + 20, 14))
	assert_eq(w.chamber_rect(0, Vector2i(ex + 13, 10), Vector2i(ex + 20, 14), "nursery"), "")
	H.excavate_rect(g, Vector2i(ex - 21, 10), Vector2i(ex - 6, 14))
	assert_eq(w.chamber_rect(0, Vector2i(ex - 21, 10), Vector2i(ex - 13, 14), "food_store"), "")
	H.advance(40)
	Events.objective_completed.disconnect(cb)
	assert_true("dig3" in completed, "three chambers objective done")
	assert_true("nursery" in completed)
	assert_false(w.campaign.completed, "hatching 5 ants is still to do")


func test_endless_yard_is_reproducible_from_its_seed() -> void:
	assert_eq(var_to_bytes(SurfaceWorld.procedural_yard(4242)), var_to_bytes(SurfaceWorld.procedural_yard(4242)))
	assert_ne(var_to_bytes(SurfaceWorld.procedural_yard(4242)), var_to_bytes(SurfaceWorld.procedural_yard(4243)))
	var a := H.make_world("endless", {"seed": 4242})
	var ground_a := a.surface.ground
	var blocked_a := a.surface.blocked
	var foods_a := var_to_bytes(a.surface.foods)
	var ent_a := a.nests[0].surface_pos
	var soil_a := a.nests[0].soil_type
	H.done()
	var b := H.make_world("endless", {"seed": 4242})
	assert_eq(b.surface.ground, ground_a, "same ground")
	assert_eq(b.surface.blocked, blocked_a, "same obstacles")
	assert_eq(var_to_bytes(b.surface.foods), foods_a, "same starting food")
	assert_eq(b.nests[0].surface_pos, ent_a, "same nest site")
	assert_eq(b.nests[0].soil_type, soil_a, "same soil")
	H.done()
	var c := H.make_world("endless", {"seed": 4243})
	assert_ne(c.surface.blocked, blocked_a, "another seed gives another yard")
