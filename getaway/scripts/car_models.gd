## Builds cars from the two models Lost City uses (Mercedes GLS and Koenigsegg Agera). Each car is
## the full model up close and a light stand-in further away. A car faces -z (the way the player
## drives); the models themselves face +x.
class_name CarModels
extends RefCounted

const NEAR := 38.0        # past this the full model gives way to its stand-in
## Where the lights sit in model space (front is +x), and each model's size for collisions.
const SPEC := {
	gls = {head = Vector3(2.4, 0.94, 0.62), tail = Vector3(-2.5, 0.95, 0.72), length = 5.0, width = 1.95},
	agera = {head = Vector3(2.12, 0.68, 0.66), tail = Vector3(-1.9, 0.72, 0.7), length = 4.3, width = 2.0},
}

var parts := {}   # vm -> [[mesh, transform, role, far]]
var mats := {}
var glow_tex: Texture2D

func _init() -> void:
	glow_tex = load("res://assets/textures/glow.png")
	var drops: Texture2D = load("res://assets/pbr/drops_n.png")
	var paint := _shader("car_paint", {drops_tex = drops})
	mats = {
		"paint": paint,
		"glass": _shader("car_paint", {drops_tex = drops, glass = true}),
		"far": _shader("car_paint", {drops_tex = drops, far = true}),
		"chrome": _std(Color(0.75, 0.77, 0.79), 0.22, 1.0),
		"trim": _std(Color(0.043, 0.043, 0.047), 0.6, 0.2),
		"carbon": _std(Color(0.05, 0.05, 0.06), 0.35, 0.5),
		"interior": _std(Color(0.06, 0.06, 0.063), 0.9, 0.0),
		"tire": _std(Color(0.04, 0.04, 0.04), 0.95, 0.0),
		"wheel": _std(Color(0.11, 0.11, 0.12), 0.4, 0.6),
		"lens": _std(Color(0.23, 0.25, 0.28), 0.06, 0.6),
		"head": _glow_mat(Color(1.0, 0.95, 0.85), 3.0),
		"tail": _glow_mat(Color(1.0, 0.05, 0.03), 2.2),
		"sign": _glow_mat(Color(0.95, 0.72, 0.28), 1.4),
	}
	for vm in SPEC:
		parts[vm] = []
		for far in [false, true]:
			var scn: Node3D = load("res://assets/vehicles/%s%s.glb" % [vm, "_far" if far else ""]).instantiate()
			for n in scn.find_children("*", "MeshInstance3D", true, false):
				parts[vm].append([(n as MeshInstance3D).mesh, _node_xform(n, scn), String(n.name), far])
			scn.free()

## A car of model vm ("gls" or "agera") in the given (linear) colour. opts: scale, taxi, halos
## ("head" for oncoming cars, "tail" for cars driving away), shadow.
func make(vm: String, paint: Color, opts := {}) -> Node3D:
	var car := Node3D.new()
	var body := Node3D.new()
	body.name = "Body"
	body.rotation.y = PI / 2.0
	var s: float = opts.get("scale", 1.0)
	body.scale = Vector3.ONE * s
	car.add_child(body)
	for p in parts[vm]:
		var mi := MeshInstance3D.new()
		mi.mesh = p[0]
		mi.transform = p[1]
		var role: String = p[2]
		mi.material_override = mats.get(role, mats.trim)
		if role == "paint" or role == "far":
			mi.set_instance_shader_parameter("paint", Vector3(paint.r, paint.g, paint.b))
		if p[3]:
			mi.visibility_range_begin = NEAR
			mi.visibility_range_begin_margin = 4.0
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			mi.visibility_range_end = NEAR
			mi.visibility_range_end_margin = 4.0
			if not opts.get("shadow", false) or role in ["interior", "lens", "head", "tail"]:
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.add_child(mi)
	var L: Dictionary = SPEC[vm]
	# a soft dark patch under the car, where it blocks the street lights
	var sh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(L.length * 1.25, L.width * 1.5)
	sh.mesh = pm
	sh.material_override = _shadow_mat()
	sh.position.y = 0.03
	sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(sh)
	if opts.get("taxi", false):
		var sign := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.28, 0.2, 0.75)
		sign.mesh = bm
		sign.material_override = mats.sign
		sign.position = Vector3(-0.3, 1.86, 0.0)
		sign.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.add_child(sign)
	var halos: String = opts.get("halos", "")
	if halos != "":
		var head := halos == "head"
		var at: Vector3 = L.head if head else L.tail
		for side in [-1.0, 1.0]:
			var h := halo(Color(1.0, 0.92, 0.8) * 0.8 if head else Color(1.0, 0.1, 0.06), 1.2 if head else 0.7)
			h.position = Vector3(at.x + (0.1 if head else -0.1), at.y, at.z * side)
			body.add_child(h)
			# its reflection on the wet road, stretched towards the camera
			var r := streak(Color(1.0, 0.85, 0.7) * 0.35 if head else Color(1.0, 0.08, 0.05) * 0.45, 0.6, 5.0)
			r.position = Vector3(at.x, 0.03, at.z * side)
			r.rotation.y = PI / 2.0 if head else -PI / 2.0   # headlights come towards the camera, tail lights drive away
			body.add_child(r)
	return car

## A glowing point that always faces the camera.
func halo(c: Color, size: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_texture = glow_tex
	m.albedo_color = c
	m.no_depth_test = false
	m.disable_fog = false
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

## A light's reflection on the wet road: a soft glow lying flat, long along z (towards the camera).
func streak(c: Color, width: float, length: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := PlaneMesh.new()
	q.size = Vector2(width, length)
	q.center_offset = Vector3(0, 0, length * 0.45)
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_texture = glow_tex
	m.albedo_color = c
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

var _shadow: StandardMaterial3D
func _shadow_mat() -> StandardMaterial3D:
	if _shadow == null:
		_shadow = StandardMaterial3D.new()
		_shadow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_shadow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_shadow.albedo_texture = glow_tex
		_shadow.albedo_color = Color(0, 0, 0, 0.85)
		_shadow.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return _shadow

func _shader(name: String, params: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/%s.gdshader" % name)
	for k in params:
		m.set_shader_parameter(k, params[k])
	return m

func _std(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c.linear_to_srgb()
	m.roughness = rough
	m.metallic = metal
	return m

func _glow_mat(c: Color, energy: float) -> StandardMaterial3D:
	var m := _std(c * 0.5, 0.3, 0.0)
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m

func _node_xform(n: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D()
	var cur: Node = n
	while cur and cur != root:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t
