## The creature: what it sees and hears, how it patrols, investigates, searches and chases, and its
## hunched pose. Ported from the browser version's monsterPerceive / monsterUpdate / animMonsterRig.
class_name Monster
extends RefCounted

var g: Game
var actor: Actor
var jaw: Node3D
var glows: Array[MeshInstance3D] = []
const GLOW := Color(1.0, 0.69, 0.251)

var pos := Vector3()
var yaw := 0.0
var state := "PATROL"
var speed := 0.0
var path: Array[Vector2] = []
var awareness := 0.0
var last_known := Vector3()
var last_seen_t := -99.0
var search_t := 0.0
var phase2 := 0
var pause_t := 0.0
var stuck_t := 0.0
var prog := Vector3()
var hear_cd := 0.0
var cur := 0
var prev := -1
var roar_cd := 0.0
var vocal_t := 8.0
var sees := false
var crossing := false
var repath := 0.0
var attack_t := 0.0
var visible := false
var skip_t := 0.0
var inv := Vector2()

# pose blend state
var ch := 0.0
var at := 0.0
var sy := 0.0
var sx := 0.0
var jw := 0.0
var fs_prev := 0.0

func _init(p_g: Game) -> void:
	g = p_g
	actor = Actor.new("beast")
	actor.walk_speed = 2.4
	actor.run_speed = 6.0
	g.add_child(actor)
	actor.set_pose_fn(_pose)

func setup_model() -> void:
	jaw = actor.find_node3d("jaw")
	var tex: Texture2D = g.world.tex("glow")
	for i in 2:
		var e := actor.find_node3d("eye_glow_%d" % i)
		if e == null:
			continue
		var s := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(0.14, 0.14)
		s.mesh = q
		s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.billboard_keep_scale = true
		m.albedo_texture = tex
		m.disable_fog = true
		m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		s.material_override = m
		e.add_child(s)
		glows.append(s)
	for mi in actor.model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func reset() -> void:
	var cand := []
	for i in g.nodes.size():
		var n: Dictionary = g.nodes[i]
		var d := U.hyp(n.x - g.pl.pos.x, n.z - g.pl.pos.z)
		if d > 95.0 and d < 160.0:
			cand.append(i)
	cur = cand[randi() % cand.size()] if cand.size() else 0
	prev = -1
	pos = Vector3(g.nodes[cur].x, 0.0, g.nodes[cur].z)
	yaw = randf() * TAU
	state = "PATROL"
	path.clear()
	awareness = 0.0
	speed = 0.0
	pause_t = 2.0
	last_seen_t = -99.0
	crossing = false
	roar_cd = 0.0
	vocal_t = 10.0
	attack_t = 0.0

# ---------------------------------------------------------------- movement
func goal(x: float, z: float) -> void:
	path.clear()
	repath = 0.6
	if g.col.path_clear(pos.x, pos.z, x, z, 1.0):
		path.append(Vector2(x, z))
		return
	var a := g.nearest_node(pos.x, pos.z, true)
	var b := g.nearest_node(x, z, true)
	for i in g.bfs(a, b):
		path.append(Vector2(g.nodes[i].x, g.nodes[i].z))
	path.append(Vector2(x, z))

## Walk along the path; true when it has run out.
func step_path(dt: float, spd: float, turn: float) -> bool:
	if path.is_empty():
		speed = lerpf(speed, 0.0, minf(1.0, dt * 3.0))
		return true
	if path.size() > 1:
		skip_t -= dt
		if skip_t <= 0.0:
			skip_t = 0.4
			if g.col.path_clear(pos.x, pos.z, path[1].x, path[1].y, 1.1):
				path.remove_at(0)
	var t := path[0]
	var dx := t.x - pos.x
	var dz := t.y - pos.z
	var d := U.hyp(dx, dz)
	if d < (2.2 if path.size() > 1 else 1.4):
		path.remove_at(0)
		if path.is_empty():
			return true
	var ad := U.ang_diff(yaw, atan2(dx, dz))
	yaw += clampf(ad, -turn * dt, turn * dt)
	var align := maxf(0.0, cos(ad))
	speed = lerpf(speed, spd * (0.25 + 0.75 * align), minf(1.0, dt * 2.2))
	pos.x += sin(yaw) * speed * dt
	pos.z += cos(yaw) * speed * dt
	pos = g.col.collide(pos, 1.35, 0.2, 5.0, true)
	pos.x = clampf(pos.x, -g.bound + 1.0, g.bound - 1.0)
	pos.z = clampf(pos.z, -g.bound + 1.0, g.bound - 1.0)
	stuck_t += dt
	if stuck_t > 1.2:
		var moved := U.hyp(pos.x - prog.x, pos.z - prog.z)
		prog = pos
		stuck_t = 0.0
		if moved < 0.6 and spd > 0.5:
			path.remove_at(0)
			if path.is_empty():
				return true
	return false

func set_state(s: String) -> void:
	state = s
	path.clear()
	pause_t = 0.0
	phase2 = 0

func patrol_next() -> void:
	var nb: Array = g.nodes[cur].n.filter(func(v): return v != prev)
	var list: Array = nb if nb.size() else g.nodes[cur].n
	var next: int = list[randi() % list.size()]
	var bias := 0.0
	if g.phase == "escape":
		bias = 0.5
	elif g.dir.far_t > 55.0:
		bias = 0.65
	elif g.dir.near_t > 40.0:
		bias = -0.6
	if bias != 0.0 and randf() < absf(bias):
		var best := INF
		for v in list:
			var sc := U.hyp(g.nodes[v].x - g.pl.pos.x, g.nodes[v].z - g.pl.pos.z) * (1.0 if bias > 0.0 else -1.0)
			if sc < best:
				best = sc
				next = v
	prev = cur
	cur = next
	path = [Vector2(g.nodes[next].x + U.rnd(-1.5, 1.5), g.nodes[next].z + U.rnd(-1.5, 1.5))]

## A noise at (x,z) draws it over.
func hear(x: float, z: float) -> void:
	if state == "CHASE" or state == "ATTACK":
		return
	if crossing:
		crossing = false
		g.dir.crossing = {}
	inv = Vector2(x, z)
	if state != "INVESTIGATE":
		set_state("INVESTIGATE")
		if randf() < 0.5:
			vocal(0.5)
	goal(x, z)

func start_chase() -> void:
	if state == "CHASE":
		return
	g.buzz(70)
	set_state("CHASE")
	awareness = 1.0
	crossing = false
	g.dir.crossing = {}
	if roar_cd <= 0.0:
		var pp := g.pos_params(pos.x, 3.0, pos.z, 40.0)
		g.sfx.play("roar", maxf(0.35, pp.vol * 1.3), pp.pan, maxf(pp.lp, 1500.0), 1)
		roar_cd = 14.0
	g.sfx.play("stinger", 0.3)

func vocal(v: float) -> void:
	var pp := g.pos_params(pos.x, 3.5, pos.z, 30.0)
	if randf() < 0.5:
		g.sfx.play("clicks", pp.vol * v, pp.pan, pp.lp)
	else:
		g.sfx.play("growl", pp.vol * v * 0.8, pp.pan, pp.lp)

# ---------------------------------------------------------------- senses
func perceive(dt: float) -> void:
	sees = false
	if g.phase != "explore" and g.phase != "escape":
		return
	var P := g.pl
	var dx := P.pos.x - pos.x
	var dz := P.pos.z - pos.z
	var d := U.hyp(dx, dz)
	var esc := g.phase == "escape"
	if P.pos.y < -2.0:
		return
	var facing := absf(U.ang_diff(yaw, atan2(dx, dz)))
	var rng := 24.0
	if P.flash:
		rng = 46.0
	if P.lit:
		rng *= 1.3
	if P.crouch:
		rng *= 0.62
	if esc:
		rng *= 1.12
	var mm := 0.55 if P.move == "still" else 0.6 if P.move == "crouch" else 1.0 if P.move == "walk" else 1.45 if P.move == "run" else 1.9
	var h := 0.7 if P.crouch else 1.3
	var s := not P.hidden and d < rng and (facing < 1.15 or d < 7.0) and g.col.los_clear(pos.x, pos.z, P.pos.x, P.pos.z, h)
	if not s and P.flash and not P.hidden and d < 30.0:
		var bx := sin(P.cam_yaw)
		var bz := cos(P.cam_yaw)
		if (bx * -dx + bz * -dz) / d > 0.82 and g.col.los_clear(pos.x, pos.z, P.pos.x, P.pos.z, 1.5):
			s = true
	if P.hidden and P.compromised and d < 18.0:
		s = true
	if P.hidden and not P.compromised and d < 1.6 and state == "SEARCH":
		s = true
	sees = s
	if s:
		var gain := (1.8 * (1.0 - d / rng) + 0.35) * mm
		if state == "SEARCH" or state == "INVESTIGATE":
			gain *= 1.7
		if crossing and d > 18.0:
			gain *= 0.3
		awareness = minf(1.2, awareness + gain * dt)
		last_known = P.pos
		last_seen_t = g.time
		if awareness >= 1.0:
			start_chase()
		elif awareness > 0.4 and state == "PATROL":
			hear(P.pos.x, P.pos.z)
	elif state != "CHASE":
		awareness = maxf(0.0, awareness - dt * 0.09)
	# hearing
	hear_cd -= dt
	if P.noise > 0.0 and state != "CHASE":
		var r := P.noise * (1.3 if esc else 1.0) * (1.25 - 0.5 * g.wx_i)
		if not g.col.los_clear(pos.x, pos.z, P.pos.x, P.pos.z, 2.0):
			r *= 0.55
		if d < r:
			if d < r * 0.3:
				awareness += 0.7 * dt
			if awareness >= 1.0:
				last_known = P.pos
				last_seen_t = g.time
				start_chase()
			elif hear_cd <= 0.0:
				hear_cd = 1.4
				var e := d * 0.18
				hear(P.pos.x + U.rnd(-e, e), P.pos.z + U.rnd(-e, e))

# ---------------------------------------------------------------- behaviour
func update(dt: float) -> void:
	roar_cd -= dt
	if g.phase == "explore" or g.phase == "escape":
		perceive(dt)
	var P := g.pl
	var esc := g.phase == "escape"
	var dP := U.hyp(P.pos.x - pos.x, P.pos.z - pos.z)
	match state:
		"PATROL":
			var spd := 2.3 if crossing else (3.3 if esc else 2.6)
			if pause_t > 0.0:
				pause_t -= dt
				speed = lerpf(speed, 0.0, dt * 3.0)
			elif path.is_empty() or step_path(dt, spd, 2.0):
				if crossing and path.is_empty():
					crossing = false
					g.dir.crossing = {}
				if path.is_empty():
					if not crossing and randf() < 0.18:
						pause_t = U.rnd(1.5, 4.0)
						if randf() < 0.5:
							vocal(0.4)
					patrol_next()
		"INVESTIGATE":
			var spd := 4.4 if esc else 3.8
			if phase2 == 0:
				if step_path(dt, spd, 2.4):
					phase2 = 1
					pause_t = U.rnd(2.0, 3.2)
			else:
				speed = lerpf(speed, 0.0, dt * 3.0)
				pause_t -= dt
				if pause_t <= 0.0:
					set_state("SEARCH")
					search_t = 12.0 if esc else 9.0
					last_known = Vector3(inv.x, 0.0, inv.y)
					phase2 = 1
		"SEARCH":
			search_t -= dt
			if phase2 == 0:
				if step_path(dt, 4.4, 2.6):
					phase2 = 1
					pause_t = 1.4
			elif pause_t > 0.0:
				pause_t -= dt
				speed = lerpf(speed, 0.0, dt * 3.0)
				if pause_t <= 0.0:
					for k in 12:
						var x := last_known.x + U.rnd(-18.0, 18.0)
						var z := last_known.z + U.rnd(-18.0, 18.0)
						if g.col.walkable(x, z, 1.6):
							goal(x, z)
							break
					if path.is_empty():
						goal(last_known.x + U.rnd(-4.0, 4.0), last_known.z + U.rnd(-4.0, 4.0))
			elif step_path(dt, 3.0, 2.4):
				pause_t = U.rnd(1.2, 2.6)
				if randf() < 0.4:
					vocal(0.5)
			if search_t <= 0.0:
				awareness *= 0.3
				set_state("PATROL")
				cur = g.nearest_node(pos.x, pos.z, true)
				prev = -1
				path = [Vector2(g.nodes[cur].x, g.nodes[cur].z)]
		"CHASE":
			var under := P.pos.y < -2.0
			var tracking := not under and (g.time - last_seen_t < 1.8 or sees)
			if tracking:
				last_known = P.pos
				repath -= dt
				if g.col.path_clear(pos.x, pos.z, P.pos.x, P.pos.z, 0.9):
					path = [Vector2(P.pos.x, P.pos.z)]
				elif repath <= 0.0 or path.is_empty():
					goal(P.pos.x, P.pos.z)
				step_path(dt, 6.5 if esc else 6.2, 3.4)
				if dP > 60.0:
					last_seen_t = -99.0
			else:
				if under:
					last_known = Vector3(16.0, 0.0, 12.5)
				set_state("SEARCH")
				search_t = 22.0 if esc else 17.0
				goal(last_known.x, last_known.z)
				phase2 = 0
				vocal(0.7)
		"ATTACK":
			attack_t += dt
			var want := atan2(P.pos.x - pos.x, P.pos.z - pos.z)
			yaw += U.ang_diff(yaw, want) * minf(1.0, dt * 8.0)
			speed = lerpf(speed, 3.0 if attack_t < 0.4 else 0.0, dt * 5.0)
			if dP > 1.9:
				pos.x += sin(yaw) * speed * dt
				pos.z += cos(yaw) * speed * dt
	_finish(dt)

func _finish(dt: float) -> void:
	var P := g.pl
	if (g.phase == "explore" or g.phase == "escape") and P.pos.y > -1.5:
		var dP := U.hyp(P.pos.x - pos.x, P.pos.z - pos.z)
		if dP < 2.35 and (not P.hidden or P.compromised) and (state in ["CHASE", "SEARCH", "INVESTIGATE"] or dP < 1.9):
			g.lose()
	animate(dt)

# ---------------------------------------------------------------- animation
func animate(dt: float) -> void:
	var chase := state == "CHASE"
	var atk := state == "ATTACK"
	var tt := g.clock
	actor.position = Vector3(pos.x, g.world.ground_at(pos.x, pos.z, 0.0), pos.z)
	actor.rotation.y = yaw
	ch = lerpf(ch, 1.0 if chase else 0.0, minf(1.0, dt * 3.0))
	at = lerpf(at, 1.0 if atk else 0.0, minf(1.0, dt * 6.0))
	var scan := (state == "SEARCH" or state == "INVESTIGATE" or pause_t > 0.0) and speed < 0.8
	sy = lerpf(sy, sin(tt * 0.9) * 0.75 if scan else 0.0, minf(1.0, dt * 2.0))
	sx = lerpf(sx, 0.25 if scan else 0.0, minf(1.0, dt * 2.0))
	jw = lerpf(jw, 0.75 if atk else (0.32 + sin(tt * 9.0) * 0.08 if chase else 0.05 + 0.04 * sin(tt * 0.8)), minf(1.0, dt * 6.0))
	actor.loco(speed)
	# footfalls: when the feet pass each other
	var lf := actor.bone_pos("LeftFoot")
	var rf := actor.bone_pos("RightFoot")
	var fd := (lf.x - rf.x) * sin(yaw) + (lf.z - rf.z) * cos(yaw)
	if speed > 0.3 and signf(fd) != signf(fs_prev) and absf(fd) > 0.05:
		footstep()
		fs_prev = fd
	elif absf(fd) > 0.05:
		fs_prev = fd
	# eye glow: brighter when facing the camera, fading with distance
	var cp := g.cam.global_position
	var dx := cp.x - pos.x
	var dz := cp.z - pos.z
	var d := U.hyp(dx, dz)
	var face := cos(U.ang_diff(yaw + sy, atan2(dx, dz)))
	var op := clampf((face - 0.1) * 1.4, 0.0, 1.0) * clampf(1.0 - (d - 12.0) / 80.0, 0.0, 1.0) * (1.0 if chase else 0.75)
	for s in glows:
		s.visible = op > 0.01
		var c := GLOW.linear_to_srgb()
		c.a = op
		(s.material_override as StandardMaterial3D).albedo_color = c

## The hunched, prowling pose on top of the walk cycle (beastPose in the browser version).
func _pose(_dt: float) -> void:
	var c := ch
	var a := at
	var sk := actor.skel
	var hips := actor.bone("Hips")
	var hp := sk.get_bone_pose_position(hips)
	hp.y *= 0.84 - 0.06 * c
	sk.set_bone_pose_position(hips, hp)
	actor.rotate_bone("Spine", Vector3.RIGHT, 0.55 + 0.2 * c)
	actor.rotate_bone("Spine1", Vector3.RIGHT, 0.4 + 0.1 * c)
	actor.rotate_bone("Spine2", Vector3.RIGHT, 0.35 - 0.3 * a)
	actor.rotate_bone("Neck", Vector3.RIGHT, -1.05 - 0.2 * c + 0.3 * a + sx)
	actor.rotate_bone("Neck", Vector3.UP, sy)
	for side in ["Left", "Right"]:
		var sg := 1.0 if side == "Left" else -1.0
		actor.rotate_bone(side + "UpLeg", Vector3.RIGHT, -0.35 - 0.1 * c)
		actor.rotate_bone(side + "Leg", Vector3.RIGHT, 0.55 + 0.1 * c)
		actor.rotate_bone(side + "Arm", Vector3.BACK, -sg * 0.15)
		actor.rotate_bone(side + "Arm", Vector3.RIGHT, 0.25 * c - a * (1.4 + 0.3 * sin(g.clock * 9.0 + sg)))
		actor.rotate_bone(side + "ForeArm", Vector3.RIGHT, -0.4 - 0.5 * a)
	if jaw:
		jaw.rotation.x = jw

func footstep() -> void:
	var wx := pos.x + sin(yaw) * 0.5
	var wz := pos.z + cos(yaw) * 0.5
	var chase := state == "CHASE"
	var pp := g.pos_params(wx, 0.0, wz, 34.0 if chase else 26.0)
	var v: float = pp.vol * (1.4 if chase else 1.0) * (0.6 if g.phase == "menu" else 1.0)
	if v >= 0.004:
		g.sfx.play("thud", v, pp.pan, pp.lp)
	if pp.d < 16.0 and g.phase != "menu":
		g.pl.shake = maxf(g.pl.shake, (1.0 - pp.d / 16.0) * 0.28)
