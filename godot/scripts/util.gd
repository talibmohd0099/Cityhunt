## Small helpers shared by the game scripts (same maths as the browser version).
class_name U
extends RefCounted

const DIRS := ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]

## Signed shortest turn from angle a to angle b.
static func ang_diff(a: float, b: float) -> float:
	var d := fmod(b - a, TAU)
	if d > PI:
		d -= TAU
	if d < -PI:
		d += TAU
	return d

static func rnd(a: float, b: float) -> float:
	return a + randf() * (b - a)

## Compass word for a direction on the map (north is -z).
static func dir_word(dx: float, dz: float) -> String:
	var b := fmod(rad_to_deg(atan2(dx, -dz)) + 360.0, 360.0)
	return DIRS[int(round(b / 45.0)) % 8]

static func fmt_t(s: float) -> String:
	return "%d:%02d" % [int(s / 60.0), int(fmod(s, 60.0))]

static func hyp(x: float, z: float) -> float:
	return sqrt(x * x + z * z)

static func load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}

static func save_json(path: String, v: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(v))
