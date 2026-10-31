extends RefCounted
## Shared setup for the acceptance tests. Static helpers only.


## Build a World, make it the active one and return it.
static func make_world(mode: String, opts: Dictionary) -> World:
	var w := World.new()
	w.setup(mode, opts)
	Game.world = w
	return w


## Small test-mode world: nest only unless flags say otherwise.
static func test_world(seed_value: int, start: Dictionary, flags: Dictionary = {"nest": true}, extra: Dictionary = {}) -> World:
	var opts := {"seed": seed_value, "flags": flags, "start": start, "difficulty": "normal"}
	opts.merge(extra, true)
	return make_world("test", opts)


static func advance(ticks: int) -> void:
	for i in ticks:
		Clock.advance()


static func hours(h: float) -> int:
	return int(h * Clock.ticks_per_hour)


static func done() -> void:
	Game.world = null


## Open every cell of a rectangle at once (no spoil, no ants needed).
static func excavate_rect(g: NestGrid, a: Vector2i, b: Vector2i) -> void:
	for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
		for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
			g.excavate(y * g.w + x)


static func rect_cells(g: NestGrid, a: Vector2i, b: Vector2i) -> PackedInt32Array:
	var out := PackedInt32Array()
	for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
		for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
			out.append(y * g.w + x)
	return out


## Living ants of a colony (optionally one caste) as an index list.
static func ants_of(w: World, colony: int, caste: String = "") -> PackedInt32Array:
	var out := PackedInt32Array()
	var ci := w.colonies[colony].caste_index(caste) if caste != "" else -1
	for i in w.ants.n:
		if w.ants.is_alive(i) and w.ants.home[i] == colony and (ci < 0 or w.ants.caste[i] == ci):
			out.append(i)
	return out


static func count_caste(w: World, colony: int, caste: String) -> int:
	return ants_of(w, colony, caste).size()


## First valid satellite site on a spiral around the main entrance, at least `dist` away.
static func find_nest_site(w: World, dist: float) -> Vector2:
	var ents := []
	for g in w.nests:
		ents.append(g.surface_pos)
	for k in 96:
		var p := w.surface.entrance + Vector2(dist + 40.0 * (k % 8), 0).rotated(k * 0.7)
		if w.surface.valid_nest_site(p, ents):
			return p
	return Vector2.INF
