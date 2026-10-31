extends Node
## Fixed 20 Hz simulation tick + calendar (day/night, seasons, years).
## Rendering reads `alpha` to interpolate between the last two ticks.

const TICK_HZ := 20
const DT := 1.0 / TICK_HZ
const MAX_STEPS_PER_FRAME := 10
const SPEEDS := [0.0, 1.0, 2.0, 4.0]

var tick: int = 0
## Ticks before tick 0 (sets the starting day/hour).
var offset_ticks: int = 0
var speed: float = 1.0
var running := false
var alpha := 0.0
var last_step_ms := 0.0
var _acc := 0.0

var ticks_per_hour := 180
var hours_per_day := 24
var days_per_season := 7
var season_names: PackedStringArray = ["spring", "summer", "autumn", "winter"]


func _ready() -> void:
	configure()


func configure() -> void:
	var s := Data.table("seasons")
	ticks_per_hour = int(s.get("ticks_per_hour", 180))
	hours_per_day = int(s.get("hours_per_day", 24))
	days_per_season = int(s.get("days_per_season", 7))
	if s.has("order"):
		season_names = PackedStringArray(s["order"])


## Reset calendar. day is 1-based; season is a name.
func reset(day: int = 1, hour: int = 6, season: String = "spring") -> void:
	tick = 0
	_acc = 0.0
	alpha = 0.0
	var si := maxi(season_names.find(season), 0)
	var d := si * days_per_season + (day - 1)
	offset_ticks = (d * hours_per_day + hour) * ticks_per_hour


func _process(delta: float) -> void:
	if not running or speed <= 0.0:
		return
	_acc += delta * speed
	var steps := 0
	while _acc >= DT and steps < MAX_STEPS_PER_FRAME:
		_acc -= DT
		var t0 := Time.get_ticks_usec()
		advance()
		last_step_ms = (Time.get_ticks_usec() - t0) / 1000.0
		steps += 1
		if not running:
			break
	if steps >= MAX_STEPS_PER_FRAME:
		_acc = 0.0  # fell behind; drop time instead of spiralling
	alpha = clampf(_acc / DT, 0.0, 1.0)


## Advance exactly one simulation tick.
func advance() -> void:
	tick += 1
	var w = Game.world
	if w != null:
		w.step(DT)
	Events.tick.emit(DT)
	var total := tick + offset_ticks
	if total % ticks_per_hour == 0:
		var h := hour_of_day()
		if w != null:
			w.on_hour(h)
		Events.hour_passed.emit(h)
		if h == 0:
			var d := day_index()
			if w != null:
				w.on_day(d)
			Events.day_passed.emit(d)
			if d % days_per_season == 0:
				if w != null:
					w.on_season(season())
				Events.season_changed.emit(season())
				if d % (days_per_season * season_names.size()) == 0:
					Events.year_passed.emit(year())


func total_hours() -> float:
	return float(tick + offset_ticks) / ticks_per_hour


func hour_of_day() -> int:
	return int(total_hours()) % hours_per_day


func hour_f() -> float:
	return fmod(total_hours(), hours_per_day)


func day_index() -> int:
	return int(total_hours()) / hours_per_day


func day_of_season() -> int:
	return day_index() % days_per_season + 1


func season_index() -> int:
	return (day_index() / days_per_season) % season_names.size()


func season() -> String:
	return season_names[season_index()]


func year() -> int:
	return day_index() / (days_per_season * season_names.size()) + 1


func is_night() -> bool:
	var h := hour_of_day()
	return h < 6 or h >= 21


## 0 at midnight, 1 at noon.
func daylight() -> float:
	return 0.5 - 0.5 * cos(hour_f() / hours_per_day * TAU)


func hours_to_ticks(hours: float) -> int:
	return int(hours * ticks_per_hour)


func label() -> String:
	return "Y%d %s day %d  %02d:%02d" % [year(), season().capitalize(), day_of_season(), hour_of_day(), int(fmod(total_hours(), 1.0) * 60)]


func set_speed_index(i: int) -> void:
	speed = SPEEDS[clampi(i, 0, SPEEDS.size() - 1)]


func speed_index() -> int:
	return maxi(SPEEDS.find(speed), 0)
