class_name AntSim
extends RefCounted
## Data-oriented ant simulation: every ant is a row in packed arrays.
## Dead ants go on a free list and their slots are reused; arrays never shrink.
##
## Spaces: 0 = surface, 1 = house, 2+i = nest i. Movement:
##  - surface/house: pheromone steering (3 antenna samples) + homing + collision.
##  - nests: flow fields over open cells (no per-ant pathfinding).

enum { IDLE, WANDER, FOLLOW, CARRY, DIG, NURSE, FIGHT, FLEE, DEAD, HAUL, TASK }
enum { J_NONE, J_DIG, J_NURSE, J_STORE, J_FORAGE, J_SPOIL, J_PATROL, J_REST, J_TRADE, J_RALLY, J_RAID, J_QUEEN, J_BROOD }
const NJOBS := 13
const STATE_NAMES := ["Idle", "Wander", "Follow trail", "Carry", "Dig", "Nurse", "Fight", "Flee", "Dead", "Haul", "Task"]
const JOB_NAMES := ["-", "Digging", "Nursing", "Storing food", "Foraging", "Removing spoil", "Patrolling", "Resting", "Trading", "Rallying", "Raiding", "Queen", "Moving brood"]

const ITEM_NONE := 0
const ITEM_SPOIL := 1
const ITEM_NAMES := ["", "spoil", "sugar", "protein", "seeds", "water", "brood", "leaf", "poison", "fungus"]
const ITEM_COLORS := [Color(0, 0, 0, 0), Color("#7a5a3a"), Color("#f2d16b"), Color("#d0504a"), Color("#c8a040"), Color("#7ec8f0"), Color("#f4f0e0"), Color("#6aa030"), Color("#40d0f0"), Color("#e0d8f0")]

const SPACE_SURFACE := 0
const SPACE_HOUSE := 1
const SPACE_NEST0 := 2
const LAYER_NEST := 0
const LAYER_SURFACE := 1
const LAYER_HOUSE := 2

const HASH_CELL := 16.0
const HASH_W := 1260
const HASH_H := 1200

var world  # World (untyped to avoid a cyclic class reference)

var n := 0
var alive := 0
var pos := PackedVector2Array()
var prev := PackedVector2Array()
var vel := PackedVector2Array()
var heading := PackedFloat32Array()
var layer := PackedByteArray()
var caste := PackedByteArray()
var state := PackedByteArray()
var job := PackedByteArray()
var carry := PackedByteArray()
var carry_amt := PackedFloat32Array()
var hp := PackedFloat32Array()
var age := PackedFloat32Array()
var timer := PackedFloat32Array()
var target := PackedInt32Array()
var faction := PackedByteArray()
var home := PackedByteArray()
var inside := PackedByteArray()
var free := PackedInt32Array()

var hash_head := PackedInt32Array()
var hash_next := PackedInt32Array()
var hcell := PackedInt32Array()

## Per colony * caste counts and per colony * job counts (rebuilt each tick).
var counts := PackedInt32Array()
var job_counts := PackedInt32Array()
var nurse_power := PackedFloat32Array()
var want := PackedInt32Array()  # per colony * job quota
var traffic := PackedInt32Array()  # per colony: ants that walked a trail this tick
var ncastes := 8

var cfg: Dictionary = {}
var sense_dist := 22.0
var sense_angle := 0.6
var turn_rate := 4.0
var wander_noise := 1.6
var deposit_interval := 3
var home_deposit := 1.0
var food_deposit := 6.0
var explore_deposit := 1.0
var alarm_deposit := 25.0
var trail_fade := 90.0
var homing_weight := 0.9
var player_weight := 3.0
var alarm_avoid := 4.0
var give_up := 150.0
var nest_speed_mult := 0.6
var max_ants := 12000
var ants_per_nurse := 4
var tick := 0


func _init(w = null) -> void:
	world = w
	cfg = Data.table("castes").get("_ants", {})
	sense_dist = float(cfg.get("sense_dist", 22.0))
	sense_angle = float(cfg.get("sense_angle", 0.6))
	turn_rate = float(cfg.get("turn_rate", 4.0))
	wander_noise = float(cfg.get("wander_noise", 1.6))
	deposit_interval = int(cfg.get("deposit_interval", 3))
	home_deposit = float(cfg.get("home_deposit", 1.0))
	food_deposit = float(cfg.get("food_deposit", 6.0))
	explore_deposit = float(cfg.get("explore_deposit", 1.0))
	alarm_deposit = float(cfg.get("alarm_deposit", 25.0))
	trail_fade = float(cfg.get("trail_fade_seconds", 90.0))
	homing_weight = float(cfg.get("homing_weight", 0.9))
	player_weight = float(cfg.get("player_weight", 3.0))
	alarm_avoid = float(cfg.get("alarm_avoid", 4.0))
	give_up = float(cfg.get("forage_give_up_seconds", 150.0))
	nest_speed_mult = float(cfg.get("nest_speed_mult", 0.6))
	max_ants = int(cfg.get("max_ants", 12000))
	ants_per_nurse = int(cfg.get("ants_per_nurse", 4))
	hash_head.resize(HASH_W * HASH_H)
	hash_head.fill(-1)


static func space_offset(space: int) -> Vector2:
	if space == SPACE_SURFACE:
		return Vector2.ZERO
	if space == SPACE_HOUSE:
		return Vector2(0, 15400)
	var i := space - SPACE_NEST0
	return Vector2((i % 18) * 1100, 18000 + (i / 18) * 900)


func space_of(i: int) -> int:
	var l := layer[i]
	if l == LAYER_SURFACE:
		return SPACE_SURFACE
	if l == LAYER_HOUSE:
		return SPACE_HOUSE
	return SPACE_NEST0 + inside[i]


# ---------------------------------------------------------------- lifecycle

func _grow(to: int) -> void:
	for arr_name in ["pos", "prev", "vel"]:
		var a: PackedVector2Array = get(arr_name)
		a.resize(to)
		set(arr_name, a)
	for arr_name in ["heading", "carry_amt", "hp", "age", "timer"]:
		var a: PackedFloat32Array = get(arr_name)
		a.resize(to)
		set(arr_name, a)
	for arr_name in ["layer", "caste", "state", "job", "carry", "faction", "home", "inside"]:
		var a: PackedByteArray = get(arr_name)
		a.resize(to)
		set(arr_name, a)
	target.resize(to)
	hash_next.resize(to)
	hcell.resize(to)


func spawn(colony_idx: int, caste_idx: int, p: Vector2, lyr: int, nest_idx: int) -> int:
	var i := -1
	if free.size() > 0:
		i = free[free.size() - 1]
		free.remove_at(free.size() - 1)
	else:
		if n >= max_ants:
			return -1
		i = n
		n += 1
		if n > pos.size():
			_grow(maxi(64, pos.size() * 2))
	var col = world.colonies[colony_idx]
	pos[i] = p
	prev[i] = p
	vel[i] = Vector2.ZERO
	heading[i] = world.rng_ants.randf() * TAU
	layer[i] = lyr
	caste[i] = caste_idx
	state[i] = IDLE
	job[i] = J_NONE
	carry[i] = ITEM_NONE
	carry_amt[i] = 0.0
	hp[i] = col.c_hp[caste_idx]
	age[i] = 0.0
	timer[i] = 0.0
	target[i] = -1
	faction[i] = col.faction
	home[i] = colony_idx
	inside[i] = nest_idx
	alive += 1
	if col.caste_names[caste_idx] == "queen":
		job[i] = J_QUEEN
		col.queen_ant = i
	return i


func kill(i: int, cause: String) -> void:
	if state[i] == DEAD:
		return
	var sp := space_of(i)
	state[i] = DEAD
	alive -= 1
	free.append(i)
	var col = world.colonies[home[i]]
	col.deaths[cause] = col.deaths.get(cause, 0) + 1
	if job[i] == J_QUEEN:
		col.queen_alive = false
		col.queen_ant = -1
		world.on_queen_died(home[i], cause)
	if carry[i] != ITEM_NONE and layer[i] != LAYER_NEST and carry_amt[i] > 0.0 and carry[i] != ITEM_SPOIL:
		pass  # dropped crumbs are lost
	if layer[i] == LAYER_NEST:
		var g: NestGrid = world.nests[inside[i]]
		var c := g.cell_at(pos[i])
		if c >= 0 and g.chamber_id[c] > 0:
			g.chambers[g.chamber_id[c] - 1]["corpses"] += 1
	Events.ant_died.emit(cause, pos[i], sp)


func is_alive(i: int) -> bool:
	return i >= 0 and i < n and state[i] != DEAD


# ---------------------------------------------------------------- spatial hash

func _hash_index(i: int) -> int:
	var v := pos[i] + space_offset(space_of(i))
	var x := clampi(int(v.x / HASH_CELL), 0, HASH_W - 1)
	var y := clampi(int(v.y / HASH_CELL), 0, HASH_H - 1)
	return y * HASH_W + x


func rebuild_hash() -> void:
	hash_head.fill(-1)
	var inv := 1.0 / HASH_CELL
	var house_off := space_offset(SPACE_HOUSE)
	var nest_off := PackedVector2Array()
	nest_off.resize(world.nests.size())
	for k in nest_off.size():
		nest_off[k] = space_offset(SPACE_NEST0 + k)
	for i in n:
		if state[i] == DEAD:
			hcell[i] = -1
			continue
		var l := layer[i]
		var v := pos[i]
		if l == LAYER_HOUSE:
			v += house_off
		elif l == LAYER_NEST:
			v += nest_off[inside[i]]
		var x := clampi(int(v.x * inv), 0, HASH_W - 1)
		var y := clampi(int(v.y * inv), 0, HASH_H - 1)
		var hc := y * HASH_W + x
		hcell[i] = hc
		hash_next[i] = hash_head[hc]
		hash_head[hc] = i


## Living ants within r of p in a space.
func ants_near(space: int, p: Vector2, r: float, max_count: int = 64) -> PackedInt32Array:
	var out := PackedInt32Array()
	var v := p + space_offset(space)
	var x0 := clampi(int((v.x - r) / HASH_CELL), 0, HASH_W - 1)
	var x1 := clampi(int((v.x + r) / HASH_CELL), 0, HASH_W - 1)
	var y0 := clampi(int((v.y - r) / HASH_CELL), 0, HASH_H - 1)
	var y1 := clampi(int((v.y + r) / HASH_CELL), 0, HASH_H - 1)
	var r2 := r * r
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var j := hash_head[y * HASH_W + x]
			while j >= 0:
				if state[j] != DEAD and space_of(j) == space and pos[j].distance_squared_to(p) <= r2:
					out.append(j)
					if out.size() >= max_count:
						return out
				j = hash_next[j]
	return out


func count_in_cell(i: int) -> int:
	var c := 0
	var j := hash_head[hcell[i]]
	while j >= 0:
		c += 1
		j = hash_next[j]
	return c


# ---------------------------------------------------------------- step

## Per-step caches so the hot loop avoids long property chains through `world`.
var _cols: Array = []
var _rng: RandomNumberGenerator
var _surf: SurfaceWorld
var _house: NestGrid
var _home_pos := PackedVector2Array()
var _speed := PackedFloat32Array()
var _sense := PackedFloat32Array()
var _wander := PackedFloat32Array()
var _life := PackedFloat32Array()
var _player_w := PackedFloat32Array()
var _surface_open := true
var _house_flag := false
var _weather_speed := 1.0
## Read-only views of static surface grids (never written after generation, so no COW copies).
var _blocked := PackedByteArray()
var _ground := PackedByteArray()
var _sw := 0
var _sh := 0
var _sinv := 0.04
var _hazard_on := false
var _air_lethal := 22.0
var _air_damage := 0.6
var _flood_level := 170.0
var _flood_damage := 0.5


func _cache() -> void:
	_cols = world.colonies
	_rng = world.rng_ants
	_surf = world.surface
	_house = world.house
	var ncol := _cols.size()
	ncastes = _cols[0].caste_names.size()
	_home_pos.resize(ncol)
	_speed.resize(ncol * ncastes)
	_sense.resize(ncol * ncastes)
	_wander.resize(ncol * ncastes)
	_life.resize(ncol * ncastes)
	_player_w.resize(ncol)
	for c in ncol:
		var col = _cols[c]
		_home_pos[c] = world.nests[col.nest].surface_pos
		_player_w[c] = player_weight * col.mult("pheromone.player_strength")
		for k in ncastes:
			_speed[c * ncastes + k] = col.c_speed[k]
			_sense[c * ncastes + k] = sense_dist * col.c_sense[k]
			_wander[c * ncastes + k] = col.c_wander[k]
			_life[c * ncastes + k] = col.c_life[k]
	_surface_open = world.surface_open()
	_house_flag = world.flags.get("house", false) and _house != null
	_weather_speed = world.weather.speed_mult
	_blocked = _surf.blocked
	_ground = _surf.ground
	_sw = _surf.w
	_sh = _surf.h
	_sinv = _surf.inv_cell
	var wt: Weather = world.weather
	_hazard_on = wt.heatwave or wt.sprinkler_active or wt.mower_active or wt.surface_temp() < 3.0 or (world.house_ai != null and (world.house_ai.sprays.size() > 0 or world.house_ai.ext_phase == "fog"))
	var env: Dictionary = world.env_cfg
	_air_lethal = float(env.get("air_lethal", 22))
	_air_damage = float(env.get("air_damage", 0.6))
	_flood_level = float(env.get("flood_level", 170))
	_flood_damage = float(env.get("flood_damage", 0.5))


func step(dt: float) -> void:
	tick += 1
	_cache()
	var ncol: int = _cols.size()
	counts.resize(ncol * ncastes)
	counts.fill(0)
	var prev_jobs := job_counts.duplicate()
	job_counts.resize(ncol * NJOBS)
	job_counts.fill(0)
	nurse_power.resize(ncol)
	nurse_power.fill(0.0)
	traffic.resize(ncol)
	traffic.fill(0)
	if prev_jobs.size() != job_counts.size():
		prev_jobs = job_counts.duplicate()
	if tick % 20 == 1 or want.size() != ncol * NJOBS:
		_update_quotas(prev_jobs)
	for g in world.nests:
		g.clear_occupancy()
	rebuild_hash()
	for i in n:
		if state[i] == DEAD:
			continue
		prev[i] = pos[i]
		var ci := caste[i]
		var h := home[i]
		var hc := h * ncastes + ci
		counts[hc] += 1
		job_counts[h * NJOBS + job[i]] += 1
		age[i] += 1.0
		if age[i] > _life[hc]:
			kill(i, "old age")
			continue
		var col = _cols[h]
		var l := layer[i]
		if l == LAYER_SURFACE:
			_step_free(i, dt, col, SPACE_SURFACE, hc)
		elif l == LAYER_NEST:
			_step_nest(i, dt, col)
		else:
			_step_free(i, dt, col, SPACE_HOUSE, hc)
		if state[i] == DEAD:
			continue
		var phase := (i + tick)
		if phase % 10 == 0:
			_hazards(i, dt * 10.0, col)
		if phase % 4 == 0 and (ci == 1 or ci == 4 or state[i] == FIGHT or job[i] == J_RAID or job[i] == J_RALLY or faction[i] != 0):
			_ant_combat(i, dt * 4.0, col)
	for c in ncol:
		var col = _cols[c]
		col.nursing_power += nurse_power[c]
		var arr: PackedInt32Array = col.counts
		for k in ncastes:
			arr[k] = counts[c * ncastes + k]
		col.counts = arr


func _update_quotas(jobs: PackedInt32Array) -> void:
	var ncol: int = world.colonies.size()
	want.resize(ncol * NJOBS)
	want.fill(0)
	for c in ncol:
		var col = world.colonies[c]
		if not col.alive:
			continue
		var g: NestGrid = world.nests[col.nest]
		var pop: int = col.population()
		var larvae := 0
		for b in col.brood:
			if b["stage"] == Colony.STAGE_LARVA:
				larvae += 1
		var base := c * NJOBS
		want[base + J_DIG] = mini(g.marks * 2, int(pop * 0.5) + 1)
		want[base + J_NURSE] = mini(int(ceil(float(larvae) / ants_per_nurse)), int(pop * 0.35) + 1)
		var surface_ok: bool = world.surface_open() and world.flags.get("surface", false)
		want[base + J_FORAGE] = int(pop * 0.75) if surface_ok else 0
		want[base + J_PATROL] = int(pop * 0.12) if surface_ok else 0
		want[base + J_TRADE] = world.trade_quota(c)
		want[base + J_RALLY] = world.rally_quota(c, pop)


# ---------------------------------------------------------------- nest movement

func _step_nest(i: int, dt: float, col) -> void:
	var g: NestGrid = world.nests[inside[i]]
	var c := g.cell_at(pos[i])
	if c < 0:
		pos[i] = g.center(g.entrance_cells[0] if g.entrance_cells.size() > 0 else g.entrance_x)
		return
	if g.solidity[c] != 0:
		var nb := _nearest_open(g, c)
		if nb < 0:
			kill(i, "crushed")
			return
		pos[i] = g.center(nb)
		c = nb
	g.occupy(c)
	var ci := caste[i]
	var h := home[i]
	var jb := job[i]
	var st := state[i]
	# Cheap paths for settled ants (most of a big nest at any moment).
	if jb == J_REST and st == IDLE:
		timer[i] -= dt
		if timer[i] <= 0.0:
			job[i] = J_NONE
		elif (tick + i) % 6 == 0:
			_jitter(i, g, c, col.c_speed[ci] * nest_speed_mult * dt * 1.2)
		return
	if jb == J_NURSE and st == NURSE and (tick + i) % 40 != 0:
		nurse_power[h] += col.c_nurse[ci]
		timer[i] += dt
		if timer[i] > 40.0:
			job[i] = J_NONE
		elif (tick + i) % 6 == 0:
			_jitter(i, g, c, col.c_speed[ci] * nest_speed_mult * dt * 1.5)
		return
	if job[i] == J_QUEEN:
		var qc := g.chamber_of_type("queen")
		if qc >= 0 and g.chamber_id[c] != qc + 1 and col.index == g.owner:
			_nest_move(i, g, c, g.field("ch:%d" % qc), col.c_speed[ci] * nest_speed_mult * dt)
		return
	var spd: float = col.c_speed[ci] * nest_speed_mult * dt
	if g.air[c] < 70:
		spd *= 0.5
	match job[i]:
		J_NONE:
			_decide_nest_job(i, g, col)
		J_DIG:
			var f := g.field("dig")
			if g.marks <= 0 or f[c] >= NestGrid.INF:
				job[i] = J_NONE
				state[i] = IDLE
				return
			if f[c] == 0:
				var mc := g.adjacent_mark(c)
				if mc < 0:
					job[i] = J_NONE
					return
				state[i] = DIG
				if g.dig(mc, col.c_dig[ci] * dt):
					world.on_cell_dug(inside[i], mc)
					carry[i] = ITEM_SPOIL
					carry_amt[i] = 1.0
					job[i] = J_SPOIL
					state[i] = TASK
			else:
				state[i] = TASK
				_nest_move(i, g, c, f, spd)
		J_SPOIL:
			if _nest_go_exit(i, g, c, spd):
				_exit_to_surface(i, g, c)
				g.mound += 1.0
				carry[i] = ITEM_NONE
				carry_amt[i] = 0.0
				job[i] = J_FORAGE if world.surface_open() and world.flags.get("surface", false) and col.c_carry[ci] > 0 and world.rng_ants.randf() < 0.5 else J_NONE
				if job[i] == J_FORAGE:
					state[i] = WANDER
					timer[i] = 0.0
				else:
					_enter_nest(i, inside[i])
		J_STORE:
			var dest := _store_chamber(g, carry[i])
			var arrived := false
			if dest < 0:
				arrived = true
			else:
				var f := g.field("ch:%d" % dest)
				if f[c] == 0 or f[c] >= NestGrid.INF:
					arrived = true
				else:
					_nest_move(i, g, c, f, spd)
			if arrived:
				_deposit_item(i, col, g)
				job[i] = J_NONE
				state[i] = IDLE
		J_NURSE:
			var bc: int = col.best_brood_chamber(g) if (tick + i) % 40 == 0 or target[i] < 0 else target[i]
			target[i] = bc
			if bc < 0:
				job[i] = J_NONE
				return
			var f := g.field("ch:%d" % bc)
			if f[c] == 0:
				state[i] = NURSE
				nurse_power[h] += col.c_nurse[ci]
				_jitter(i, g, c, spd * 0.3)
				timer[i] += dt
				if timer[i] > 40.0:
					job[i] = J_NONE
			elif f[c] >= NestGrid.INF:
				job[i] = J_NONE
			else:
				state[i] = TASK
				_nest_move(i, g, c, f, spd)
		J_REST:
			timer[i] -= dt
			if timer[i] <= 0.0:
				job[i] = J_NONE
				return
			var rc := target[i]
			if rc >= 0 and rc < g.chambers.size():
				var f := g.field("ch:%d" % rc)
				if f[c] > 0 and f[c] < NestGrid.INF:
					_nest_move(i, g, c, f, spd)
					return
			state[i] = IDLE
			_jitter(i, g, c, spd * 0.2)
		J_FORAGE, J_PATROL, J_TRADE, J_RALLY:
			if job[i] != J_RALLY and not world.surface_open():
				job[i] = J_NONE
				return
			if _nest_go_exit(i, g, c, spd):
				_exit_to_surface(i, g, c)
		J_RAID:
			# Enemy ants inside a nest: head for the queen chamber, then home via the exit.
			if carry[i] == ITEM_NONE:
				var qc := g.chamber_of_type("queen")
				if qc < 0:
					job[i] = J_TRADE
					return
				var f := g.field("ch:%d" % qc)
				if f[c] > 0 and f[c] < NestGrid.INF:
					_nest_move(i, g, c, f, spd)
				else:
					var victim = world.colonies[g.owner]
					if victim.brood.size() > 0 and world.rng_ants.randf() < 0.02:
						victim.brood.pop_back()
						carry[i] = 6
						carry_amt[i] = 1.0
					_jitter(i, g, c, spd * 0.5)
			else:
				if _nest_go_exit(i, g, c, spd):
					_exit_to_surface(i, g, c)
					state[i] = CARRY
		J_BROOD:
			job[i] = J_NONE
		_:
			job[i] = J_NONE


func _decide_nest_job(i: int, g: NestGrid, col) -> void:
	var ci := caste[i]
	var h := home[i]
	timer[i] = 0.0
	target[i] = -1
	state[i] = TASK
	if col.index != g.owner and faction[i] != world.colonies[g.owner].faction:
		job[i] = J_RAID
		return
	if col.index != g.owner:
		# Visiting a friendly nest (trade delivery done): go home.
		job[i] = J_TRADE
		return
	if carry[i] == ITEM_SPOIL:
		job[i] = J_SPOIL
		return
	if carry[i] != ITEM_NONE:
		job[i] = J_STORE
		return
	var base: int = h * NJOBS
	var r: float = world.rng_ants.randf()
	if want[base + J_RALLY] > job_counts[base + J_RALLY] and (ci == 1 or ci == 4 or (col.has_unlock("behaviour:army_march") and ci == 0 and r < 0.4)):
		job[i] = J_RALLY
		return
	if want[base + J_DIG] > job_counts[base + J_DIG] and col.c_dig[ci] >= 0.5 and r < 0.9:
		job[i] = J_DIG
		return
	if want[base + J_NURSE] > job_counts[base + J_NURSE] and col.c_nurse[ci] > 0.0 and (ci == 3 or ci == 5 or r < 0.5):
		job[i] = J_NURSE
		return
	if want[base + J_TRADE] > job_counts[base + J_TRADE] and col.c_carry[ci] >= 1.0 and r < 0.5:
		var dest: int = world.trade_target(h)
		var item: int = world.trade_item(h)
		if dest >= 0 and item > 0:
			var got: float = col.take_store(ITEM_NAMES[item], col.c_carry[ci] * 2.0)
			if got > 0.0:
				carry[i] = item
				carry_amt[i] = got
				target[i] = dest
				job[i] = J_TRADE
				return
	if (ci == 1 or ci == 4) and want[base + J_PATROL] > job_counts[base + J_PATROL] and r < 0.6:
		job[i] = J_PATROL
		return
	if ci != 1 and ci != 3 and col.c_carry[ci] > 0.0 or ci == 2:
		if want[base + J_FORAGE] > job_counts[base + J_FORAGE] and r < 0.85:
			job[i] = J_FORAGE
			return
	if ci == 3 and col.brood.size() > 0:
		job[i] = J_NURSE
		return
	job[i] = J_REST
	timer[i] = 8.0 + world.rng_ants.randf() * 20.0
	var options: Array = []
	for t in ["queen", "nursery", "food_store"]:
		options.append_array(g.chambers_of_type(t))
	target[i] = options[world.rng_ants.randi() % options.size()] if options.size() > 0 else -1


func _store_chamber(g: NestGrid, item: int) -> int:
	var name: String = ITEM_NAMES[item]
	var t := "food_store"
	if name == "water":
		t = "water"
	elif name == "leaf":
		t = "fungus"
	elif name == "brood":
		t = "nursery"
	var best := g.chamber_of_type(t)
	if best < 0 or not g.chambers[best]["ok"]:
		best = g.chamber_of_type("food_store")
	if best < 0 or not g.chambers[best]["ok"]:
		best = g.chamber_of_type("queen")
	return best


func _deposit_item(i: int, col, g: NestGrid) -> void:
	var name: String = ITEM_NAMES[carry[i]]
	if name == "brood":
		col.brood.append({"stage": Colony.STAGE_PUPA, "age": 0.0, "caste": "worker", "fed": 4, "protein": 1, "hunger": 0.0, "chamber": col.best_brood_chamber(g), "sick": 0.0, "royal": false})
	elif name != "" and name != "spoil":
		col.add_store(name, carry_amt[i], g)
		Events.sfx.emit("deposit", pos[i], SPACE_NEST0 + inside[i])
	carry[i] = ITEM_NONE
	carry_amt[i] = 0.0


func _nearest_open(g: NestGrid, c: int) -> int:
	for r in range(1, 6):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var x := c % g.w + dx
				var y := c / g.w + dy
				if x >= 0 and y >= 0 and x < g.w and y < g.h and g.solidity[y * g.w + x] == 0:
					return y * g.w + x
	return -1


func _nest_move(i: int, g: NestGrid, c: int, f: PackedInt32Array, spd: float) -> void:
	var nxt := g.downhill(f, c)
	var tgt := g.center(nxt)
	var d := tgt - pos[i]
	var len := d.length()
	if len < 0.001:
		return
	var step := minf(spd, len)
	var np := pos[i] + d / len * step
	if g.passable(np):
		pos[i] = np
		heading[i] = d.angle()


func _jitter(i: int, g: NestGrid, c: int, spd: float) -> void:
	heading[i] += world.rng_ants.randf_range(-1.5, 1.5)
	var np := pos[i] + Vector2(cos(heading[i]), sin(heading[i])) * spd
	if g.passable(np):
		pos[i] = np
	else:
		heading[i] += PI


## Walk up the exit field; true when at the surface row (or house gap).
func _nest_go_exit(i: int, g: NestGrid, c: int, spd: float) -> bool:
	var f := g.field("exit")
	if f[c] >= NestGrid.INF:
		_jitter(i, g, c, spd * 0.3)
		return false
	if f[c] == 0:
		return true
	_nest_move(i, g, c, f, spd)
	return false


func _exit_to_surface(i: int, g: NestGrid, c: int) -> void:
	layer[i] = LAYER_SURFACE
	var off := float(c % g.w - g.entrance_x) * g.cell * 3.0
	pos[i] = g.surface_pos + Vector2(off, world.rng_ants.randf_range(-6, 6))
	prev[i] = pos[i]
	heading[i] = world.rng_ants.randf() * TAU
	timer[i] = 0.0
	if job[i] == J_TRADE and carry[i] == ITEM_NONE:
		state[i] = CARRY  # heading back to its own nest
	elif job[i] == J_TRADE or job[i] == J_RAID:
		state[i] = CARRY
	elif job[i] == J_RALLY:
		state[i] = FOLLOW
	else:
		state[i] = WANDER


func _enter_nest(i: int, nest_idx: int) -> void:
	var g: NestGrid = world.nests[nest_idx]
	layer[i] = LAYER_NEST
	inside[i] = nest_idx
	var c := g.entrance_x
	if g.solidity[c] != 0:
		# Entrance blocked: find any open surface-row cell.
		c = -1
		for x in g.w:
			if g.solidity[x] == 0:
				c = x
				break
		if c < 0:
			layer[i] = LAYER_SURFACE
			heading[i] += PI
			return
	pos[i] = g.center(c)
	prev[i] = pos[i]
	state[i] = TASK
	if carry[i] == ITEM_NONE:
		carry_amt[i] = 0.0
	if carry[i] != ITEM_NONE:
		job[i] = J_STORE if carry[i] != ITEM_SPOIL else J_SPOIL
	elif job[i] == J_RALLY and faction[i] != world.colonies[g.owner].faction:
		job[i] = J_RAID
	else:
		job[i] = J_NONE


# ---------------------------------------------------------------- surface / house

func _step_free(i: int, dt: float, col, space: int, hc: int) -> void:
	var st := state[i]
	if st == FIGHT:
		_step_fight(i, dt, col, space)
		return
	if st == HAUL:
		timer[i] += dt
		return  # moved by World.haul_step
	var ci := caste[i]
	var f := faction[i]
	var ph: PheromoneField = world.pher[space]
	var p := pos[i]
	var spd: float = _speed[hc] * dt
	if space == SPACE_SURFACE:
		var gx := int(p.x * _sinv)
		var gy := int(p.y * _sinv)
		if gx >= 0 and gy >= 0 and gx < _sw and gy < _sh:
			spd *= SurfaceWorld.GROUND_SPEED[_ground[gy * _sw + gx]]
		spd *= _weather_speed
	timer[i] += dt
	var hd := heading[i]
	var phase := tick + i
	var steer := phase & 1 == 0
	var base := f * PheromoneField.PER_FACTION
	var sd: float = _sense[hc]
	match st:
		WANDER, FOLLOW, IDLE, TASK:
			var jb := job[i]
			if st == FOLLOW or jb == J_RALLY:
				var rp: Vector2 = world.rally_point(f)
				if space != SPACE_SURFACE or rp == Vector2.INF or not world.rally_active(f):
					state[i] = CARRY
					return
				hd = lerp_angle(hd, (rp - p).angle(), 3.0 * dt)
				if steer:
					hd += ph.steer(p, hd, sd, sense_angle, base + PheromoneField.PLAYER, -1, 1.0, 0.0) * turn_rate * dt * 2.0
				var en: int = world.enemy_nest_at(p, f, 30.0)
				if en >= 0:
					_enter_nest(i, en)
					return
				if p.distance_to(rp) < 50.0:
					hd += _rng.randf_range(-2.0, 2.0) * dt * 4.0
			elif jb == J_PATROL:
				var to_home := _home_pos[home[i]] - p
				if steer:
					hd += ph.steer(p, hd, sd, sense_angle, base + PheromoneField.ALARM, base + PheromoneField.PLAYER, 3.0, 0.0) * turn_rate * dt * 2.0
				if to_home.length() > 450.0:
					hd = lerp_angle(hd, to_home.angle(), 1.5 * dt)
				if timer[i] > 60.0:
					state[i] = CARRY
			else:
				# Forager / scout outbound.
				var scout: bool = ci == 2
				if steer:
					if scout:
						hd += ph.steer(p, hd, sd, sense_angle, base + PheromoneField.FOOD, base + PheromoneField.EXPLORE, -0.3, alarm_avoid) * turn_rate * dt * 2.0
					else:
						hd += ph.steer(p, hd, sd, sense_angle, base + PheromoneField.FOOD, base + PheromoneField.PLAYER, _player_w[home[i]], alarm_avoid) * turn_rate * dt * 2.0
					# Food underfoot?
					var fid: int = _surf.food_at(space, p.x, p.y)
					if fid > 0 and _surf.foods.has(fid):
						_found_food(i, fid, col, space)
						return
				hd += _rng.randf_range(-1.0, 1.0) * wander_noise * _wander[hc] * dt * 3.0
				if phase % deposit_interval == 0:
					var strength := home_deposit * exp(-timer[i] / trail_fade) * 3.0
					if strength > 0.05:
						ph.deposit(p.x, p.y, base + PheromoneField.HOME, strength * deposit_interval)
					if scout:
						ph.deposit(p.x, p.y, base + PheromoneField.EXPLORE, explore_deposit * deposit_interval)
				if timer[i] > give_up or not _surface_open:
					state[i] = CARRY
				if _house_flag and space == SPACE_SURFACE and phase % 8 == 0:
					var gap: int = world.house_gap_at(p, 30.0)
					if gap >= 0 and _rng.randf() < 0.6:
						_enter_house(i)
						return
		CARRY:
			var food_trail := (carry[i] != ITEM_NONE and carry[i] != ITEM_SPOIL) or carry_amt[i] < 0.0
			if space == SPACE_HOUSE:
				# Follow the house exit flow field back to the gap.
				var hg := _house
				var c := hg.cell_at(p)
				var fe := hg.field("exit")
				if c >= 0 and fe[c] == 0:
					_leave_house(i)
					return
				if c >= 0 and fe[c] < NestGrid.INF:
					var nxt := hg.downhill(fe, c)
					hd = lerp_angle(hd, (hg.center(nxt) - p).angle(), 8.0 * dt)
				elif steer:
					hd += ph.steer(p, hd, sd, sense_angle, base + PheromoneField.HOME, base + PheromoneField.PLAYER, 1.0, alarm_avoid) * turn_rate * dt * 2.0
			else:
				var trade := job[i] == J_TRADE and target[i] >= 0 and carry[i] != ITEM_NONE
				var dest_pos: Vector2 = _home_pos[target[i]] if trade else _home_pos[home[i]]
				var to_home := dest_pos - p
				var dist := to_home.length()
				if dist < 14.0:
					var dest_nest: int = _cols[target[i] if trade else home[i]].nest
					if trade:
						_cols[target[i]].add_store(ITEM_NAMES[carry[i]], carry_amt[i], world.nests[dest_nest])
						carry[i] = ITEM_NONE
						carry_amt[i] = 0.0
						heading[i] += PI
						timer[i] = 0.0
						return
					_enter_nest(i, dest_nest)
					return
				if steer:
					hd += ph.steer(p, hd, sd, sense_angle, base + PheromoneField.HOME, base + PheromoneField.PLAYER, 1.0, alarm_avoid) * turn_rate * dt * 2.0
				hd = lerp_angle(hd, to_home.angle(), homing_weight * dt * (3.0 if dist < 80.0 else 1.0))
				hd += _rng.randf_range(-1.0, 1.0) * wander_noise * 0.15 * dt * 3.0
			if food_trail and phase % deposit_interval == 0:
				var strength := food_deposit * exp(-timer[i] / trail_fade)
				if strength > 0.05:
					ph.deposit(p.x, p.y, base + PheromoneField.FOOD, strength * deposit_interval)
					traffic[home[i]] += 1
		FLEE:
			hd += _rng.randf_range(-0.5, 0.5)
			if timer[i] > 3.0:
				state[i] = WANDER
		_:
			state[i] = WANDER
	# Move with collision.
	var np := p + Vector2(cos(hd), sin(hd)) * spd
	var blocked := false
	if space == SPACE_SURFACE:
		var bx := int(np.x * _sinv)
		var by := int(np.y * _sinv)
		blocked = bx < 0 or by < 0 or bx >= _sw or by >= _sh or _blocked[by * _sw + bx] != 0
	else:
		blocked = not _house.passable(np)
	if blocked:
		hd += (PI * 0.5 + _rng.randf() * PI * 0.5) * (1.0 if (i & 1) == 0 else -1.0)
	else:
		pos[i] = np
	heading[i] = wrapf(hd, -PI, PI)


func _found_food(i: int, fid: int, col, space: int) -> void:
	var surf: SurfaceWorld = world.surface
	var f: Dictionary = surf.foods[fid]
	if not f["found"]:
		f["found"] = true
		world.on_food_found(fid, faction[i])
	var ci := caste[i]
	if f["weight"] > 0.0:
		var hauling: float = world.haul_strength(fid)
		if col.c_carry[ci] <= 0.0 or (hauling + col.c_carry[ci] < f["weight"] and world.rng_ants.randf() < 0.4):
			# Too heavy alone: run home laying a food trail to recruit help.
			state[i] = CARRY
			timer[i] = 0.0
			_scout_recruit(i)
			return
		state[i] = HAUL
		target[i] = fid
		timer[i] = 0.0
		return
	if col.c_carry[ci] <= 0.0:
		# Scouts can't carry: run home laying a food trail.
		state[i] = CARRY
		carry[i] = ITEM_NONE
		timer[i] = 0.0
		var ph: PheromoneField = world.pher[space]
		ph.deposit_spread(pos[i].x, pos[i].y, faction[i] * PheromoneField.PER_FACTION + PheromoneField.FOOD, food_deposit * 6.0)
		_scout_recruit(i)
		return
	var want_amt: float = minf(f["carry"], 1.0) * col.c_carry[ci] * 2.0 * col.mult("forage.harvest")
	var got := surf.take_food(fid, want_amt)
	if got <= 0.0:
		return
	var type: String = f["type"]
	carry[i] = maxi(ITEM_NAMES.find(type), 2)
	carry_amt[i] = got
	state[i] = CARRY
	timer[i] = 0.0
	heading[i] += PI
	Events.sfx.emit("pickup", pos[i], space)


## Scouts returning from food lay strong FOOD on the way home (handled by CARRY with a flag).
func _scout_recruit(i: int) -> void:
	carry[i] = ITEM_NONE
	carry_amt[i] = 0.0
	# Mark as recruiter: carry_amt < 0 means "lay food trail without cargo".
	carry_amt[i] = -1.0


func _enter_house(i: int) -> void:
	var hg: NestGrid = world.house
	if hg == null:
		return
	layer[i] = LAYER_HOUSE
	pos[i] = hg.center(hg.entrance_cells[0]) + Vector2(world.rng_ants.randf_range(0, 10), 0)
	prev[i] = pos[i]
	heading[i] = 0.0
	world.on_reach_house(home[i])


func _leave_house(i: int) -> void:
	layer[i] = LAYER_SURFACE
	var gaps: Array = world.surface.house_gaps
	pos[i] = (gaps[0] if gaps.size() > 0 else world.surface.entrance) + Vector2(world.rng_ants.randf_range(-10, 10), 25)
	prev[i] = pos[i]
	heading[i] = PI * 0.5


func _step_fight(i: int, dt: float, col, space: int) -> void:
	var t := target[i]
	if t <= -2:
		var e := -t - 2
		if not is_alive(e) or space_of(e) != space or pos[e].distance_to(pos[i]) > 10.0:
			state[i] = WANDER if layer[i] != LAYER_NEST else TASK
			target[i] = -1
		return
	# Creature fights are resolved in Creatures (it moves attached ants).
	if t < 0 or not world.creatures.exists(t):
		state[i] = WANDER if layer[i] != LAYER_NEST else TASK
		target[i] = -1


# ---------------------------------------------------------------- ant vs ant

func _ant_combat(i: int, dt: float, col) -> void:
	var hc := hcell[i]
	if hc < 0:
		return
	var j := hash_head[hc]
	var me := faction[i]
	var p := pos[i]
	var sp := space_of(i)
	while j >= 0:
		if j != i and faction[j] != me and state[j] != DEAD and space_of(j) == sp and pos[j].distance_squared_to(p) < 64.0:
			var dmg: float = col.c_attack[caste[i]] * dt
			var other = world.colonies[home[j]]
			if col.has_unlock("behaviour:decapitate") and world.rng_ants.randf() < 0.05 * dt:
				dmg = 999.0
			if col.has_unlock("behaviour:formic_spray"):
				dmg *= 1.3
			dmg *= other.mult("combat.damage_taken")
			hp[j] -= dmg
			if state[i] != FIGHT:
				state[i] = FIGHT
				target[i] = -j - 2
			if state[j] != FIGHT and state[j] != HAUL:
				state[j] = FIGHT
				target[j] = -i - 2
			var ph: PheromoneField = world.pher[sp]
			ph.deposit(p.x, p.y, me * PheromoneField.PER_FACTION + PheromoneField.ALARM, alarm_deposit * 0.5)
			if hp[j] <= 0.0:
				col.kills["ant"] = col.kills.get("ant", 0) + 1
				kill(j, "combat")
				if state[i] == FIGHT:
					state[i] = WANDER if layer[i] != LAYER_NEST else TASK
			return
		j = hash_next[j]


# ---------------------------------------------------------------- hazards

func _hazards(i: int, dt: float, col) -> void:
	var l := layer[i]
	if l == LAYER_NEST:
		var g: NestGrid = world.nests[inside[i]]
		var c := g.cell_at(pos[i])
		if c < 0:
			return
		if g.air[c] < _air_lethal:
			hp[i] -= _air_damage * dt * col.mult("nest.air_use")
		if g.moisture[c] > _flood_level and not col.has_unlock("behaviour:raft"):
			hp[i] -= _flood_damage * dt / col.mult("env.flood_resist")
		if hp[i] <= 0.0:
			kill(i, "suffocated" if g.air[c] < _air_lethal else "drowned")
		return
	if not _hazard_on:
		return
	var dmg: float = world.weather.hazard_damage(pos[i], l, col) * dt
	if l == LAYER_HOUSE and world.house_ai != null:
		dmg += world.house_ai.hazard_damage(pos[i]) * dt
	if l == LAYER_SURFACE and world.weather.mower_kills(pos[i]):
		kill(i, "lawnmower")
		return
	if dmg > 0.0:
		hp[i] -= dmg * col.mult("combat.damage_taken")
		if hp[i] <= 0.0:
			kill(i, world.weather.hazard_name(l))


# ---------------------------------------------------------------- external control
# Other systems must change ant rows through these methods: writing `ants.pos[i]`
# from outside would copy the whole packed array (copy-on-write through a property).

func hold_at(i: int, p: Vector2) -> void:
	pos[i] = p


func damage(i: int, amount: float, cause: String) -> void:
	hp[i] -= amount
	if hp[i] <= 0.0:
		kill(i, cause)


func attach(i: int, creature_id: int) -> void:
	state[i] = FIGHT
	target[i] = creature_id


func detach(i: int, from: Vector2) -> void:
	state[i] = FLEE
	timer[i] = 0.0
	target[i] = -1
	var away := (pos[i] - from).normalized()
	if away == Vector2.ZERO:
		away = Vector2.RIGHT
	pos[i] = pos[i] + away * 18.0
	heading[i] = away.angle()


func release(i: int) -> void:
	state[i] = WANDER if layer[i] != LAYER_NEST else TASK
	target[i] = -1
	timer[i] = 0.0


func release_attached(creature_id: int) -> void:
	for i in n:
		if state[i] == FIGHT and target[i] == creature_id:
			release(i)


func release_haulers(fid: int) -> void:
	for i in n:
		if state[i] == HAUL and target[i] == fid:
			release(i)


func set_haul(i: int, fid: int) -> void:
	state[i] = HAUL
	target[i] = fid
	timer[i] = 0.0


## Give up on a stuck haul and run home laying a recruitment trail.
func recruit(i: int) -> void:
	state[i] = CARRY
	target[i] = -1
	timer[i] = 0.0
	carry[i] = ITEM_NONE
	carry_amt[i] = -1.0


func enter_nest(i: int, nest_idx: int) -> void:
	state[i] = TASK
	target[i] = -1
	carry[i] = ITEM_NONE
	_enter_nest(i, nest_idx)


func leave_house_to(i: int, p: Vector2) -> void:
	layer[i] = LAYER_SURFACE
	pos[i] = p
	prev[i] = p


func rehome(i: int, colony_idx: int) -> void:
	home[i] = colony_idx
	job[i] = J_NONE
	if layer[i] != LAYER_NEST:
		state[i] = CARRY
		carry_amt[i] = 0.0


## Remove without a death (queen relocation).
func despawn(i: int) -> void:
	if state[i] == DEAD:
		return
	state[i] = DEAD
	alive -= 1
	free.append(i)


func nudge_out(i: int) -> void:
	if layer[i] != LAYER_NEST:
		return
	var g: NestGrid = world.nests[inside[i]]
	var c := g.cell_at(pos[i])
	for nb in [c - 1, c + 1, c - g.w, c + g.w]:
		if nb >= 0 and nb < g.w * g.h and g.solidity[nb] == 0 and nb != c:
			pos[i] = g.center(nb)
			return


# ---------------------------------------------------------------- queries

func info(i: int) -> Dictionary:
	if not is_alive(i):
		return {}
	var col = world.colonies[home[i]]
	return {
		"index": i, "caste": col.caste_names[caste[i]], "state": STATE_NAMES[state[i]], "job": JOB_NAMES[job[i]],
		"carry": ITEM_NAMES[carry[i]], "carry_amt": carry_amt[i], "hp": hp[i], "max_hp": col.c_hp[caste[i]],
		"age_days": age[i] / (Clock.ticks_per_hour * 24.0), "faction": faction[i], "colony": col.name,
		"layer": ["Nest", "Surface", "House"][layer[i]], "space": space_of(i),
	}


func nearest_ant(space: int, p: Vector2, r: float) -> int:
	var best := -1
	var bd := r * r
	for j in ants_near(space, p, r, 256):
		var d := pos[j].distance_squared_to(p)
		if d < bd:
			bd = d
			best = j
	return best


## Positions hash for determinism tests.
func state_hash() -> int:
	var h := 17
	for i in n:
		if state[i] == DEAD:
			continue
		h = hash([h, i, snappedf(pos[i].x, 0.001), snappedf(pos[i].y, 0.001), state[i], caste[i], carry[i]])
	return h


func serialize() -> Dictionary:
	return {
		"n": n, "alive": alive, "pos": pos, "prev": prev, "vel": vel, "heading": heading, "layer": layer,
		"caste": caste, "state": state, "job": job, "carry": carry, "carry_amt": carry_amt, "hp": hp,
		"age": age, "timer": timer, "target": target, "faction": faction, "home": home, "inside": inside,
		"free": free, "tick": tick,
	}


func deserialize(d: Dictionary) -> void:
	for k in d.keys():
		set(k, d[k])
	hash_next.resize(pos.size())
	hcell.resize(pos.size())
