## The player: movement, stamina, noise, the trail the child follows, the third-person camera and
## the flashlight. Ported from the browser version's updatePlayer / updateCamera / updateFlash.
class_name PlayerCtl
extends RefCounted

var g: Game
var actor: Actor

var pos := Vector3()
var yaw := 0.0
var vel := Vector3()
var crouch := false
var flash := true
var stamina := 1.0
var exhaust := false
var hidden := false
var compromised := false
var noise := 0.0
var move := "still"
var ph := 0.0
var amt := 0.0
var step_acc := 0.0
var trail: Array[Vector3] = []
var lit := false
var run_amt := 0.0
var cr_a := 0.0
var real_sp := 0.0

# camera
var cam_yaw := 0.0
var cam_pitch := 0.28
var cam_dist := 3.3
var cam_cur := 3.3
var shake := 0.0
var cam_fwd := Vector3.FORWARD

# flashlight
var light: SpotLight3D
var beam: MeshInstance3D
var beam_mat: ShaderMaterial
var lens: MeshInstance3D
var lens_mat: StandardMaterial3D
var aim_dir := Vector3.FORWARD      # flashlight direction, for the arm

func _init(p_g: Game) -> void:
	g = p_g
	actor = Actor.new("player")
	actor.walk_speed = 1.5
	actor.run_speed = 4.6
	g.add_child(actor)
	actor.set_pose_fn(_arm_pose)
	light = SpotLight3D.new()
	light.light_color = Color(1.0, 0xf0 / 255.0, 0xdc / 255.0).linear_to_srgb()
	light.spot_range = 40.0 * 0.91
	light.spot_attenuation = 0.2
	light.spot_angle = rad_to_deg(0.4)
	light.spot_angle_attenuation = 1.7
	light.light_energy = 0.0
	light.shadow_enabled = true
	light.shadow_bias = 0.03
	light.shadow_normal_bias = 1.0
	g.add_child(light)
	beam_mat = ShaderMaterial.new()
	beam_mat.shader = load("res://shaders/beam.gdshader")
	beam = MeshInstance3D.new()
	beam.mesh = _beam_mesh()
	beam.material_override = beam_mat
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.extra_cull_margin = 16.0
	g.add_child(beam)

func setup_model() -> void:
	# the torch in her hand: its lens glows while the light is on
	var torch := actor.find_node3d("torch")
	if torch:
		for mi in torch.find_children("*", "MeshInstance3D", true, false):
			var m := (mi as MeshInstance3D)
			if m.mesh and m.mesh.get_aabb().size.y < 0.01:
				lens = m
		if lens:
			lens_mat = StandardMaterial3D.new()
			lens_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			lens_mat.albedo_color = Color(1.0, 0xf4 / 255.0, 0xe0 / 255.0)
			lens.material_override = lens_mat
	for mi in actor.model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _beam_mesh() -> ArrayMesh:
	# open cone from the lens (z=0) to 16 m ahead (z=-16), radius tan(0.36)*16 at the far end
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 24
	var r := tan(0.36) * 16.0
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		var b0 := Vector3(cos(a0) * r, sin(a0) * r, -16.0)
		var b1 := Vector3(cos(a1) * r, sin(a1) * r, -16.0)
		var n0 := Vector3(cos(a0), sin(a0), tan(0.36)).normalized()
		var n1 := Vector3(cos(a1), sin(a1), tan(0.36)).normalized()
		for v in [[Vector3.ZERO, n0], [b0, n0], [b1, n1]]:
			st.set_normal(v[1])
			st.add_vertex(v[0])
	return st.commit()

func reset(start: Vector3) -> void:
	pos = start
	crouch = false
	hidden = false
	compromised = false
	stamina = 1.0
	exhaust = false
	flash = true
	trail.clear()
	ph = 0.0
	amt = 0.0
	vel = Vector3.ZERO
	cam_yaw = atan2(-start.x, -start.z)
	yaw = cam_yaw
	cam_pitch = 0.22
	cam_cur = cam_dist

func update(dt: float) -> void:
	var inp: Dictionary = g.hud.input
	var jx: float = inp.jx
	var jy: float = inp.jy
	var kx: float = inp.kx
	var ky: float = inp.ky
	if kx != 0.0 or ky != 0.0:
		var l := U.hyp(kx, ky)
		var m := 1.0 if inp.krun else 0.6
		jx = kx / l * m
		jy = ky / l * m
	var mag := minf(1.0, U.hyp(jx, jy))
	if g.phase == "dialog" or g.phase == "caught":
		mag = 0.0
	var want_sprint: bool = (inp.sprint or inp.ksprint) and mag > 0.2 and not crouch
	if hidden:
		if mag > 0.35:
			hidden = false
			compromised = false
		else:
			mag = 0.0
	var can_sprint := want_sprint and not exhaust and stamina > 0.0
	stamina = clampf(stamina + (-dt / 6.0 if can_sprint else dt / 7.0), 0.0, 1.0)
	if stamina <= 0.0:
		exhaust = true
	if exhaust and stamina > 0.35:
		exhaust = false
	var speed := 0.0
	move = "still"
	if mag > 0.08:
		if crouch:
			speed = 1.5 * minf(1.0, mag / 0.6)
			move = "crouch"
		elif can_sprint:
			speed = 7.0
			move = "sprint"
		elif mag > 0.72:
			speed = 4.4
			move = "run"
		else:
			speed = lerpf(0.9, 2.2, minf(1.0, mag / 0.72))
			move = "walk"
	if g.phase == "escape" and g.child.state == "follow" and move == "sprint":
		speed = 6.6
	var fy := sin(cam_yaw)
	var fz := cos(cam_yaw)
	var rx := -cos(cam_yaw)
	var rz := sin(cam_yaw)
	var dx := 0.0
	var dz := 0.0
	if mag > 0.08:
		dx = (fy * jy + rx * jx) / mag
		dz = (fz * jy + rz * jx) / mag
	var acc := 9.0 if speed > vel.length() else 12.0
	vel.x = lerpf(vel.x, dx * speed, minf(1.0, acc * dt))
	vel.z = lerpf(vel.z, dz * speed, minf(1.0, acc * dt))
	var old := pos
	pos.x += vel.x * dt
	pos.z += vel.z * dt
	pos = g.col.collide(pos, 0.33, pos.y + 0.1, pos.y + (1.1 if crouch else 1.75), false)
	pos.x = clampf(pos.x, -g.bound, g.bound)
	pos.z = clampf(pos.z, -g.bound, g.bound)
	var gy := g.world.ground_at(pos.x, pos.z, pos.y)
	pos.y = gy if absf(gy - pos.y) > 1.5 else lerpf(pos.y, gy, minf(1.0, dt * 14.0))
	real_sp = U.hyp(pos.x - old.x, pos.z - old.z) / maxf(dt, 1e-4)
	if speed > 0.1:
		yaw += U.ang_diff(yaw, atan2(dx, dz)) * minf(1.0, dt * 10.0)
	elif flash and not hidden:
		yaw += U.ang_diff(yaw, cam_yaw) * minf(1.0, dt * 4.0)
	# animation
	var stride := 1.9 if move == "sprint" else 1.55 if move == "run" else 0.8 if move == "crouch" else 1.25
	ph += real_sp / stride * PI * dt
	amt = lerpf(amt, clampf(real_sp / 2.2, 0.0, 1.0), minf(1.0, dt * 8.0))
	run_amt = lerpf(run_amt, 1.0 if move == "sprint" else 0.6 if move == "run" else 0.0, minf(1.0, dt * 6.0))
	cr_a = lerpf(cr_a, 1.0 if crouch else 0.0, minf(1.0, dt * 8.0))
	actor.position = pos
	actor.rotation.y = yaw
	actor.loco(real_sp, cr_a)
	# footsteps
	step_acc += real_sp * dt
	if step_acc > stride * 0.5 and real_sp > 0.4:
		step_acc = 0.0
		var wet: bool = g.world.in_interior(pos.x, pos.z) == null and pos.y > -1.0
		var v := 0.16 if move == "sprint" else 0.1 if move == "run" else 0.025 if move == "crouch" else 0.05
		g.sfx.play("step_wet" if wet else "step_dry", v, U.rnd(-0.1, 0.1))
	# noise the monster can hear
	noise = 0.0 if real_sp < 0.3 else 34.0 if move == "sprint" else 19.0 if move == "run" else 2.2 if move == "crouch" else 8.0
	# trail for the child
	if trail.is_empty() or U.hyp(trail[-1].x - pos.x, trail[-1].z - pos.z) > 0.7:
		trail.append(pos)
		if trail.size() > 400:
			trail.remove_at(0)
			g.child.ti = maxi(0, g.child.ti - 1)

## The right arm holds the torch up along the beam unless running (rigAimDir in the browser version).
func _arm_pose(_dt: float) -> void:
	if not flash or hidden:
		return
	var w := clampf(1.0 - run_amt * 1.1, 0.0, 1.0)
	if w <= 0.001:
		return
	var d := aim_dir.rotated(Vector3.UP, -yaw)
	actor.aim_bone("RightArm", Vector3(-0.2, -0.75, 0.55), w)
	actor.aim_bone("RightForeArm", Vector3(0.08, d.y * 0.8 - 0.1, 1.0), w)
	actor.aim_bone("RightHand", d, w)

func update_camera(dt: float) -> void:
	var inp: Dictionary = g.hud.input
	var sens: float = (0.0058 if g.hud.touch else 0.005) * g.settings.sens / 100.0
	cam_yaw -= inp.look_dx * sens
	cam_pitch = clampf(cam_pitch + inp.look_dy * sens * 0.85, -0.5, 1.05)
	inp.look_dx = 0.0
	inp.look_dy = 0.0
	if g.phase == "caught":
		var want := atan2(g.mon.pos.x - pos.x, g.mon.pos.z - pos.z)
		cam_yaw += U.ang_diff(cam_yaw, want) * minf(1.0, dt * 5.0)
		cam_pitch = lerpf(cam_pitch, -0.35, minf(1.0, dt * 3.0))
	var cp := cos(cam_pitch)
	var sp := sin(cam_pitch)
	var f := Vector3(sin(cam_yaw) * cp, -sp, cos(cam_yaw) * cp)
	cam_fwd = f
	var rx := -cos(cam_yaw)
	var rz := sin(cam_yaw)
	var hh := 1.05 if cr_a > 0.5 else 1.55
	var a := Vector3(pos.x, pos.y + hh, pos.z)
	var tgt := Vector3(pos.x + rx * 0.42, pos.y + hh + 0.08, pos.z + rz * 0.42)
	var want := tgt - f * cam_dist
	var t := g.col.ray3(a, want, 0.22)
	var d := maxf(0.35, cam_dist * t - 0.15)
	cam_cur = d if d < cam_cur else lerpf(cam_cur, d, minf(1.0, dt * 3.0))
	var p := tgt - f * cam_cur
	# ceilings
	if pos.y < -2.5:
		p.y = clampf(p.y, -5.7, -1.8)
	else:
		var r = g.world.in_interior(pos.x, pos.z)
		if r != null:
			p.y = minf(p.y, float(r.ceil))
		p.y = maxf(p.y, g.world.ground_at(p.x, p.z, pos.y) + 0.25)
	if shake > 0.0:
		var s := shake * 0.09
		p += Vector3(U.rnd(-s, s), U.rnd(-s, s), U.rnd(-s, s))
		shake = maxf(0.0, shake - dt * 2.2)
	g.cam.position = p
	g.cam.look_at(tgt + f * 10.0)

func update_flash(dt: float, t: float) -> void:
	var on := flash and g.phase in ["explore", "escape", "dialog", "caught"]
	var fx := sin(yaw)
	var fz := cos(yaw)
	var rx := -cos(yaw)
	var rz := sin(yaw)
	var hy := pos.y + (0.85 if cr_a > 0.5 else 1.32)
	var h := Vector3(pos.x + rx * 0.26 + fx * 0.42, hy, pos.z + rz * 0.26 + fz * 0.42)
	var ap := cam_pitch * 0.85 - 0.02
	var dir := Vector3(sin(cam_yaw) * cos(ap), -sin(ap), cos(cam_yaw) * cos(ap))
	var jit := 0.03 if move == "sprint" else 0.015 if move == "run" else 0.004
	var target := h + dir * 20.0 + Vector3(sin(t * 9.0) * jit * 20.0, cos(t * 11.0) * jit * 20.0, 0.0)
	aim_dir = (target - h).normalized()
	var fl := (0.2 if randf() < 0.004 else 1.0) if on else 0.0
	light.position = h
	if not h.is_equal_approx(target):
		light.look_at(target)
		beam.position = h
		beam.look_at(target)
	light.light_energy = lerpf(light.light_energy, (2.4 * 1.11 * fl) if on else 0.0, minf(1.0, dt * 25.0))
	beam.visible = on
	var under: bool = pos.y < -2.0 or g.world.in_interior(pos.x, pos.z) != null
	beam_mat.set_shader_parameter("intensity", (0.55 if under else 1.0) * fl)
	if lens_mat:
		lens_mat.albedo_color = Color(1.0, 0.957, 0.878) if on else Color(0.1, 0.1, 0.1)
