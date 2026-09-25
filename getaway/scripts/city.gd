## The street the car races down: wet road, sidewalks, lamps and buildings, all built from 10 m pieces
## that scroll towards the camera and jump back to the far end once they are behind it (the car
## itself never moves forward, so the numbers stay small however far you drive). Plus the night sky,
## fog, glow and rain.
class_name City
extends Node3D

const CHUNK := 10.0
const CHUNKS := 26
const LOOP := CHUNK * CHUNKS       # 260 m of street
const BACK := 20.0                 # pieces this far behind the car jump to the far end
const ROAD_HALF := 7.0             # four 3.5 m lanes
const WALK := 4.0                  # sidewalk width
const KERB := 0.15
const LAMP_GAP := 26.0
const FOG := Color(0.1, 0.11, 0.15)

var items: Array[Node3D] = []      # road pieces and lamps (they repeat every LOOP metres)
var buildings := [[], []]          # per side (left, right), each a MeshInstance3D
var far_end := [0.0, 0.0]          # z of the far edge of the last building on each side
var rng := RandomNumberGenerator.new()
var models: CarModels
var env: Environment
var rain_mat: ShaderMaterial
var travel := 0.0

func build(p_models: CarModels, seed: int) -> void:
	models = p_models
	rng.seed = seed
	_environment()
	_street()
	_lamps()
	_buildings()
	_rain()

## Moves the street dz metres towards the camera.
func advance(dz: float, speed: float) -> void:
	travel += dz
	for n in items:
		n.position.z += dz
		if n.position.z > BACK:
			n.position.z -= LOOP
	for side in 2:
		far_end[side] += dz
		for b in buildings[side]:
			b.position.z += dz
			var w: float = b.get_meta("w")
			if b.position.z - w * 0.5 > BACK:
				_place(b, side)
	rain_mat.set_shader_parameter("travel", travel)
	rain_mat.set_shader_parameter("slant", speed / 22.0)

# ---------------------------------------------------------------- sky, fog, glow
func _environment() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = FOG.linear_to_srgb()
	var sky := Sky.new()
	var skym := ShaderMaterial.new()
	skym.shader = load("res://shaders/env_sky.gdshader")
	skym.set_shader_parameter("pano", load("res://assets/textures/env.png"))
	sky.sky_material = skym
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.075, 0.08, 0.1).linear_to_srgb()
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.25
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = FOG.linear_to_srgb()
	env.fog_density = 1.0
	env.fog_depth_begin = 15.0
	env.fog_depth_end = 210.0
	env.fog_depth_curve = 1.2
	env.fog_sky_affect = 0.0
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_hdr_threshold = 0.8
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	for lv in 7:
		env.set_glow_level(lv, [0.0, 0.5, 0.6, 0.65, 0.7, 0.0, 0.0][lv])
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	# a faint cold light from the sky, so the car shapes read in the dark
	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.6, 0.7, 1.0)
	moon.light_energy = 0.12
	moon.rotation_degrees = Vector3(-60, 30, 0)
	add_child(moon)

# ---------------------------------------------------------------- road and sidewalks
func _street() -> void:
	var mesh := ArrayMesh.new()
	var h := CHUNK * 0.5
	# road
	_quad(mesh, Vector3(-ROAD_HALF, 0, -h), Vector3(ROAD_HALF, 0, h), Vector3.UP)
	# both sidewalks in one surface
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in [-1.0, 1.0]:
		var x0: float = ROAD_HALF * s
		var x1: float = (ROAD_HALF + WALK) * s
		_quad_st(st, Vector3(min(x0, x1), KERB, -h), Vector3(max(x0, x1), KERB, h), Vector3.UP)
	st.commit(mesh)
	# kerb faces
	var st2 := SurfaceTool.new()
	st2.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in [-1.0, 1.0]:
		var x: float = ROAD_HALF * s
		_wall_st(st2, x, -h, h, KERB, Vector3(-s, 0, 0))
	st2.commit(mesh)
	var road_mat := _shader("ground", {
		albedo_tex = load("res://assets/pbr/asphalt_a.png"), detail_tex = load("res://assets/pbr/asphalt_n.png"),
		tile = 2.5, gain = 0.9, markings = true})
	var walk_mat := _shader("ground", {
		albedo_tex = load("res://assets/pbr/paving_a.png"), detail_tex = load("res://assets/pbr/paving_n.png"),
		tile = 3.0, gain = 0.8, markings = false})
	var kerb_mat := StandardMaterial3D.new()
	kerb_mat.albedo_color = Color(0.3, 0.3, 0.29)
	kerb_mat.roughness = 0.5
	mesh.surface_set_material(0, road_mat)
	mesh.surface_set_material(1, walk_mat)
	mesh.surface_set_material(2, kerb_mat)
	for i in CHUNKS:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position.z = BACK - CHUNK * 0.5 - i * CHUNK
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		items.append(mi)

func _quad(mesh: ArrayMesh, a: Vector3, b: Vector3, n: Vector3) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_quad_st(st, a, b, n)
	st.commit(mesh)

## A flat rectangle from corner a to corner b (same height), facing up.
func _quad_st(st: SurfaceTool, a: Vector3, b: Vector3, n: Vector3) -> void:
	var p := [Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, a.y, b.z), Vector3(a.x, a.y, b.z)]
	for k in [0, 1, 2, 0, 2, 3]:
		st.set_normal(n)
		st.set_uv(Vector2(p[k].x, p[k].z))
		st.add_vertex(p[k])

## The upright face of the kerb along z at x, facing n.
func _wall_st(st: SurfaceTool, x: float, z0: float, z1: float, y: float, n: Vector3) -> void:
	var p := [Vector3(x, 0, z0), Vector3(x, 0, z1), Vector3(x, y, z1), Vector3(x, y, z0)]
	var order := [0, 1, 2, 0, 2, 3] if n.x > 0 else [0, 2, 1, 0, 3, 2]   # clockwise seen from the road
	for k in order:
		st.set_normal(n)
		st.add_vertex(p[k])

# ---------------------------------------------------------------- street lamps
func _lamps() -> void:
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.08, 0.085, 0.09)
	pole_mat.roughness = 0.4
	pole_mat.metallic = 0.6
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(1.0, 0.85, 0.6)
	head_mat.emission_enabled = true
	head_mat.emission = Color(1.0, 0.78, 0.5)
	head_mat.emission_energy_multiplier = 4.0
	var pole := CylinderMesh.new()
	pole.top_radius = 0.07
	pole.bottom_radius = 0.1
	pole.height = 6.6
	pole.radial_segments = 8
	var arm := BoxMesh.new()
	arm.size = Vector3(1.6, 0.08, 0.08)
	var head := BoxMesh.new()
	head.size = Vector3(0.7, 0.12, 0.3)
	var n := int(LOOP / LAMP_GAP)
	for side in [-1.0, 1.0]:
		for i in n:
			var lamp := Node3D.new()
			lamp.position = Vector3((ROAD_HALF + 0.55) * side, 0, BACK - (i + (0.25 if side < 0 else 0.75)) * LAMP_GAP)
			var p := MeshInstance3D.new()
			p.mesh = pole
			p.material_override = pole_mat
			p.position.y = 3.3
			lamp.add_child(p)
			var a := MeshInstance3D.new()
			a.mesh = arm
			a.material_override = pole_mat
			a.position = Vector3(-0.75 * side, 6.55, 0)
			lamp.add_child(a)
			var hd := MeshInstance3D.new()
			hd.mesh = head
			hd.material_override = head_mat
			hd.position = Vector3(-1.4 * side, 6.45, 0)
			lamp.add_child(hd)
			var halo := models.halo(Color(1.0, 0.75, 0.45) * 0.9, 3.2)
			halo.position = hd.position + Vector3(0, -0.1, 0)
			lamp.add_child(halo)
			var light := OmniLight3D.new()
			light.position = hd.position + Vector3(0, -0.3, 0)
			light.light_color = Color(1.0, 0.78, 0.52)
			light.light_energy = 2.2
			light.omni_range = 17.0
			light.omni_attenuation = 1.4
			light.distance_fade_enabled = true
			light.distance_fade_begin = 60.0
			light.distance_fade_length = 20.0
			lamp.add_child(light)
			# its reflection in the wet road
			var r := models.streak(Color(1.0, 0.7, 0.4) * 0.28, 1.4, 12.0)
			r.position = Vector3(-1.4 * side, 0.02, 0)
			lamp.add_child(r)
			add_child(lamp)
			items.append(lamp)

# ---------------------------------------------------------------- buildings
func _buildings() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/building.gdshader")
	for side in 2:
		far_end[side] = BACK + 10.0
		for i in 18:
			var b := MeshInstance3D.new()
			b.material_override = mat
			b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(b)
			buildings[side].append(b)
			_place(b, side)

## Puts a building at the far end of its side of the street with a new size and look.
func _place(b: MeshInstance3D, side: int) -> void:
	var w := rng.randf_range(10.0, 24.0)
	var h := rng.randf_range(11.0, 46.0)
	var d := 14.0
	var bm := BoxMesh.new()
	bm.size = Vector3(d, h, w)
	b.mesh = bm
	b.set_meta("w", w)
	var gap := 0.0 if rng.randf() < 0.7 else rng.randf_range(2.0, 5.0)
	var s := -1.0 if side == 0 else 1.0
	b.position = Vector3((ROAD_HALF + WALK + 0.3 + d * 0.5) * s, h * 0.5, far_end[side] - gap - w * 0.5)
	far_end[side] = b.position.z - w * 0.5
	var tone := rng.randf_range(0.1, 0.3)
	var tint := Color.from_hsv(rng.randf_range(0.02, 0.12), rng.randf_range(0.1, 0.35), 1.0)
	b.set_instance_shader_parameter("wall", Vector3(tint.r, tint.g, tint.b) * tone)
	b.set_instance_shader_parameter("seed", rng.randf() * 100.0)
	b.set_instance_shader_parameter("height", h)
	var sc := Color.from_hsv(rng.randf(), 0.8, 1.0)
	b.set_instance_shader_parameter("sign_col", Vector3(sc.r, sc.g, sc.b))

# ---------------------------------------------------------------- rain
func _rain() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r := RandomNumberGenerator.new()
	r.seed = 7
	for i in 1400:
		var seed := Color(r.randf(), r.randf(), r.randf(), r.randf())
		for c in [Vector2(-1, 0), Vector2(1, 0), Vector2(1, 1), Vector2(-1, 0), Vector2(1, 1), Vector2(-1, 1)]:
			st.set_color(seed)
			st.set_uv(c)
			st.add_vertex(Vector3.ZERO)
	rain_mat = _shader("rain", {amount = 0.6})
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = rain_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.custom_aabb = AABB(Vector3(-1000, -100, -1000), Vector3(2000, 400, 2000))
	add_child(mi)

func _shader(name: String, params: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/%s.gdshader" % name)
	for k in params:
		m.set_shader_parameter(k, params[k])
	return m
