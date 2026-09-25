## Collision against the city's boxes, ported from the browser version so movement, sight lines and
## camera collision behave the same. Boxes are bucketed in an 8 m grid to keep each query small.
class_name Col
extends RefCounted

const CELL := 8.0
const F_LOS := 1
const F_CAM := 2
const F_MON := 4

var x0 := PackedFloat32Array()
var x1 := PackedFloat32Array()
var y0 := PackedFloat32Array()
var y1 := PackedFloat32Array()
var z0 := PackedFloat32Array()
var z1 := PackedFloat32Array()
var flags := PackedInt32Array()
var grid := {}              # Vector2i -> PackedInt32Array of box indices
var stamp := PackedInt32Array()
var query := 0
var bound := 117.6

func _init(boxes: Array, p_bound: float) -> void:
	bound = p_bound
	for c in boxes:
		add_box(float(c[0]), float(c[1]), float(c[2]), float(c[3]), float(c[4]), float(c[5]), int(c[6]))

func add_box(ax0: float, ax1: float, ay0: float, ay1: float, az0: float, az1: float, f: int) -> int:
	var i := x0.size()
	x0.append(minf(ax0, ax1)); x1.append(maxf(ax0, ax1))
	y0.append(ay0); y1.append(ay1)
	z0.append(minf(az0, az1)); z1.append(maxf(az0, az1))
	flags.append(f)
	stamp.append(0)
	for gx in range(floori(x0[i] / CELL), floori(x1[i] / CELL) + 1):
		for gz in range(floori(z0[i] / CELL), floori(z1[i] / CELL) + 1):
			var k := Vector2i(gx, gz)
			if not grid.has(k):
				grid[k] = PackedInt32Array()
			var arr: PackedInt32Array = grid[k]
			arr.append(i)
			grid[k] = arr
	return i

## Box indices whose grid cells overlap the rectangle, each once.
func near(ax: float, az: float, bx: float, bz: float) -> PackedInt32Array:
	query += 1
	var out := PackedInt32Array()
	for gx in range(floori(minf(ax, bx) / CELL), floori(maxf(ax, bx) / CELL) + 1):
		for gz in range(floori(minf(az, bz) / CELL), floori(maxf(az, bz) / CELL) + 1):
			var arr = grid.get(Vector2i(gx, gz))
			if arr == null:
				continue
			for i in arr:
				if stamp[i] != query:
					stamp[i] = query
					out.append(i)
	return out

## Pushes a standing circle (radius r, from height yb to yt) out of the boxes. Monster-only barriers
## stop only the monster.
func collide(p: Vector3, r: float, yb: float, yt: float, is_mon: bool) -> Vector3:
	var list := near(p.x - r, p.z - r, p.x + r, p.z + r)
	for it in 2:
		for i in list:
			if flags[i] & F_MON and not is_mon:
				continue
			if y1[i] <= yb or y0[i] >= yt:
				continue
			if p.x < x0[i] - r or p.x > x1[i] + r or p.z < z0[i] - r or p.z > z1[i] + r:
				continue
			var cx := clampf(p.x, x0[i], x1[i])
			var cz := clampf(p.z, z0[i], z1[i])
			var dx := p.x - cx
			var dz := p.z - cz
			var d2 := dx * dx + dz * dz
			if d2 >= r * r:
				continue
			if d2 > 1e-8:
				var d := sqrt(d2)
				p.x = cx + dx / d * r
				p.z = cz + dz / d * r
			else:
				var l := p.x - x0[i]
				var rr := x1[i] - p.x
				var t := p.z - z0[i]
				var b := z1[i] - p.z
				var m := minf(minf(l, rr), minf(t, b))
				if m == l: p.x = x0[i] - r
				elif m == rr: p.x = x1[i] + r
				elif m == t: p.z = z0[i] - r
				else: p.z = z1[i] + r
	return p

func _seg_box(ax: float, az: float, dx: float, dz: float, i: int, pad: float) -> float:
	var t0 := 0.0
	var t1 := 1.0
	if absf(dx) < 1e-9:
		if ax < x0[i] - pad or ax > x1[i] + pad:
			return -1.0
	else:
		var a := (x0[i] - pad - ax) / dx
		var b := (x1[i] + pad - ax) / dx
		if a > b:
			var q := a; a = b; b = q
		t0 = maxf(t0, a); t1 = minf(t1, b)
		if t0 > t1:
			return -1.0
	if absf(dz) < 1e-9:
		if az < z0[i] - pad or az > z1[i] + pad:
			return -1.0
	else:
		var a := (z0[i] - pad - az) / dz
		var b := (z1[i] + pad - az) / dz
		if a > b:
			var q := a; a = b; b = q
		t0 = maxf(t0, a); t1 = minf(t1, b)
		if t0 > t1:
			return -1.0
	return t0

## True when nothing that blocks sight stands between the two points at height h.
func los_clear(ax: float, az: float, bx: float, bz: float, h: float) -> bool:
	var dx := bx - ax
	var dz := bz - az
	for i in near(ax, az, bx, bz):
		var f := flags[i]
		if not (f & F_LOS) or (f & F_MON) or y0[i] >= h or y1[i] <= h:
			continue
		if _seg_box(ax, az, dx, dz, i, 0.0) >= 0.0:
			return false
	return true

## True when a body padded by pad can walk straight from a to b.
func path_clear(ax: float, az: float, bx: float, bz: float, pad: float) -> bool:
	var dx := bx - ax
	var dz := bz - az
	for i in near(ax - pad, az - pad, bx + pad, bz + pad):
		if y0[i] > 3.0 or y1[i] < 0.4:
			continue
		if _seg_box(ax, az, dx, dz, i, pad) >= 0.0:
			return false
	return true

## Fraction (0..1) of the way from a to b before the camera would enter a wall.
func ray3(a: Vector3, b: Vector3, pad: float) -> float:
	var best := 1.0
	var d := b - a
	for i in near(minf(a.x, b.x) - pad, minf(a.z, b.z) - pad, maxf(a.x, b.x) + pad, maxf(a.z, b.z) + pad):
		var f := flags[i]
		if not (f & F_CAM) or (f & F_MON):
			continue
		if a.x > x0[i] - pad and a.x < x1[i] + pad and a.z > z0[i] - pad and a.z < z1[i] + pad and a.y > y0[i] and a.y < y1[i]:
			continue
		var t0 := 0.0
		var t1 := best
		var ok := true
		for ax in 3:
			var o: float = a[ax]
			var dd: float = d[ax]
			var lo: float = [x0[i], y0[i], z0[i]][ax] - pad
			var hi: float = [x1[i], y1[i], z1[i]][ax] + pad
			if absf(dd) < 1e-9:
				if o < lo or o > hi:
					ok = false
					break
			else:
				var p := (lo - o) / dd
				var q := (hi - o) / dd
				if p > q:
					var s := p; p = q; q = s
				t0 = maxf(t0, p); t1 = minf(t1, q)
				if t0 > t1:
					ok = false
					break
		if ok and t0 < best:
			best = t0
	return best

## Open ground a body of radius r could stand on.
func walkable(x: float, z: float, r: float) -> bool:
	if absf(x) > bound - 2.0 or absf(z) > bound - 2.0:
		return false
	for i in near(x - r, z - r, x + r, z + r):
		if y0[i] > 3.0 or y1[i] < 0.4:
			continue
		if x > x0[i] - r and x < x1[i] + r and z > z0[i] - r and z < z1[i] + r:
			return false
	return true
