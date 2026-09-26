## The player: what he wants to do (from the joystick, buttons and camera), stamina, noise, the trail
## the child follows, the third-person camera and the flashlight clipped to his chest. How he moves
## (speed building up, turning, stepping, crouching) is his body's business: Man (man.gd).
## Ported from the browser version's updatePlayer / updateCamera / updateFlash.
class_name PlayerCtl
extends RefCounted

var g: Game
var actor: Man

var pos := Vector3()
var yaw := 0.0
var crouch := false
var flash := true
var stamina := 1.0
var exhaust := false
var hidden := false
var compromised := false
var noise := 0.0
var move := "still"
var step_acc := 0.0
var last_step := 0
var trail: Array[Vector3] = []
var lit := false
var cr_a := 0.0
var real_sp := 0.0

# camera
var cam_yaw := 0.0
var cam_pitch := 0.28
var cam_dist := 3.3
var cam_cur := 3.3
var shake := 0.0
var cam_fwd := Vector3.FORWARD
var cam_piv := Vector3()            # the point the camera follows, trailing him slightly
var cam_run := 0.0                  # 0..1 with running speed: the camera drops back a little
var fov_base := 62.0                # set by the game for the screen shape
var cam_t := 0.0

# flashlight, clipped to his jacket
var light: SpotLight3D
var beam: MeshInstance3D
var beam_mat: ShaderMaterial
var torch: Node3D
var lens_mat: StandardMaterial3D

func _init(p_g: Game) -> void:
	g = p_g
	actor = Man.new()
	g.add_child(actor)
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

## A small torch clipped to the left of his chest, pointing ahead; its lens glows while it is on.
func setup_model() -> void:
	var skel := actor.skel
	var chest := skel.find_bone("Bip01 Spine2")
	var att := BoneAttachment3D.new()
	att.bone_name = "Bip01 Spine2"
	skel.add_child(att)
	# where it sits on him standing (character space, facing +z), turned into the chest bone's space
	var at := Transform3D(Basis(), Vector3(0.105, 1.36, 0.115))
	torch = Node3D.new()
	torch.transform = skel.get_bone_global_rest(chest).affine_inverse() * at
	att.add_child(torch)
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.05, 0.05, 0.055)
	metal.metallic = 0.6
	metal.roughness = 0.45
	var body := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.019
	cyl.bottom_radius = 0.016
	cyl.height = 0.11
	cyl.radial_segments = 12
	cyl.rings = 1
	body.mesh = cyl
	body.material_override = metal
	body.rotation.x = PI * 0.5
	torch.add_child(body)
	var clip := MeshInstance3D.new()
	var bx := BoxMesh.new()
	bx.size = Vector3(0.026, 0.006, 0.05)
	clip.mesh = bx
	clip.material_override = metal
	clip.position = Vector3(0.0, 0.022, -0.01)
	torch.add_child(clip)
	var lens := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.017
	disc.bottom_radius = 0.017
	disc.height = 0.002
	disc.radial_segments = 12
	disc.rings = 1
	lens.mesh = disc
	lens.rotation.x = PI * 0.5
	lens.position = Vector3(0.0, 0.0, 0.056)
	lens_mat = StandardMaterial3D.new()
	lens_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lens_mat.albedo_color = Color(1.0, 0xf4 / 255.0, 0xe0 / 255.0)
	lens.material_override = lens_mat
	torch.add_child(lens)
	for mi in actor.model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for mi in torch.find_children("*", "MeshInstance3D", true, false):
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
	step_acc = 0.0
	cam_yaw = atan2(-start.x, -start.z)
	yaw = cam_yaw
	cam_pitch = 0.22
	cam_cur = cam_dist
	cam_piv = start
	cam_run = 0.0
	actor.reset(yaw)
	actor.position = pos
	actor.rotation.y = yaw

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
	# the speed he wants to go at; his body gets there in its own time
	var want := 0.0
	if mag > 0.08:
		if crouch:
			want = 1.5 * minf(1.0, mag / 0.6)
		elif can_sprint:
			want = 6.6 if g.phase == "escape" and g.child.state == "follow" else 7.0
		elif mag > 0.72:
			want = 4.4
		else:
			want = lerpf(0.9, 2.2, minf(1.0, mag / 0.72))
	var dir := Vector2()
	if mag > 0.08:
		var fy := sin(cam_yaw)
		var fz := cos(cam_yaw)
		var rx := -cos(cam_yaw)
		var rz := sin(cam_yaw)
		dir = Vector2(fy * jy + rx * jx, fz * jy + rz * jx) / mag
	# standing with the torch on he turns (stepping round) to face where the camera looks
	var look := cam_yaw if flash and not hidden and g.phase != "caught" else NAN
	var step := actor.move(dt, dir, want, crouch, look)
	var old := pos
	pos.x += step.x
	pos.z += step.z
	pos = g.col.collide(pos, 0.33, pos.y + 0.1, pos.y + (1.1 if crouch else 1.75), false)
	pos.x = clampf(pos.x, -g.bound, g.bound)
	pos.z = clampf(pos.z, -g.bound, g.bound)
	var gy := g.world.ground_at(pos.x, pos.z, pos.y)
	pos.y = gy if absf(gy - pos.y) > 1.5 else lerpf(pos.y, gy, minf(1.0, dt * 14.0))
	real_sp = U.hyp(pos.x - old.x, pos.z - old.z) / maxf(dt, 1e-4)
	actor.real_speed = real_sp
	yaw = actor.yaw
	actor.position = pos
	actor.rotation.y = yaw
	actor.animate(dt)
	# how crouched he is (for the camera and the torch), from how low his hips are
	cr_a = clampf((0.86 - actor.skel.get_bone_pose_position(0).y) / 0.36, 0.0, 1.0)
	move = "still"
	if real_sp > 0.3:
		if actor.is_crouched():
			move = "crouch"
		elif real_sp > 5.0:
			move = "sprint"
		elif real_sp > 2.7:
			move = "run"
		else:
			move = "walk"
	# footsteps: on each heel strike of the gait cycle, or every half stride in a start, stop or turn
	var heel := actor.step != last_step
	last_step = actor.step
	if actor.state != Man.MOVE and actor.state != Man.CROUCH:
		step_acc += real_sp * dt
		heel = step_acc > 0.7 and real_sp > 0.3
	if heel:
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
	cam_t += dt
	var cp := cos(cam_pitch)
	var sp := sin(cam_pitch)
	var f := Vector3(sin(cam_yaw) * cp, -sp, cos(cam_yaw) * cp)
	cam_fwd = f
	var rx := -cos(cam_yaw)
	var rz := sin(cam_yaw)
	# the point followed: over his shoulder, trailing him a little so speed and stops have weight,
	# and eased up and down (kerbs, crouching) instead of jumping
	var hh := lerpf(1.55, 1.05, cr_a)
	var goal := Vector3(pos.x, pos.y + hh, pos.z)
	if cam_piv.distance_to(goal) > 3.0:
		cam_piv = goal
	var k := 1.0 - exp(-dt / 0.06)
	cam_piv.x = lerpf(cam_piv.x, goal.x, k)
	cam_piv.z = lerpf(cam_piv.z, goal.z, k)
	cam_piv.y = lerpf(cam_piv.y, goal.y, 1.0 - exp(-dt / 0.14))
	cam_run = lerpf(cam_run, clampf((real_sp - 2.5) / 4.5, 0.0, 1.0), 1.0 - exp(-dt / 0.7))
	var dist := cam_dist + 0.4 * cam_run
	var a := Vector3(pos.x, cam_piv.y, pos.z)
	var tgt := Vector3(cam_piv.x + rx * 0.42, cam_piv.y + 0.08, cam_piv.z + rz * 0.42)
	var want := tgt - f * dist
	var t := g.col.ray3(a, want, 0.22)
	var d := maxf(0.35, dist * t - 0.15)
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
	# held by someone breathing: a slow drift, a little more when running
	var sw := 0.0025 + 0.006 * cam_run
	g.cam.rotate_object_local(Vector3.RIGHT, (sin(cam_t * 0.83) + 0.5 * sin(cam_t * 1.91)) * sw)
	g.cam.rotate_object_local(Vector3.UP, (sin(cam_t * 0.61 + 1.3) + 0.5 * sin(cam_t * 1.37)) * sw)
	g.cam.fov = fov_base + 5.0 * cam_run

func update_flash(dt: float, t: float) -> void:
	var on := flash and g.phase in ["explore", "escape", "dialog", "caught"]
	# the beam leaves the torch on his chest and points where the camera looks; it bobs with his steps
	var h := torch.global_transform * Vector3(0.0, 0.0, 0.06) if torch else pos + Vector3(0.0, 1.3, 0.0)
	var ap := cam_pitch * 0.85 - 0.02
	var dir := Vector3(sin(cam_yaw) * cos(ap), -sin(ap), cos(cam_yaw) * cos(ap))
	var bob := clampf(real_sp / 7.0, 0.0, 1.0) * 0.025 + 0.002
	var ph := actor.phase * TAU
	var target := h + dir * 20.0 + Vector3(sin(ph) * bob * 20.0, cos(ph * 2.0) * bob * 14.0, 0.0).rotated(Vector3.UP, cam_yaw) + Vector3(sin(t * 0.7), cos(t * 0.53), 0.0) * 0.06
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
