## The player's body: a man from the Microsoft Rocketbox library (MIT licence) moved by his motion
## capture, baked by tools/player/bake.gd into assets/player/man.scn.
## Movement is decided here, the way a person moves: speed builds up and dies down, turns carry
## momentum and lean into the curve, and starting, stopping and turning on the spot use the captured
## steps themselves (root motion), so the feet stay where they land. While walking or running the
## gait cycles play at the rate that matches the ground speed, and a foot on the ground is held
## where it landed (leg IK) whatever the blend or the turn does. PlayerCtl says where he wants to go
## and how fast (move() returns how far he went), places him, then calls animate().
class_name Man
extends Node3D

enum { IDLE, START, MOVE, STOP, TURN, CROUCH_IN, CROUCH, CROUCH_OUT }

const CYCLES := ["walk_slow", "walk", "walk_fast", "jog", "run", "sprint"]
const FADE := 0.22
const ANKLE_DOWN := 0.125       # ankle and toe heights (m) below which a foot is flat on the ground
const TOE_DOWN := 0.025

var model: Node3D
var skel: Skeleton3D
var meta: Dictionary
var anims := {}                 # clip -> Animation
var rtrack := {}                # clip -> PackedInt32Array, rotation track per animated bone (-1: rest)
var htrack := {}                # clip -> the hips' position track
var bones := PackedInt32Array() # bones any clip animates
var rest_q: Array[Quaternion] = []
var cyc_speed := PackedFloat32Array()
var cyc_stride := PackedFloat32Array()
var body: Node3D                # leans into turns and speed changes

var state := IDLE
var yaw := 0.0
var speed := 0.0                # forward, m/s
var turn_rate := 0.0            # rad/s
var accel := 0.0
var phase := 0.0                # gait cycle: 0 = left heel strike, ~0.5 = right heel strike
var clip := ""                  # the start, stop, turn or crouch clip playing
var ct := 0.0                   # its time
var extra_turn := 0.0           # rad/s added to a turn clip so he ends up facing the right way
var idle_t := 0.0
var crouch_t := 0.0
var tails: Array = []           # layers fading out after a change: [clip, time, rate, weight, per second]
var lean := Vector2()           # x: sideways into turns, y: forward with acceleration
var step := 0                   # counts heel strikes (footstep sounds)
var real_speed := 0.0           # ground speed after collisions, reported by PlayerCtl
var legs: Array = []            # per leg: [thigh, calf, foot, toe] bone indices
var locks: Array = []           # per leg: [point held (world), weight]
var hold_gap := [0.0, 0.0]      # per leg: how far the clip's foot is from the point held (m)

func _ready() -> void:
	body = Node3D.new()
	body.name = "Lean"
	add_child(body)
	model = load("res://assets/player/man.scn").instantiate()
	body.add_child(model)
	meta = model.get_meta("clips")
	skel = model.get_node("Skeleton3D")
	var ap: AnimationPlayer = model.get_node("AnimationPlayer")
	ap.active = false
	var used := {}
	for c in ap.get_animation_list():
		var an := ap.get_animation(c)
		anims[c] = an
		for t in an.get_track_count():
			if an.track_get_type(t) == Animation.TYPE_ROTATION_3D:
				used[skel.find_bone(str(an.track_get_path(t)).get_slice(":", 1))] = true
	var ids := used.keys()
	ids.sort()
	bones = PackedInt32Array(ids)
	for b in skel.get_bone_count():
		rest_q.append(skel.get_bone_rest(b).basis.get_rotation_quaternion())
	for c in anims:
		var an: Animation = anims[c]
		var tr := PackedInt32Array()
		for b in bones:
			tr.append(an.find_track(NodePath("Skeleton3D:" + skel.get_bone_name(b)), Animation.TYPE_ROTATION_3D))
		rtrack[c] = tr
		htrack[c] = an.find_track(NodePath("Skeleton3D:" + skel.get_bone_name(0)), Animation.TYPE_POSITION_3D)
	for c in CYCLES:
		cyc_speed.append(meta[c].speed)
		cyc_stride.append(meta[c].stride)
	for side in ["L", "R"]:
		var leg := []
		for part in ["Thigh", "Calf", "Foot", "Toe0"]:
			leg.append(skel.find_bone("Bip01 %s %s" % [side, part]))
		legs.append(leg)
		locks.append([Vector3(), 0.0])
	_materials()
	var mi: MeshInstance3D = skel.get_node("Body")
	mi.extra_cull_margin = 2.0
	_apply([["idle", 0.0, 1.0]])

func _materials() -> void:
	var mi: MeshInstance3D = model.get_node("Skeleton3D/Body")
	var dir := "res://assets/player/"
	for i in 2:
		var part := "body" if i == 0 else "head"
		var m := StandardMaterial3D.new()
		m.albedo_texture = load(dir + part + "_color.jpg")
		m.normal_enabled = true
		m.normal_texture = load(dir + part + "_normal.jpg")
		m.roughness_texture = load(dir + part + "_rough.jpg")
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		m.roughness = 1.0
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		mi.set_surface_override_material(i, m)
	var h := StandardMaterial3D.new()
	h.albedo_texture = load(dir + "hair.png")
	h.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	h.alpha_scissor_threshold = 0.35
	h.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
	h.cull_mode = BaseMaterial3D.CULL_DISABLED
	h.roughness = 0.7
	mi.set_surface_override_material(2, h)

func reset(p_yaw: float) -> void:
	yaw = p_yaw
	speed = 0.0
	turn_rate = 0.0
	accel = 0.0
	state = IDLE
	clip = ""
	tails.clear()
	lean = Vector2()
	idle_t = randf() * 5.0
	for L in locks:
		L[1] = 0.0

## The world position of a bone.
func bone_pos(n: String) -> Vector3:
	return skel.global_transform * skel.get_bone_global_pose(skel.find_bone(n)).origin

func is_crouched() -> bool:
	return state in [CROUCH_IN, CROUCH]

# ---------------------------------------------------------------- movement

## One frame: dir is where he should go (world x/z, length 0 = stay), want the speed he should go at,
## look the way to face while standing (NAN: don't care). Returns the step taken (world).
func move(dt: float, dir: Vector2, want: float, crouch: bool, look := NAN) -> Vector3:
	var go := want > 0.05 and dir.length() > 0.01
	var want_yaw := atan2(dir.x, dir.y) if go else yaw
	var d := Vector3()
	var prev_speed := speed
	match state:
		IDLE:
			idle_t += dt
			speed = 0.0
			if crouch:
				_play(CROUCH_IN, "crouch_in", 0.0)
			elif go:
				_start(want_yaw, want)
			elif not is_nan(look) and absf(angle_difference(yaw, look)) > deg_to_rad(100.0):
				var a := angle_difference(yaw, look)
				var c := ("turn_l" if a > 0.0 else "turn_r") + ("180" if absf(a) > deg_to_rad(140.0) else "90")
				_play(TURN, c, a - _clip_turn(c))
		START:
			# keep steering at the direction wanted: what the clip still turns plus a correction
			if go:
				var left := _clip_turn(clip) - _root(clip, ct).z
				extra_turn = angle_difference(yaw + left, want_yaw) / maxf(0.15, _len(clip) - ct)
			d = _root_step(dt)
			if not go and ct < _len(clip) * 0.45:
				_to(IDLE, 0.3)
			elif ct >= _len(clip) - FADE:
				var m: Dictionary = meta[clip]
				speed = m.to_speed
				# the clip carries on under the fade: the cycle joins where the clip will be
				phase = fposmod(m.to_phase - FADE * speed / _stride(speed), 1.0)
				_to(MOVE, FADE)
		MOVE:
			d = _move_cycle(dt, go, want_yaw, want, crouch)
		STOP:
			d = _root_step(dt)
			speed = d.length() / maxf(dt, 1e-4)
			if go and ct < _len(clip) * 0.5:
				phase = _phase_from_stop()
				_to(MOVE, FADE)
			elif go or ct >= _len(clip):
				speed = 0.0
				_to(IDLE, 0.35)
		TURN:
			d = _root_step(dt)
			if go or crouch or ct >= _len(clip):
				_to(IDLE, 0.3 if not go else 0.2)
		CROUCH_IN:
			d = _root_step(dt, 1.35)
			if ct >= _len(clip) - 0.3:
				crouch_t = 0.0
				speed = 0.0
				_to(CROUCH, 0.3)
		CROUCH:
			d = _crouch_move(dt, go, want_yaw, want)
			if not crouch:
				if speed > 0.4:
					_to(MOVE, 0.45)
				else:
					_play(CROUCH_OUT, "crouch_out", 0.0, 0.3)
		CROUCH_OUT:
			d = _root_step(dt, 1.35)
			if crouch:
				_to(CROUCH, 0.35)
			elif ct >= _len(clip) - 0.3 or (go and ct > _len(clip) * 0.5):
				_to(IDLE, 0.3)
	accel = lerpf(accel, (speed - prev_speed) / maxf(dt, 1e-4), 1.0 - exp(-dt / 0.15))
	return d

## Poses him for this frame, once he has been placed where move() took him.
func animate(dt: float) -> void:
	_update_lean(dt)
	_pose(dt)
	_hold_feet(dt)

func _start(want_yaw: float, want: float) -> void:
	var a := angle_difference(yaw, want_yaw)
	var c := ""
	if absf(a) < deg_to_rad(50.0):
		c = "run_start" if want > 3.0 else "walk_start"
	else:
		var deg := absf(rad_to_deg(a))
		c = ("turn_l" if a > 0.0 else "turn_r") + ("60" if deg < 95.0 else "120" if deg < 150.0 else "180") + "_walk"
	_play(START, c, a - _clip_turn(c), 0.2)

func _move_cycle(dt: float, go: bool, want_yaw: float, want: float, crouch: bool) -> Vector3:
	var a := angle_difference(yaw, want_yaw)
	var target := want if go else 0.0
	var braking := go and absf(a) > deg_to_rad(110.0) and speed > 1.6
	if braking:
		target = minf(target, 0.9)
	elif go and absf(a) > deg_to_rad(45.0):
		# a sharp cut: he eases off so he can turn tighter
		target = minf(target, lerpf(target, 1.4, clampf((absf(a) - deg_to_rad(45.0)) / deg_to_rad(65.0), 0.0, 1.0)))
	if not go and speed > 3.3:
		target = 3.0    # a runner needs a few strides before he can stop
	var up := 2.7 if speed < 4.6 else 2.0
	var down := 6.0 if braking else 3.4
	speed = move_toward(speed, target, (up if target > speed else down) * dt)
	# he can't run faster than the ground lets him (walls, cars)
	if real_speed < speed - 0.8 and go:
		speed = maxf(real_speed + 0.8, 0.0)
	var max_rate := lerpf(4.6, 2.3, clampf((speed - 1.2) / 5.0, 0.0, 1.0))
	var want_rate := clampf(a * 5.0, -max_rate, max_rate) if go else 0.0
	turn_rate = lerpf(turn_rate, want_rate, 1.0 - exp(-dt / 0.11))
	yaw += turn_rate * dt
	phase = fposmod(phase + speed / _stride(speed) * dt, 1.0)
	if crouch:
		crouch_t = 0.0
		_to(CROUCH, 0.45)
	elif not go:
		if speed > 2.3 and speed <= 3.3:
			_stop("run_stop")
		elif speed > 1.0 and speed <= 2.3:
			_stop("walk_stop")
		elif speed < 0.25:
			speed = 0.0
			_to(IDLE, 0.4)
	return Vector3(sin(yaw), 0.0, cos(yaw)) * speed * dt

func _crouch_move(dt: float, go: bool, want_yaw: float, want: float) -> Vector3:
	crouch_t += dt
	var target := minf(want, 1.5) if go else 0.0
	speed = move_toward(speed, target, (1.8 if target > speed else 2.6) * dt)
	if real_speed < speed - 0.5 and go:
		speed = maxf(real_speed + 0.5, 0.0)
	var a := angle_difference(yaw, want_yaw)
	var want_rate := clampf(a * 4.0, -3.2, 3.2) if go else 0.0
	turn_rate = lerpf(turn_rate, want_rate, 1.0 - exp(-dt / 0.14))
	yaw += turn_rate * dt
	var stride: float = meta["crouch_walk"].stride if meta.has("crouch_walk") else 0.9
	phase = fposmod(phase + speed / stride * dt, 1.0)
	return Vector3(sin(yaw), 0.0, cos(yaw)) * speed * dt

func _stop(c: String) -> void:
	var entry: PackedFloat32Array = meta[c].entry
	var t := entry[int(phase * entry.size()) % entry.size()]
	_play(STOP, c, 0.0, FADE)
	ct = t

## Where in the gait cycle a stop clip is at its current time (to run on after changing his mind).
func _phase_from_stop() -> float:
	var entry: PackedFloat32Array = meta[clip].entry
	var best := 0
	for i in entry.size():
		if absf(entry[i] - ct) < absf(entry[best] - ct):
			best = i
	return float(best) / entry.size()

func _play(s: int, c: String, extra: float, fade := 0.25) -> void:
	_to(s, fade)
	clip = c
	ct = 0.0
	extra_turn = extra / _len(c)

## Changes state; whatever was showing fades out over the given time.
func _to(s: int, fade: float) -> void:
	for L in _layers():
		var rate := 1.0
		if L[0] in CYCLES or L[0] == "crouch_walk":
			rate = speed / _stride(speed) if L[0] != "crouch_walk" else speed / float(meta["crouch_walk"].stride)
		tails.append([L[0], L[1], rate, L[2] * (1.0 - _tail_weight()), 1.0 / maxf(fade, 0.01)])
	while tails.size() > 5:
		tails.pop_front()
	state = s

func _tail_weight() -> float:
	var w := 0.0
	for T in tails:
		w += T[3]
	return minf(w, 1.0)

func _len(c: String) -> float:
	return float(meta[c].len)

## The clip's root (travel x, z and turn) at a time.
func _root(c: String, t: float) -> Vector3:
	var r: PackedFloat32Array = meta[c].root
	var n := r.size() / 3 - 1
	var f := clampf(t * 30.0, 0.0, float(n))
	var k := mini(int(f), n - 1)
	var w := f - k
	return Vector3(lerpf(r[k * 3], r[k * 3 + 3], w), lerpf(r[k * 3 + 1], r[k * 3 + 4], w), lerpf(r[k * 3 + 2], r[k * 3 + 5], w))

func _clip_turn(c: String) -> float:
	return _root(c, _len(c)).z

## Advances the playing clip and moves him the way it moves (with any extra turn).
func _root_step(dt: float, rate := 1.0) -> Vector3:
	var t1 := minf(ct + dt * rate, _len(clip))
	var r0 := _root(clip, ct)
	var r1 := _root(clip, t1)
	var dx := r1.x - r0.x
	var dz := r1.y - r0.y
	var a := yaw - r0.z
	yaw += (r1.z - r0.z) + extra_turn * (t1 - ct)
	ct = t1 if t1 < _len(clip) else ct + dt * rate
	return Vector3(dx * cos(a) + dz * sin(a), 0.0, -dx * sin(a) + dz * cos(a))

## Stride length at a ground speed: between two captured gaits, between their strides; beyond the
## slowest and fastest, their own stride, with the steps quicker or slower, so a foot on the ground
## moves back exactly as fast as the body moves on.
func _stride(s: float) -> float:
	var n := cyc_speed.size()
	if s <= cyc_speed[0]:
		return cyc_stride[0]
	for i in n - 1:
		if s <= cyc_speed[i + 1]:
			return lerpf(cyc_stride[i], cyc_stride[i + 1], (s - cyc_speed[i]) / (cyc_speed[i + 1] - cyc_speed[i]))
	return cyc_stride[n - 1]

func _update_lean(dt: float) -> void:
	var side := clampf(-turn_rate * speed * 0.03, -0.22, 0.22) if state == MOVE else 0.0
	var fwd := clampf(accel * 0.02, -0.06, 0.08) if state == MOVE else 0.0
	lean = lean.lerp(Vector2(side, fwd), 1.0 - exp(-dt / 0.12))
	body.rotation = Vector3(lean.y, 0.0, lean.x)

# ---------------------------------------------------------------- pose

## The clips showing in the current state: [clip, time, weight].
func _layers() -> Array:
	match state:
		IDLE:
			return [["idle", fposmod(idle_t, _len("idle")), 1.0]]
		MOVE:
			return _cycle_layers()
		CROUCH:
			var cw := "crouch_walk" if anims.has("crouch_walk") else "walk_slow"
			var w := clampf(speed / 0.35, 0.0, 1.0)
			return [["crouch_idle", fposmod(crouch_t, _len("crouch_idle")), 1.0 - w], [cw, phase, w]]
		_:
			return [[clip, minf(ct, _len(clip)), 1.0]]

func _cycle_layers() -> Array:
	var n := cyc_speed.size()
	var s := speed
	var idle_w := clampf(1.0 - s / 0.5, 0.0, 1.0)
	var L: Array = []
	if s <= cyc_speed[0]:
		L = [[CYCLES[0], phase, 1.0]]
	elif s >= cyc_speed[n - 1]:
		L = [[CYCLES[n - 1], phase, 1.0]]
	else:
		for i in n - 1:
			if s <= cyc_speed[i + 1]:
				var w := (s - cyc_speed[i]) / (cyc_speed[i + 1] - cyc_speed[i])
				L = [[CYCLES[i], phase, 1.0 - w], [CYCLES[i + 1], phase, w]]
				break
	if idle_w > 0.0:
		for l in L:
			l[2] *= 1.0 - idle_w
		L.append(["idle", fposmod(idle_t, _len("idle")), idle_w])
	return L

func _pose(dt: float) -> void:
	var tw := _tail_weight()
	var L := _layers()
	for l in L:
		l[2] *= 1.0 - tw
	for T in tails:
		T[1] += T[2] * dt
		var ln := _len(T[0])
		T[1] = fposmod(T[1], ln) if meta[T[0]].kind != "once" else minf(T[1], ln)
		L.append([T[0], T[1], T[3]])
	_apply(L)
	var keep: Array = []
	for T in tails:
		T[3] = maxf(0.0, T[3] - dt * T[4])
		if T[3] > 0.001:
			keep.append(T)
	tails = keep
	# heel strikes, for footsteps
	if state == MOVE or state == CROUCH:
		var s := int(floor(phase * 2.0))
		if s != step % 2:
			step += 1

## A foot flat on the ground stays where it landed: the leg is bent to reach it (two-bone IK) until
## the clip lifts the foot, then eased back to the clip.
func _hold_feet(dt: float) -> void:
	var sg := skel.global_transform
	var inv := sg.affine_inverse()
	var ground := global_position.y
	for i in 2:
		var leg: Array = legs[i]
		var L: Array = locks[i]
		var foot := skel.get_bone_global_pose(leg[2])
		var toe := skel.get_bone_global_pose(leg[3])
		var fw := sg * foot.origin
		var down := fw.y - ground < ANKLE_DOWN and (sg * toe.origin).y - ground < TOE_DOWN
		if down and state != TURN:
			if L[1] <= 0.0:
				L[0] = fw
			L[1] = 1.0
		else:
			L[1] = maxf(0.0, L[1] - dt / 0.12)
		if L[1] <= 0.0:
			hold_gap[i] = 0.0
			continue
		var held: Vector3 = L[0]
		held.y = fw.y
		hold_gap[i] = held.distance_to(fw) if down else 0.0
		if held.distance_to(fw) > 0.3:
			L[1] = 0.0
			continue
		_reach(leg, inv * fw.lerp(held, L[1]), foot.basis)

## Bends a leg so its ankle reaches a point (skeleton space), the knee bending the way it bends now;
## the foot keeps its angle.
func _reach(leg: Array, target: Vector3, foot_basis: Basis) -> void:
	var th := skel.get_bone_global_pose(leg[0])
	var kn := skel.get_bone_global_pose(leg[1])
	var an := skel.get_bone_global_pose(leg[2])
	var h := th.origin
	var l1 := h.distance_to(kn.origin)
	var l2 := kn.origin.distance_to(an.origin)
	var d := clampf(h.distance_to(target), absf(l1 - l2) + 0.01, l1 + l2 - 0.002)
	var u := (target - h).normalized()
	var pole := kn.origin - (h + an.origin) * 0.5
	pole = pole - u * pole.dot(u)
	if pole.length() < 1e-4:
		return
	pole = pole.normalized()
	var along := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
	var knee := h + u * along + pole * sqrt(maxf(l1 * l1 - along * along, 0.0))
	th.basis = Basis(Quaternion((kn.origin - h).normalized(), (knee - h).normalized())) * th.basis
	skel.set_bone_global_pose(leg[0], th)
	kn = skel.get_bone_global_pose(leg[1])
	var ankle := skel.get_bone_global_pose(leg[2]).origin
	kn.basis = Basis(Quaternion((ankle - kn.origin).normalized(), (target - kn.origin).normalized())) * kn.basis
	skel.set_bone_global_pose(leg[1], kn)
	var f := skel.get_bone_global_pose(leg[2])
	f.basis = foot_basis
	skel.set_bone_global_pose(leg[2], f)

func _apply(layers: Array) -> void:
	var tot := 0.0
	for l in layers:
		tot += l[2]
	if tot <= 1e-5:
		return
	for i in bones.size():
		var b := bones[i]
		var acc := Quaternion(0, 0, 0, 0)
		for l in layers:
			var tr: int = rtrack[l[0]][i]
			var q: Quaternion = (anims[l[0]] as Animation).rotation_track_interpolate(tr, l[1]) if tr >= 0 else rest_q[b]
			if acc.dot(q) < 0.0:
				q = -q
			acc += q * (l[2] / tot)
		skel.set_bone_pose_rotation(b, acc.normalized())
	var h := Vector3()
	for l in layers:
		h += (anims[l[0]] as Animation).position_track_interpolate(htrack[l[0]], l[1]) * (l[2] / tot)
	skel.set_bone_pose_position(0, h)
