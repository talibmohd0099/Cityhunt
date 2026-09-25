## The lost child: hiding and crying, then following the player's trail, waiting when left behind,
## and cowering when the creature is near. Ported from the browser version's childUpdate.
class_name Child
extends RefCounted

var g: Game
var actor: Actor

var pos := Vector3()
var yaw := 0.0
var state := "hiding"
var ti := 0
var ph := 0.0
var scared_t := 0.0
var sob_t := 5.0
var hidden := true
var wait_said := 0.0
var cr := 0.0

func _init(p_g: Game) -> void:
	g = p_g
	actor = Actor.new("child")
	actor.walk_speed = 0.95
	actor.run_speed = 2.9
	g.add_child(actor)

func setup_model() -> void:
	for mi in actor.model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func reset(loc: Dictionary) -> void:
	pos = Vector3(loc.spot[0], loc.y, loc.spot[1])
	state = "hiding"
	hidden = true
	yaw = atan2(loc.ent[0] - loc.spot[0], loc.ent[1] - loc.spot[1])
	ti = 0
	sob_t = 3.0

func _sob(vol: float, ref: float, lift: float) -> void:
	var pp := g.pos_params(pos.x, pos.y + lift, pos.z, ref)
	var v: float = pp.vol * vol
	if v >= 0.003:
		g.sfx.play("sob", v, pp.pan, pp.lp)

func update(dt: float) -> void:
	var P := g.pl
	var M := g.mon
	var px := P.pos.x
	var pz := P.pos.z
	var dP := U.hyp(pos.x - px, pos.z - pz)
	var dM := U.hyp(pos.x - M.pos.x, pos.z - M.pos.z)
	var same_m := pos.y > -1.5
	var sp := 0.0
	var cower := false
	var crouch := 0.0
	if state == "hiding":
		crouch = 1.0
		cower = true
		sob_t -= dt
		if sob_t <= 0.0:
			sob_t = U.rnd(4.0, 7.0) if dP < 18.0 else U.rnd(9.0, 14.0)
			if dP < 45.0:
				_sob(0.9, 9.0, 0.6)
	elif state == "dialog":
		crouch = 0.4
		yaw += U.ang_diff(yaw, atan2(px - pos.x, pz - pos.z)) * minf(1.0, dt * 4.0)
	else:
		# fear
		if same_m and dM < 11.0 and M.state != "ATTACK":
			if state != "scared":
				state = "scared"
				hidden = true
				g.hud.sub("CHILD", "It’s here…", 1.8)
			scared_t = 3.0
		if state == "scared":
			crouch = 1.0
			cower = true
			if dM > 18.0:
				scared_t -= dt
			if scared_t <= 0.0:
				hidden = false
				state = "follow" if dP < 22.0 else "wait"
				if state == "wait":
					wait_said = 0.0
			sob_t -= dt
			if sob_t <= 0.0:
				sob_t = U.rnd(3.0, 6.0)
				_sob(0.7, 8.0, 0.5)
				if dM < 24.0 and M.state != "CHASE":
					M.hear(pos.x, pos.z)
		elif state == "follow" or state == "wait":
			# distance along the trail
			var tl := P.trail
			var path_d := dP
			if tl.size():
				ti = clampi(ti, 0, tl.size() - 1)
				var acc := U.hyp(tl[ti].x - pos.x, tl[ti].z - pos.z)
				for i in range(ti, tl.size() - 1):
					acc += U.hyp(tl[i + 1].x - tl[i].x, tl[i + 1].z - tl[i].z)
				acc += U.hyp(tl[-1].x - px, tl[-1].z - pz)
				path_d = acc
			if state == "follow" and path_d > 17.0:
				state = "wait"
				wait_said = 0.0
			if state == "wait":
				crouch = 0.3
				wait_said -= dt
				if wait_said <= 0.0:
					wait_said = 7.0
					if dP < 40.0:
						g.hud.sub("CHILD", "Wait! Don’t leave me!", 2.2)
					_sob(0.6, 10.0, 0.6)
				if dP < 5.5:
					state = "follow"
			if state == "follow":
				var direct := dP < 7.0 and absf(P.pos.y - pos.y) < 1.0 and g.col.los_clear(pos.x, pos.z, px, pz, 0.6)
				var tx := px
				var tz := pz
				if direct:
					ti = maxi(0, tl.size() - 1)
				elif tl.size():
					while ti < tl.size() - 1 and U.hyp(tl[ti].x - pos.x, tl[ti].z - pos.z) < 0.6:
						ti += 1
					tx = tl[ti].x
					tz = tl[ti].z
				var stop := 1.7 if direct else 0.0
				var dx := tx - pos.x
				var dz := tz - pos.z
				var d := U.hyp(dx, dz)
				var want := 5.0 if path_d > 5.0 else 3.6 if path_d > 3.0 else 2.2
				if d > stop + 0.05 and path_d > 1.9:
					sp = want
					yaw += U.ang_diff(yaw, atan2(dx, dz)) * minf(1.0, dt * 9.0)
					var mv := minf(d - stop, sp * dt)
					pos.x += dx / d * mv
					pos.z += dz / d * mv
					pos = g.col.collide(pos, 0.22, pos.y + 0.1, pos.y + 1.0, false)
				else:
					yaw += U.ang_diff(yaw, atan2(px - pos.x, pz - pos.z)) * minf(1.0, dt * 3.0)
				if P.hidden and dP < 7.0:
					crouch = 1.0
				if M.state == "CHASE" or dM < 28.0:
					sob_t -= dt
					if sob_t <= 0.0:
						sob_t = U.rnd(5.0, 9.0)
						if randf() < 0.5 and dM < 30.0:
							_sob(0.6, 8.0, 0.5)
							if dM < 18.0 and M.state == "PATROL":
								M.hear(pos.x, pos.z)
	hidden = state == "hiding" or state == "scared" or (P.hidden and dP < 7.0)
	var gy := g.world.ground_at(pos.x, pos.z, pos.y)
	pos.y = gy if absf(gy - pos.y) > 1.5 else lerpf(pos.y, gy, minf(1.0, dt * 14.0))
	cr = lerpf(cr, crouch, minf(1.0, dt * 6.0))
	actor.position = pos
	actor.rotation.y = yaw
	actor.loco(sp, cr, 1.0 if cower else 0.0)
