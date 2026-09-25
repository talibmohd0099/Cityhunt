## The city: meshes and data exported from the browser version (assets/baked), materials,
## lights, fog, sky, rain and the collision boxes the characters move against.
class_name World
extends Node3D

const BAKED := "res://assets/baked/"
const PBR := "res://assets/pbr/"
# night haze: darker and a little warmer than the browser version (street light scattered in the rain),
# and thinner, so the towers stay visible as dark shapes against the clouds
const FOG_BASE := Color(0.064, 0.058, 0.06)   # linear
const FOG_END := 210.0
var fog_base := FOG_BASE
var fog_end := FOG_END
const HEMI_SKY := Color(0.231, 0.278, 0.376)
const HEMI_GROUND := Color(0.051, 0.047, 0.043)
const HEMI := 0.42
const AMBIENT := Color(0.078, 0.079, 0.095)   # (sky + ground) / 2 * 0.42, plus the panorama's share
# three.js lights fade as (1 - d/r)^2; Godot's closest match is 0.725 of the range with attenuation 0.3 and 0.88 of the energy
const RANGE_FIT := Vector3(0.725, 0.3, 0.88)
const POLICE_RED := Color(1, 0.125, 0.125)
const POLICE_BLUE := Color(0.19, 0.31, 1)
const REFL_LAYER := 1 << 19   # camera layer used by the wet-street reflection camera

# collision layers
const L_SOLID := 1        # walls, cars, props: stop the player, child and monster
const L_MONSTER := 2      # barriers only the monster can't pass (the subway canopy)
const L_SIGHT := 4        # blocks line of sight
const L_CAMERA := 8       # keeps the camera out of walls

var data: Dictionary
var col: Array = []          # [x0,x1,y0,y1,z0,z1,flags]
var slabs: Array = []
var interiors: Array = []
var hole: Dictionary
var nodes: Array = []
var lamps: Array = []        # {p:Vector3, c:Color, i, r, kind, flicker, on}
var env: Environment
var sky_mat: ShaderMaterial
var skyline_mat: ShaderMaterial
var moon: DirectionalLight3D
var bolt: DirectionalLight3D
var pool_lights: Array[OmniLight3D] = []
var pool_sel: Array = []
var pool_t := 0.0
var halo_mm: MultiMesh
var halo_base: Array = []
var blink: Array = []
var neons: Array = []
var fb_meshes: Array = []
var rain_mat: ShaderMaterial
var splash_mat: ShaderMaterial
var rain_node: MeshInstance3D
var splash_node: MeshInstance3D
var lit_near := false       # player standing under a working street lamp
var flash := 0.0            # lightning 0..1
var dyn_halo_mm: MultiMesh  # a few moving glows (exit flare, fires)
var hemi_lights: Array[DirectionalLight3D] = []

func _ready() -> void:
	data = JSON.parse_string(FileAccess.get_file_as_string(BAKED + "city.json"))
	col = data.col
	slabs = data.slabs
	interiors = data.interiors
	hole = data.HOLE
	nodes = data.nodes
	for L in data.lamps:
		lamps.append({p = Vector3(L.p[0], L.p[1], L.p[2]), c = Color(L.c[0], L.c[1], L.c[2]).linear_to_srgb(), i = float(L.i), r = float(L.r), kind = String(L.kind), flicker = float(L.flicker), on = true})
	RenderingServer.global_shader_parameter_set("rain_amount", 0.65)
	RenderingServer.global_shader_parameter_set("refl_on", 0.0)
	_environment()
	_city_meshes()
	_trees()
	_halos()
	_ground_fx()
	_neons()
	_vehicles()
	_contact_shadows()
	_colliders()
	_lights()
	_rain()

# ---------------------------------------------------------------- helpers
func tex(name: String) -> Texture2D:
	return load(BAKED + "textures/" + name + ".png")

func shader_mat(path: String, params: Dictionary = {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/" + path + ".gdshader")
	for k in params:
		m.set_shader_parameter(k, params[k])
	return m

static func m4(a: Array) -> Transform3D:
	# three.js column-major 4x4 -> Transform3D
	return Transform3D(Basis(Vector3(a[0], a[1], a[2]), Vector3(a[4], a[5], a[6]), Vector3(a[8], a[9], a[10])), Vector3(a[12], a[13], a[14]))

# ---------------------------------------------------------------- environment
func _environment() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = fog_base.linear_to_srgb()
	# reflections: a picture of the lit city at night
	var sky := Sky.new()
	var skym := shader_mat("env_sky", {pano = tex("env")})
	sky.sky_material = skym
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# fill light: the browser's hemisphere light (blue-grey sky above, dark ground below) plus the faint
	# glow of the city panorama. The part that doesn't depend on direction is the ambient colour; the
	# up/down difference comes from two shadowless lights, one shining down and one negative shining up.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = AMBIENT.linear_to_srgb()
	env.ambient_light_energy = 1.0
	# film-like response: bright lamps and windows roll off softly instead of clipping
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.3
	# depth fog, like the browser's FogExp2 but thinner
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = fog_base.linear_to_srgb()
	env.fog_density = 1.0
	env.fog_depth_begin = 0.0
	env.fog_depth_end = fog_end
	env.fog_depth_curve = 1.0
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.0
	# bloom like the browser's UnrealBloomPass (strength 0.75, radius 0.6, threshold 0.8)
	env.glow_enabled = true
	env.glow_intensity = 0.75
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 0.8
	env.glow_hdr_scale = 0.05
	env.glow_hdr_luminance_cap = 1.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	for lv in 7:
		env.set_glow_level(lv, [0.52, 0.56, 0.6, 0.64, 0.68, 0.0, 0.0][lv])
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	# visible sky dome
	sky_mat = shader_mat("skydome", {hor = fog_base})
	var dome := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 880.0
	sm.height = 1760.0
	sm.radial_segments = 32
	sm.rings = 16
	dome.mesh = sm
	dome.material_override = sky_mat
	dome.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	dome.extra_cull_margin = 16384.0
	dome.name = "SkyDome"
	add_child(dome)

# ---------------------------------------------------------------- city meshes
func _city_meshes() -> void:
	var city: Node3D = load(BAKED + "city.glb").instantiate()
	add_child(city)
	var brick: Texture2D = load("res://assets/brick.jpg")
	var mats := {
		"ground": shader_mat("wet", {albedo_tex = tex("asphalt"), rough_tex = tex("asphalt_rough"), ripple_tex = load("res://assets/ripples.jpg"), wet = 1.0,
			has_detail = true, detail_a = load(PBR + "asphalt_a.png"), detail_n = load(PBR + "asphalt_n.png"), detail_scale = 1.0 / 2.5, detail_gain = 0.6, macro_mean = 0.018, macro_amount = 0.6}),
		"slab": shader_mat("wet", {albedo_tex = tex("concrete"), rough_tex = tex("concrete_rough"), ripple_tex = load("res://assets/ripples.jpg"), wet = 0.55, use_vcolor = true,
			has_detail = true, detail_a = load(PBR + "paving_a.png"), detail_n = load(PBR + "paving_n.png"), detail_scale = 1.0 / 3.0, detail_gain = 0.8, macro_mean = 0.066, macro_amount = 0.35}),
		"tile": shader_mat("wet", {albedo_tex = tex("tiles"), has_rough = false, base_rough = 0.32, ripple_tex = load("res://assets/ripples.jpg"), wet = 0.45}),
		"grass": shader_mat("wet", {albedo_tex = tex("grass"), has_rough = false, base_rough = 0.95, ripple_tex = load("res://assets/ripples.jpg"), wet = 0.0}),
		"mark": shader_mat("vcolor", {rough = 0.3, metal = 0.0, tint = Vector3(0.36, 0.35, 0.33)}),   # worn, wet road paint
		"build": shader_mat("building", {facade = tex("facade"), facade_emi = tex("facade_emi"), brick = brick,
			brick_n = load(PBR + "brick_n.png"), streaks = load(PBR + "wall_streaks.png")}),
		"store": shader_mat("store", {store_tex = tex("store"), store_emi = tex("store_emi")}),
		"props": shader_mat("vcolor", {rough = 0.42, metal = 0.35}),
		"conc": shader_mat("vcolor", {rough = 0.85, metal = 0.0, tint = Vector3(0.3, 0.3, 0.31)}),
		"glow": shader_mat("vglow"),
		"car_paint": shader_mat("car_paint", {use_vcolor = true, drops_tex = load(PBR + "drops_n.png")}),
		"car_trim": shader_mat("vcolor", {rough = 0.8, metal = 0.1}),
		"tower_crown": shader_mat("vglow", {no_fog = true, boost = 1.6}),
		"tower_spire": shader_mat("vglow", {no_fog = true, boost = 0.5}),
	}
	skyline_mat = shader_mat("skyline", {emi = tex("facade_emi"), hor = fog_base})
	mats["skyline"] = skyline_mat
	for n in city.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var nm := String(mi.name)
		var fb := nm.begins_with("fb_")
		var key := nm.trim_prefix("fb_")
		var cut := key.rfind("_")
		if not mats.has(key) and cut > 0 and key.substr(cut + 1).is_valid_int():
			key = key.substr(0, cut)
		if mats.has(key):
			mi.material_override = mats[key]
		else:
			push_warning("no material for city mesh " + nm)
		var cast := key in ["build", "props", "conc", "car_paint", "car_trim"]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 0.0
		if fb:
			fb_meshes.append(mi)
		if key in ["ground", "slab", "tile", "grass", "mark"]:
			mi.layers = 2   # hidden from the reflection camera

func _trees() -> void:
	var tscn: Node3D = load(BAKED + "tree.glb").instantiate()
	var meshes := {}
	for n in tscn.find_children("*", "MeshInstance3D", true, false):
		meshes[String(n.name)] = (n as MeshInstance3D).mesh
	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0x1d / 255.0, 0x16 / 255.0, 0x11 / 255.0).linear_to_srgb()
	trunk_mat.roughness = 0.95
	var core_mat := StandardMaterial3D.new()
	core_mat.albedo_color = Color(0x0e / 255.0, 0x15 / 255.0, 0x0d / 255.0).linear_to_srgb()
	core_mat.roughness = 0.95
	var leaf_mat := shader_mat("leaves", {tex = tex("leaf")})
	for part in [["trunk", trunk_mat], ["leaves", leaf_mat], ["core", core_mat]]:
		var list: Array = data.trees[part[0]]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[part[0]]
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, m4(list[i]))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = part[1]
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if part[0] != "core" else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.name = "Trees_" + part[0]
		add_child(mmi)
	tscn.free()

# ---------------------------------------------------------------- glowing points
func _quad_mm(count: int, custom: bool) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = custom
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	mm.mesh = q
	mm.instance_count = count
	return mm

func _halos() -> void:
	blink = data.blink
	var list: Array = (data.halos as Array).duplicate()
	_car_halos(list)
	halo_mm = _quad_mm(list.size(), true)
	for i in list.size():
		var h: Array = list[i]
		halo_mm.set_instance_transform(i, Transform3D(Basis(), Vector3(h[0], h[1], h[2])))
		var c := Color(h[3], h[4], h[5])
		halo_base.append(c)
		halo_mm.set_instance_color(i, c)
		halo_mm.set_instance_custom_data(i, Color(h[6], 0, 0, 0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = halo_mm
	mmi.material_override = shader_mat("halo")
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-1000, -100, -1000), Vector3(2000, 700, 2000))
	mmi.name = "Halos"
	add_child(mmi)
	# a few glows that move (flares, fires)
	dyn_halo_mm = _quad_mm(8, true)
	for i in 8:
		dyn_halo_mm.set_instance_transform(i, Transform3D(Basis(), Vector3(0, -999, 0)))
		dyn_halo_mm.set_instance_color(i, Color(0, 0, 0))
		dyn_halo_mm.set_instance_custom_data(i, Color(0, 0, 0, 0))
	var dmi := MultiMeshInstance3D.new()
	dmi.multimesh = dyn_halo_mm
	dmi.material_override = mmi.material_override
	dmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	dmi.custom_aabb = mmi.custom_aabb
	add_child(dmi)

func set_dyn_halo(i: int, p: Vector3, c: Color, size: float) -> void:
	dyn_halo_mm.set_instance_transform(i, Transform3D(Basis(), p))
	dyn_halo_mm.set_instance_color(i, c)
	dyn_halo_mm.set_instance_custom_data(i, Color(size, 0, 0, 0))

func _ground_fx() -> void:
	# light pools
	var pools: Array = data.pools
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var pm := PlaneMesh.new()
	pm.size = Vector2(2, 2)
	mm.mesh = pm
	mm.instance_count = pools.size()
	for i in pools.size():
		var p: Array = pools[i]
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(p[2], 1, p[2])), Vector3(p[0], 0.155, p[1])))
		mm.set_instance_color(i, Color(p[3], p[4], p[5]))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = shader_mat("pool", {tex = tex("pool")})
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.name = "LightPools"
	add_child(mmi)
	# wet streaks
	for set in [[data.streaks, 1.1, 10.0], [data.streaksN, 1.6, 9.0]]:
		var list: Array = set[0]
		var sm := MultiMesh.new()
		sm.transform_format = MultiMesh.TRANSFORM_3D
		sm.use_colors = true
		var sp := PlaneMesh.new()
		sp.size = Vector2(set[1], set[2])
		sm.mesh = sp
		sm.instance_count = list.size()
		for i in list.size():
			var s: Array = list[i]
			sm.set_instance_transform(i, Transform3D(Basis(), Vector3(s[0], 0.16, s[1])))
			sm.set_instance_color(i, Color(s[2], s[3], s[4]))
		var smi := MultiMeshInstance3D.new()
		smi.multimesh = sm
		smi.material_override = shader_mat("streak", {tex = tex("streak"), len = set[2]})
		smi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		smi.custom_aabb = AABB(Vector3(-1000, -10, -1000), Vector3(2000, 20, 2000))
		smi.name = "Streaks"
		add_child(smi)
	# light shafts
	var cone := _cone_mesh()
	for cool in [0, 1]:
		var list := (data.cones as Array).filter(func(c): return int(c[5]) == cool)
		if list.is_empty():
			continue
		var cm := MultiMesh.new()
		cm.transform_format = MultiMesh.TRANSFORM_3D
		cm.mesh = cone
		cm.instance_count = list.size()
		for i in list.size():
			var c: Array = list[i]
			cm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(c[4], c[3], c[4])), Vector3(c[0], c[1], c[2])))
		var cmi := MultiMeshInstance3D.new()
		cmi.multimesh = cm
		cmi.material_override = shader_mat("cone", {tint = Vector3(0.72, 0.8, 1.0) if cool == 1 else Vector3(1.0, 0.65, 0.31)})
		cmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		cmi.layers = 2
		cmi.name = "LightCones"
		add_child(cmi)

func _cone_mesh() -> ArrayMesh:
	# open cone, radius 0.15 at the top (y=0) to 1 at the bottom (y=-1); uv.y is 1 at the top
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 14
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		var t0 := Vector3(cos(a0) * 0.15, 0, sin(a0) * 0.15)
		var t1 := Vector3(cos(a1) * 0.15, 0, sin(a1) * 0.15)
		var b0 := Vector3(cos(a0), -1, sin(a0))
		var b1 := Vector3(cos(a1), -1, sin(a1))
		var n0 := Vector3(cos(a0), 0.85, sin(a0)).normalized()
		var n1 := Vector3(cos(a1), 0.85, sin(a1)).normalized()
		for v in [[t0, n0, 1.0], [b0, n0, 0.0], [b1, n1, 0.0], [t0, n0, 1.0], [b1, n1, 0.0], [t1, n1, 1.0]]:
			st.set_normal(v[1])
			st.set_uv(Vector2(0, v[2]))
			st.add_vertex(v[0])
	return st.commit()

func _neons() -> void:
	for n in data.neons:
		var mi := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(n.w, n.h)
		mi.mesh = q
		var mat := shader_mat("neon", {tex = load(BAKED + "textures/" + String(n.tex))})
		if n.double:
			mat.shader = load("res://shaders/neon.gdshader")
		mi.material_override = mat
		mi.position = Vector3(n.pos[0], n.pos[1], n.pos[2])
		mi.rotation.y = n.rotY
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		if n.double:
			var back := mi.duplicate() as MeshInstance3D
			back.rotation.y = n.rotY + PI
			add_child(back)
			neons.append({mats = [mat], lamp = int(n.lamp), mode = String(n.mode), ph = randf() * 10.0})
		else:
			neons.append({mats = [mat], lamp = int(n.lamp), mode = String(n.mode), ph = randf() * 10.0})

# ---------------------------------------------------------------- vehicles (real 3D models)
const CAR_VIS_END := 110.0    # cars further than this fade out (the fog hides them by then)
const CAR_NEAR := 26.0        # past this the full car model gives way to its light stand-in
## Model scale per car type: the Mercedes stands in for sedans, taxis and police cars a little smaller.
static func car_scale(s: Dictionary) -> float:
	return 0.93 if s.vm == "gls" and String(s.get("type", "suv")) in ["sedan", "taxi", "police"] else 1.0

static func car_xform(s: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, float(s.ry)).scaled(Vector3.ONE * car_scale(s)), Vector3(s.x, 0, s.z))

## Where the lights of each model sit, in model space (front is +x).
const CAR_LIGHTS := {
	gls = {head = Vector3(2.4, 0.94, 0.62), tail = Vector3(-2.5, 0.95, 0.72), roof = Vector3(-0.45, 1.76, 0.0), led = Vector3(0.9, 1.12, 0.35)},
	agera = {head = Vector3(2.12, 0.68, 0.66), tail = Vector3(-1.9, 0.72, 0.7), roof = Vector3(-0.2, 1.13, 0.0), led = Vector3(0.6, 0.9, 0.3)},
}

## Glowing points that belong to the model cars: headlights, police bars, alarm lights.
func _car_halos(list: Array) -> void:
	for s in data.vslots:
		if not CAR_LIGHTS.has(s.vm):
			continue
		var L: Dictionary = CAR_LIGHTS[s.vm]
		var t := car_xform(s)
		if s.get("lit", false):
			for sz in [-1.0, 1.0]:
				var p: Vector3 = t * Vector3(L.head.x + 0.05, L.head.y, L.head.z * sz)
				list.append([p.x, p.y, p.z, 1.0, 0.94, 0.82, 1.5])
		if s.get("flash", false):
			for k in 2:
				var p: Vector3 = t * (L.roof + Vector3(0, 0.3, (k * 2 - 1) * 0.35))
				blink.append({i = list.size(), kind = "police", ph = float(s.ph) + k * 0.5, alarm = -1})
				list.append([p.x, p.y, p.z, 1.0, 0.1, 0.1, 2.2] if k == 0 else [p.x, p.y, p.z, 0.16, 0.3, 1.0, 2.2])
		var a := int(s.get("alarm", -1))
		if a >= 0:
			var led: Vector3 = t * L.led
			blink.append({i = list.size(), kind = "led", ph = fmod(float(s.x) * 7.31 + float(s.z) * 3.17, 6.0), alarm = a})   # no randf: keep the game's random sequence as it was
			list.append([led.x, led.y, led.z, 1.0, 0.12, 0.06, 0.3])
			for sz in [-1.0, 1.0]:
				var f: Vector3 = t * Vector3(L.head.x + 0.05, L.head.y, L.head.z * sz)
				blink.append({i = list.size(), kind = "alarm", ph = 0.0, alarm = a})
				list.append([f.x, f.y, f.z, 1.0, 0.69, 0.25, 1.5])
				var r: Vector3 = t * Vector3(L.tail.x - 0.05, L.tail.y, L.tail.z * sz)
				blink.append({i = list.size(), kind = "alarm", ph = 0.0, alarm = a})
				list.append([r.x, r.y, r.z, 1.0, 0.56, 0.12, 1.2])

func _vehicles() -> void:
	var slots: Array = data.vslots
	if slots.is_empty():
		return
	var drops: Texture2D = load("res://assets/pbr/drops_n.png")
	var paint := shader_mat("car_paint", {drops_tex = drops})
	var glass := shader_mat("car_paint", {drops_tex = drops, glass = true})
	var mats := {
		"paint": paint,
		"glass": glass,
		"chrome": _std(Color(0xbf / 255.0, 0xc3 / 255.0, 0xc8 / 255.0), 0.22, 1.0),
		"trim": _std(Color(0x0b / 255.0, 0x0b / 255.0, 0x0c / 255.0), 0.6, 0.2),
		"carbon": _std(Color(0x0d / 255.0, 0x0d / 255.0, 0x0f / 255.0), 0.35, 0.5),
		"interior": _std(Color(0x0f / 255.0, 0x0f / 255.0, 0x10 / 255.0), 0.9, 0.0),
		"tire": _std(Color(0x0a / 255.0, 0x0a / 255.0, 0x0a / 255.0), 0.95, 0.0),
		"wheel": _std(Color(0x1c / 255.0, 0x1c / 255.0, 0x1e / 255.0), 0.4, 0.6),
		"lens": _std(Color(0x3a / 255.0, 0x3f / 255.0, 0x48 / 255.0), 0.06, 0.6, 1.0),
		"head": _std(Color(0x8f / 255.0, 0x8f / 255.0, 0x88 / 255.0), 0.2, 0.3),
		"tail": _std(Color(0x52 / 255.0, 0x04 / 255.0, 0x04 / 255.0), 0.3, 0.0),
	}
	(mats.tail as StandardMaterial3D).emission_enabled = true
	(mats.tail as StandardMaterial3D).emission = Color(0x22 / 255.0, 0, 0)
	# parked with the lights on
	var head_lit := _std(Color(1, 0.95, 0.85), 0.2, 0.0)
	head_lit.emission_enabled = true
	head_lit.emission = Color(1.0, 0.93, 0.8)
	head_lit.emission_energy_multiplier = 3.0
	var tail_lit := _std(Color(0.4, 0.02, 0.02), 0.3, 0.0)
	tail_lit.emission_enabled = true
	tail_lit.emission = Color(1.0, 0.05, 0.03)
	tail_lit.emission_energy_multiplier = 2.0
	# taxi sign and police light bar
	var sign_mat := _std(Color(0.9, 0.72, 0.3), 0.4, 0.0)
	sign_mat.emission_enabled = true
	sign_mat.emission = Color(0.95, 0.72, 0.28)
	sign_mat.emission_energy_multiplier = 1.4
	var bar_mat := shader_mat("beacon")
	mats["far"] = shader_mat("car_paint", {drops_tex = drops, far = true})
	# each car is the full model up close and a light stand-in further away (tools/vehicles/make_far_lod.py)
	var parts := {}   # vm -> [[mesh, local transform, role, far]]
	for vm in CAR_LIGHTS:
		parts[vm] = []
		for far in [false, true]:
			var path := "res://assets/vehicles/%s%s.glb" % [vm, "_far" if far else ""]
			if not ResourceLoader.exists(path):
				return   # keep the stand-in cars
			var scn: Node3D = load(path).instantiate()
			for n in scn.find_children("*", "MeshInstance3D", true, false):
				parts[vm].append([(n as MeshInstance3D).mesh, _node_xform(n, scn), String(n.name), far])
			scn.free()
	var root := Node3D.new()
	root.name = "Cars"
	add_child(root)
	for s in slots:
		if not parts.has(s.vm):
			continue
		var car := Node3D.new()
		car.transform = car_xform(s)
		root.add_child(car)
		var type := String(s.get("type", "suv"))
		var lit: bool = s.get("lit", false)
		var list: Array = parts[s.vm]
		var door := int(s.get("door", 0))
		if door != 0 and DOOR.has(s.vm):
			list = _door_parts(s.vm, parts[s.vm], door)
			if not mats.has("paint_door"):
				for r in ["paint", "glass", "chrome", "trim"]:
					mats[r + "_door"] = _two_sided(mats[r])
		for p in list:
			var mi := MeshInstance3D.new()
			mi.mesh = p[0]
			mi.transform = p[1]
			var role: String = p[2]
			var m: Material = mats.get(role, mats.trim)
			var hinge = p[4] if p.size() > 4 else null
			if hinge != null:
				m = mats[role + "_door"]
			if lit and role == "head":
				m = head_lit
			elif lit and role == "tail":
				m = tail_lit
			mi.material_override = m
			if role == "paint" or role == "far":
				mi.set_instance_shader_parameter("paint", Vector3(s.col[0], s.col[1], s.col[2]))
				mi.set_instance_shader_parameter("livery", 1.0 if type == "police" else 0.0)
			if role in ["interior", "lens", "head", "tail"] or p[3]:
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_car_vis(mi)
			if p[3]:
				mi.visibility_range_begin = CAR_NEAR
				mi.visibility_range_begin_margin = 4.0
				mi.set_meta("far", true)
			else:
				mi.visibility_range_end = CAR_NEAR
				mi.visibility_range_end_margin = 4.0
			if hinge != null:
				# the door swings out around its front edge
				var h := Node3D.new()
				h.position = hinge
				h.rotation.y = door * 1.0
				mi.position -= hinge
				h.add_child(mi)
				car.add_child(h)
			else:
				car.add_child(mi)
		var L: Dictionary = CAR_LIGHTS[s.vm]
		if type == "taxi":
			car.add_child(_car_box(Vector3(0.28, 0.2, 0.75), L.roof + Vector3(0, 0.1, 0), sign_mat))
		elif type == "police":
			car.add_child(_car_box(Vector3(0.32, 0.08, 1.4), L.roof + Vector3(0, 0.04, 0), mats.trim))
			for k in 2:
				var b := _car_box(Vector3(0.26, 0.12, 0.6), L.roof + Vector3(0, 0.14, (k * 2 - 1) * 0.35), bar_mat)
				b.set_instance_shader_parameter("beacon", Vector4(1.0, 0.1, 0.08, float(s.ph)) if k == 0 else Vector4(0.15, 0.3, 1.0, float(s.ph) + 0.5))
				car.add_child(b)
	for m in fb_meshes:
		(m as MeshInstance3D).visible = false

## Front doors that can be left hanging open, in model space: the triangles of these parts whose
## middle falls inside the box are the door; it turns around the hinge at its front edge.
const DOOR := {gls = {parts = ["paint", "glass", "chrome", "trim"], x0 = -0.03, x1 = 1.04, y0 = 0.42, y1 = 1.62, z = 0.72, hinge = Vector2(1.05, 0.98)}}
var _door_cache := {}

## The model's parts with the front door on one side (+1: +z, -1: -z) split off. Door parts carry the
## hinge point as a fifth entry.
func _door_parts(vm: String, parts: Array, side: int) -> Array:
	var key := "%s%d" % [vm, side]
	if _door_cache.has(key):
		return _door_cache[key]
	var D: Dictionary = DOOR[vm]
	var hinge := Vector3(D.hinge.x, 0.0, D.hinge.y * side)
	var out := []
	for p in parts:
		if p[3] or not String(p[2]) in D.parts:
			out.append(p)
			continue
		var mesh: Mesh = p[0]
		var arrays := mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var body := PackedInt32Array()
		var leaf := PackedInt32Array()
		for t in range(0, idx.size(), 3):
			var c := (v[idx[t]] + v[idx[t + 1]] + v[idx[t + 2]]) / 3.0
			var on: bool = c.x > D.x0 and c.x < D.x1 and c.y > D.y0 and c.y < D.y1 and c.z * side > D.z
			var dst := leaf if on else body
			dst.append(idx[t])
			dst.append(idx[t + 1])
			dst.append(idx[t + 2])
		for half in [[body, null], [leaf, hinge]]:
			if (half[0] as PackedInt32Array).is_empty():
				continue
			var a := arrays.duplicate()
			a[Mesh.ARRAY_INDEX] = half[0]
			var m := ArrayMesh.new()
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
			out.append([m, p[1], p[2], false, half[1]])
	_door_cache[key] = out
	return out

## The same material drawn from both sides (the inside of an open door).
func _two_sided(m: Material) -> Material:
	var d: Material = m.duplicate()
	if d is StandardMaterial3D:
		(d as StandardMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
	elif d is ShaderMaterial:
		var sh := Shader.new()
		sh.code = (d as ShaderMaterial).shader.code.replace("render_mode ", "render_mode cull_disabled, ")
		(d as ShaderMaterial).shader = sh
	return d

## Footprint (length, width) of each kind of car, for the contact shadows.
const CAR_SIZE := {sedan = Vector2(4.7, 1.84), taxi = Vector2(4.7, 1.84), police = Vector2(4.7, 1.84), suv = Vector2(4.8, 1.94),
	van = Vector2(5.3, 1.98), ambulance = Vector2(5.3, 1.98), bus = Vector2(11.2, 2.5), fire = Vector2(9.0, 2.5),
	gls = Vector2(5.1, 2.1), agera = Vector2(4.3, 2.0)}

func _contact_shadows() -> void:
	var list: Array = data.cars
	var models := {}
	for s in data.vslots:
		models[Vector2(s.x, s.z)] = s
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var pm := PlaneMesh.new()
	pm.size = Vector2(1, 1)
	mm.mesh = pm
	mm.instance_count = list.size()
	for i in list.size():
		var c: Dictionary = list[i]
		var size: Vector2 = CAR_SIZE.get(String(c.type), CAR_SIZE.sedan)
		var s = models.get(Vector2(c.x, c.z))
		if s != null and ResourceLoader.exists("res://assets/vehicles/%s.glb" % s.vm):
			size = CAR_SIZE[s.vm] * car_scale(s)
		var ext := size + Vector2(0.9, 0.9)
		var b := Basis(Vector3.UP, float(c.get("ry", 0.0))).scaled(Vector3(ext.x, 1, ext.y))
		mm.set_instance_transform(i, Transform3D(b, Vector3(c.x, 0.012, c.z)))
		mm.set_instance_custom_data(i, Color(1.1 / ext.x, 1.1 / ext.y, 0, 0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = shader_mat("contact_shadow")
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.layers = 2   # hidden from the reflection camera
	mmi.name = "CarShadows"
	add_child(mmi)

func _car_box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.position = pos
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_car_vis(mi)
	return mi

func _car_vis(mi: GeometryInstance3D) -> void:
	mi.visibility_range_end = CAR_VIS_END
	mi.visibility_range_end_margin = 12.0
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

func _node_xform(n: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D()
	var cur: Node = n
	while cur and cur != root:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t

func _std(c: Color, rough: float, metal: float, coat := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c.linear_to_srgb()
	m.roughness = rough
	m.metallic = metal
	if coat > 0.0:
		m.clearcoat_enabled = true
		m.clearcoat = coat
		m.clearcoat_roughness = 0.06
	return m

# ---------------------------------------------------------------- collision
func _colliders() -> void:
	var body := StaticBody3D.new()
	body.name = "CityColliders"
	body.collision_layer = 0
	body.collision_mask = 0
	add_child(body)
	# one body per layer combination keeps queries simple
	var bodies := {}
	for c in col:
		var f := int(c[6])
		var los := f & 1 != 0
		var cam := f & 2 != 0
		var mon := f & 4 != 0
		var layer := 0
		if mon:
			layer = L_MONSTER
		else:
			layer = L_SOLID
			if los:
				layer |= L_SIGHT
			if cam:
				layer |= L_CAMERA
		if not bodies.has(layer):
			var b := StaticBody3D.new()
			b.collision_layer = layer
			b.collision_mask = 0
			b.name = "Col_%d" % layer
			add_child(b)
			bodies[layer] = b
		var sh := CollisionShape3D.new()
		var bx := BoxShape3D.new()
		var size := Vector3(float(c[1]) - float(c[0]), float(c[3]) - float(c[2]), float(c[5]) - float(c[4]))
		bx.size = Vector3(maxf(size.x, 0.02), maxf(size.y, 0.02), maxf(size.z, 0.02))
		sh.shape = bx
		sh.position = Vector3((float(c[0]) + float(c[1])) / 2.0, (float(c[2]) + float(c[3])) / 2.0, (float(c[4]) + float(c[5])) / 2.0)
		(bodies[layer] as StaticBody3D).add_child(sh)
	body.queue_free()

## Height of the walkable surface under (x,z): street 0, sidewalks and floors 0.14, the subway stairs, the underground at -6.
func ground_at(x: float, z: float, y: float) -> float:
	if x > hole.x0 and x < hole.x1 and z > hole.z0 and z < hole.z1:
		return 0.14 - 6.14 * (z - hole.z0) / (hole.z1 - hole.z0)
	if y < -3.0:
		return -6.0
	return 0.14 if on_slab(x, z) else 0.0

func on_slab(x: float, z: float) -> bool:
	for s in slabs:
		if x > s.x0 and x < s.x1 and z > s.z0 and z < s.z1:
			return true
	return false

func in_interior(x: float, z: float):
	for r in interiors:
		if x > r.x0 and x < r.x1 and z > r.z0 and z < r.z1:
			return r
	return null

# ---------------------------------------------------------------- lights
func _lights() -> void:
	moon = DirectionalLight3D.new()
	moon.light_color = Color(0x6d / 255.0, 0x82 / 255.0, 0xa8 / 255.0).linear_to_srgb()
	moon.light_energy = 0.16
	moon.look_at_from_position(Vector3(-80, 140, 40), Vector3.ZERO)
	moon.shadow_enabled = false
	add_child(moon)
	var k := (HEMI_SKY - HEMI_GROUND) * (HEMI / 2.0)
	var kmax := maxf(k.r, maxf(k.g, k.b))
	for neg in [false, true]:
		var h := DirectionalLight3D.new()
		h.name = "HemiDown" if not neg else "HemiUp"
		h.light_color = Color(k.r / kmax, k.g / kmax, k.b / kmax).linear_to_srgb()
		h.light_energy = kmax
		h.light_negative = neg
		h.light_specular = 0.0
		h.shadow_enabled = false
		h.rotation = Vector3(-PI / 2.0 if not neg else PI / 2.0, 0, 0)
		add_child(h)
		hemi_lights.append(h)
	bolt = DirectionalLight3D.new()
	bolt.light_color = Color(0xcd / 255.0, 0xd8 / 255.0, 1.0).linear_to_srgb()
	bolt.light_energy = 0.0
	bolt.look_at_from_position(Vector3(60, 160, -80), Vector3.ZERO)
	add_child(bolt)
	for i in 5:
		var l := OmniLight3D.new()
		l.omni_range = 18.0
		l.omni_attenuation = RANGE_FIT.y
		l.light_energy = 0.0
		l.shadow_enabled = false
		add_child(l)
		pool_lights.append(l)

## Called every frame with the point the lights should gather around (the player).
func update(dt: float, t: float, ref: Vector3, weather: float, cam: Camera3D) -> void:
	RenderingServer.global_shader_parameter_set("game_time", t)
	pool_t -= dt
	if pool_t <= 0.0:
		pool_t = 0.2
		var cand := []
		for L in lamps:
			if L.on:
				var d: float = (L.p.x - ref.x) ** 2 + ((L.p.y - ref.y) * 1.5) ** 2 + (L.p.z - ref.z) ** 2
				cand.append([L, d])
		cand.sort_custom(func(a, b): return a[1] < b[1])
		pool_sel = cand.slice(0, 5).map(func(a): return a[0])
	lit_near = false
	for i in pool_lights.size():
		var l := pool_lights[i]
		if i >= pool_sel.size():
			l.light_energy = 0.0
			continue
		var L: Dictionary = pool_sel[i]
		l.position = L.p
		l.omni_range = L.r * RANGE_FIT.x
		var d := Vector2(L.p.x - ref.x, L.p.z - ref.z).length()
		var f := 1.0
		if L.flicker > 0.0:
			var n := sin(t * 23.0 + L.p.x) * sin(t * 7.3 + L.p.z)
			f = 0.15 if n > 0.9 - L.flicker * 0.6 else 1.0
		if L.kind == "police":
			l.light_color = (POLICE_RED if int(floor(t * 2.2)) % 2 == 1 else POLICE_BLUE).linear_to_srgb()
		else:
			l.light_color = L.c
		l.light_energy = L.i * clampf(1.0 - (d - 22.0) / 18.0, 0.0, 1.0) * f * RANGE_FIT.z
		if L.kind == "street" and Vector2(L.p.x - ref.x, L.p.z - ref.z).length() < 6.5 and f > 0.5:
			lit_near = true
	# blinking halos
	for b in blink:
		var k := 1.0
		match String(b.kind):
			"avi": k = 1.0 if sin((t + b.ph) * 2.2) > 0.6 else 0.08
			"police": k = 1.0 if int(floor(t * 2.2 + b.ph * 2.0)) % 2 == 0 else 0.05
			"hazard": k = 1.0 if int(floor(t * 1.6)) % 2 == 1 else 0.05
			"amber": k = 1.0 if int(floor(t * 1.1)) % 2 == 1 else 0.12
			"led":
				var a : float = alarm_state.call(int(b.alarm))
				k = 0.0 if a > 0.0 else (1.0 if sin(t * 2.6 + b.ph) > 0.9 else 0.12)
			"alarm":
				var a2 : float = alarm_state.call(int(b.alarm))
				k = (1.0 if int(floor(t * 3.2)) % 2 == 1 else 0.03) if a2 > 0.0 else 0.0
		halo_mm.set_instance_color(int(b.i), halo_base[int(b.i)] * k)
	# neon flicker
	for n in neons:
		var k := 1.0
		if n.mode == "flicker":
			k = (0.2 if randf() < 0.5 else 1.0) if sin(t * 1.3 + n.ph) > 0.93 else 1.0
		elif n.mode == "broken":
			var s := sin(t * 0.7 + n.ph)
			k = (0.1 if randf() < 0.3 else 0.9) if s > 0.4 else (0.08 if s > -0.2 else 1.0)
		elif n.mode == "dim":
			k = 0.8
		for m in n.mats:
			(m as ShaderMaterial).set_shader_parameter("level", k)
		if n.lamp >= 0:
			lamps[n.lamp].on = k >= 0.3
	# weather and lightning
	RenderingServer.global_shader_parameter_set("rain_amount", weather)
	if refl_vp:
		refl_env.fog_depth_end = env.fog_depth_end / 1.35
		_update_reflection(cam)
	env.fog_depth_end = fog_end / (0.85 + 0.3 * weather)
	env.ambient_light_energy = 1.0 + flash * 5.2
	for h in hemi_lights:
		h.light_energy = maxf(HEMI_SKY.r - HEMI_GROUND.r, maxf(HEMI_SKY.g - HEMI_GROUND.g, HEMI_SKY.b - HEMI_GROUND.b)) * HEMI / 2.0 * (1.0 + flash * 5.2)
	bolt.light_energy = flash * 1.6
	env.fog_light_color = fog_base.lightened(flash * 0.18).linear_to_srgb()
	sky_mat.set_shader_parameter("flash", flash)
	skyline_mat.set_shader_parameter("flash", flash)
	_update_rain(weather, cam)

# ---------------------------------------------------------------- wet-street reflections
## A second camera mirrored below the street renders the city upside down into a small texture,
## which the wet ground shaders sample (the same trick as the browser version).
var refl_vp: SubViewport
var refl_cam: Camera3D
var refl_env: Environment
var refl_enabled := true
var refl_scale := 0.28

## Graphics level 0 low, 1 medium, 2 high: street reflections, glow and how far away cars are drawn.
func set_quality(lv: int) -> void:
	refl_enabled = lv > 0
	refl_scale = [0.2, 0.26, 0.36][lv]
	if refl_vp:
		_resize_reflection()
	env.glow_enabled = lv > 0
	var vis: float = [60.0, 85.0, CAR_VIS_END][lv]
	var cars := get_node_or_null("Cars")
	if cars:
		for n in cars.find_children("*", "GeometryInstance3D", true, false):
			var gi := n as GeometryInstance3D
			if gi.has_meta("far") or gi.visibility_range_end > CAR_NEAR:
				gi.visibility_range_end = vis

func setup_reflection() -> void:
	refl_vp = SubViewport.new()
	refl_vp.name = "Reflection"
	refl_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	refl_vp.use_hdr_2d = true
	refl_vp.positional_shadow_atlas_size = 0
	refl_vp.gui_disable_input = true
	refl_vp.mesh_lod_threshold = 6.0   # the blurry mirror image doesn't need fine detail
	add_child(refl_vp)
	refl_cam = Camera3D.new()
	refl_cam.cull_mask = 1 | REFL_LAYER
	refl_env = env.duplicate()
	refl_env.glow_enabled = false
	refl_env.adjustment_enabled = false
	refl_cam.environment = refl_env
	refl_vp.add_child(refl_cam)
	refl_cam.current = true
	RenderingServer.global_shader_parameter_set("refl_tex", refl_vp.get_texture())
	get_viewport().size_changed.connect(_resize_reflection)
	_resize_reflection()

func _resize_reflection() -> void:
	var sz := Vector2(get_window().size) * refl_scale
	refl_vp.size = Vector2i(maxi(64, int(sz.x)), maxi(64, int(sz.y)))

func _update_reflection(cam: Camera3D) -> void:
	var p := cam.global_position
	if not refl_enabled or p.y < 0.3:
		RenderingServer.global_shader_parameter_set("refl_on", 0.0)
		refl_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	refl_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	RenderingServer.global_shader_parameter_set("refl_on", 1.0)
	var b := cam.global_transform.basis
	var tgt := p - b.z
	refl_cam.fov = cam.fov
	refl_cam.near = cam.near
	refl_cam.far = cam.far
	refl_cam.look_at_from_position(Vector3(p.x, -p.y, p.z), Vector3(tgt.x, -tgt.y, tgt.z), Vector3(b.y.x, -b.y.y, b.y.z))
	var vp := refl_cam.get_camera_projection() * Projection(refl_cam.global_transform.affine_inverse())
	RenderingServer.global_shader_parameter_set("refl_vp", vp)

## Car alarm state lookup, provided by the game (seconds of alarm left, 0 = quiet).
var alarm_state: Callable = func(_i: int) -> float: return 0.0

# ---------------------------------------------------------------- rain
func _rain() -> void:
	var n := 1100
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in n:
		var seed := Color(rng.randf(), rng.randf(), rng.randf(), rng.randf())
		var corners := [Vector2(-1, 0), Vector2(1, 0), Vector2(1, 1), Vector2(-1, 0), Vector2(1, 1), Vector2(-1, 1)]
		for c in corners:
			st.set_color(seed)
			st.set_uv(c)
			st.add_vertex(Vector3.ZERO)
	var mesh := st.commit()
	rain_mat = shader_mat("rain")
	rain_node = MeshInstance3D.new()
	rain_node.mesh = mesh
	rain_node.material_override = rain_mat
	rain_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rain_node.custom_aabb = AABB(Vector3(-1000, -100, -1000), Vector3(2000, 400, 2000))
	rain_node.layers = 2
	add_child(rain_node)
	var st2 := SurfaceTool.new()
	st2.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 160:
		var seed := Color(rng.randf(), rng.randf(), rng.randf(), rng.randf())
		for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			st2.set_color(seed)
			st2.set_uv(c)
			st2.add_vertex(Vector3.ZERO)
	splash_mat = shader_mat("splash", {tex = tex("glow"), ground_mask = _ground_mask(), mask_rect = Vector4(-MASK_HALF, -MASK_HALF, MASK_HALF * 2.0, MASK_HALF * 2.0)})
	splash_node = MeshInstance3D.new()
	splash_node.mesh = st2.commit()
	splash_node.material_override = splash_mat
	splash_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	splash_node.custom_aabb = rain_node.custom_aabb
	splash_node.layers = 2
	add_child(splash_node)

func _update_rain(weather: float, cam: Camera3D) -> void:
	var cp := cam.global_position
	var hide := weather < 0.004 or cp.y < -1.0 or in_interior(cp.x, cp.z) != null
	rain_node.visible = not hide
	splash_node.visible = not hide
	rain_mat.set_shader_parameter("amount", weather)
	splash_mat.set_shader_parameter("amount", weather)

const MASK_HALF := 120.0
## Half-metre map of the raised sidewalks (red) and indoor floors (green), so splashes land on the right surface.
func _ground_mask() -> ImageTexture:
	var n := int(MASK_HALF * 4.0)
	var img := Image.create(n, n, false, Image.FORMAT_RG8)
	var k := n / (MASK_HALF * 2.0)
	for s in slabs:
		img.fill_rect(Rect2i(int((s.x0 + MASK_HALF) * k), int((s.z0 + MASK_HALF) * k), int((s.x1 - s.x0) * k), int((s.z1 - s.z0) * k)), Color(1, 0, 0))
	for r in interiors:
		img.fill_rect(Rect2i(int((r.x0 + MASK_HALF) * k), int((r.z0 + MASK_HALF) * k), int((r.x1 - r.x0) * k), int((r.z1 - r.z0) * k)), Color(1, 1, 0))
	return ImageTexture.create_from_image(img)
