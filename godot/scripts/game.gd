## Lost City: the game. Owns the city, the three characters, the clues, the director that stages
## scares, the escape, sound mixing and the flow between menu, play and the end screens.
## Ported from the browser version (index.html); the numbers are the same so it plays the same.
class_name Game
extends Node3D

const SETTINGS_PATH := "user://settings.json"
const RECORDS_PATH := "user://records.json"
const EXIT_FLARE := Color(1.0, 0.188, 0.094)   # 0xff3018

var args := {}
var world: World
var col: Col
var sfx: Sfx
var hud: Hud
var cam: Camera3D
var pl: PlayerCtl
var child: Child
var mon: Monster
var data: Dictionary
var nodes: Array
var bound := 117.6

# flow
var phase := "menu"
var paused := false
var time := 0.0          # time in this run
var clock := 0.0         # wall clock, keeps running in menus
var menu_t := 0.0
var loc: Dictionary
var exit: Dictionary
var found := 0
var quiet := 0.0
var help_said := false
var cry_t := 6.0
var end_t := 0.0
var escape_t := 0.0
var nag_t := 0.0
var choice := -1
var deaths := 0
var alarm_told := false
var timers: Array = []   # [[time, Callable]], run on game time

class Director:
	var next_cross := 18.0
	var next_phantom := 75.0
	var next_lightning := 24.0
	var next_siren := 12.0
	var flash_seq: Array = []
	var flash_t := 0.0
	var crossing: Dictionary = {}
	var near_t := 0.0
	var far_t := 0.0
	var esc_t := 30.0
	var thunder_at := -1.0
	var thunder_vol := 0.0
var dir := Director.new()

# weather: 0 dry .. 1 storm, eases toward wx_to
var wx_states: Array
var wx_i := 0.65
var wx_to := 0.65
var wx_s := "rain"
var wx_t := 45.0

var settings := {vol = 80, rain = 60, sens = 100, gfx = "auto", vib = true}
var records := {runs = 0, wins = 0, best = 0.0}

# clues and props
var clues: Array = []
var clue_root: Node3D
var hides: Array = []
var alarms: Array = []
var loc_lamps: Dictionary
var exg: Node3D
var ex_flare: OmniLight3D
var ex_on := false

# heartbeat
var heart_t := 0.0
# adaptive quality
var fps_acc := 0.0
var fps_n := 0
var fps_check := 0.0
var low_q := false
var q1 := false

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var eq := a.find("=")
			if eq > 0:
				args[a.substr(2, eq - 2)] = a.substr(eq + 1)
			else:
				args[a.substr(2)] = "1"
	if args.has("seed"):
		seed(int(args.seed))
	settings.merge(U.load_json(SETTINGS_PATH), true)
	records.merge(U.load_json(RECORDS_PATH), true)
	world = World.new()
	world.name = "World"
	add_child(world)
	data = world.data
	nodes = data.nodes
	for n in nodes:
		n.n = n.n.map(func(v): return int(v))
	bound = float(data.BOUND)
	col = Col.new(data.col, bound)
	wx_states = data.wxStates
	for h in data.hides:
		hides.append(Vector2(h[0], h[1]))
	for a in data.alarms:
		alarms.append({x = float(a.x), z = float(a.z), hx = float(a.hx), hz = float(a.hz), alarm_t = 0.0, cd = 0.0, call_t = 0.0, voice = -1})
	world.alarm_state = func(i: int) -> float: return alarms[i].alarm_t if i >= 0 and i < alarms.size() else 0.0
	loc_lamps = data.locLamps
	sfx = Sfx.new()
	sfx.name = "Sfx"
	add_child(sfx)
	cam = Camera3D.new()
	cam.fov = 62.0
	cam.near = 0.1
	cam.far = 950.0
	cam.cull_mask = 0xFFFFF & ~World.REFL_LAYER
	add_child(cam)
	cam.current = true
	world.setup_reflection()
	pl = PlayerCtl.new(self)
	child = Child.new(self)
	mon = Monster.new(self)
	pl.setup_model()
	child.setup_model()
	mon.setup_model()
	clue_root = Node3D.new()
	clue_root.name = "Clues"
	add_child(clue_root)
	_build_exit()
	_grade()
	hud = Hud.new(self)
	add_child(hud)
	sfx.set_master(settings.vol / 100.0)
	get_viewport().size_changed.connect(_on_resize)
	_on_resize()
	apply_gfx()
	to_menu()
	if args.has("play"):
		start_game()
	elif args.has("settings"):
		hud.open_settings()

func _grade() -> void:
	# colour grade, grain and a touch of lens fringing, like the browser version
	var layer := CanvasLayer.new()
	layer.layer = -1
	add_child(layer)
	var r := ColorRect.new()
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/grade.gdshader")
	r.material = m
	layer.add_child(r)

func _on_resize() -> void:
	var s := get_viewport().get_visible_rect().size
	var portrait := s.x < s.y
	cam.fov = 72.0 if portrait else 62.0
	pl.cam_dist = 4.4 if portrait else 3.3

# ---------------------------------------------------------------- helpers
func buzz(ms: int) -> void:
	if settings.vib:
		Input.vibrate_handheld(ms)

func after(sec: float, fn: Callable) -> void:
	timers.append([time + sec, fn])

func _run_timers() -> void:
	var i := 0
	while i < timers.size():
		if time >= timers[i][0]:
			var fn: Callable = timers[i][1]
			timers.remove_at(i)
			fn.call()
		else:
			i += 1

## Volume, stereo pan and muffling for a sound at (x,y,z), heard from the camera (posParams).
func pos_params(x: float, y: float, z: float, ref: float) -> Dictionary:
	var cp := cam.global_position
	var dx := x - cp.x
	var dz := z - cp.z
	var d := U.hyp(dx, dz) + 0.01
	var rel := U.ang_diff(pl.cam_yaw, atan2(dx, dz))
	var pan := -sin(rel) * 0.85
	var vol := 1.0 / (1.0 + pow(d / ref, 2.0))
	var lp := 16000.0 * exp(-d / 45.0) + 300.0
	if cos(rel) < 0.0:
		lp *= 0.6
	var under := pl.pos.y < -2.0
	var src_under := y < -2.0
	if under != src_under:
		lp = minf(lp, 260.0)
	elif not col.los_clear(cp.x, cp.z, x, z, 2.5):
		lp = minf(lp, 700.0)
	return {vol = vol, pan = pan, lp = lp, d = d}

# ---------------------------------------------------------------- navigation
func bfs(a: int, b: int) -> Array:
	if a == b:
		return [a]
	var prev := PackedInt32Array()
	prev.resize(nodes.size())
	prev.fill(-1)
	prev[a] = a
	var q := [a]
	var qi := 0
	while qi < q.size():
		var u: int = q[qi]
		qi += 1
		if u == b:
			break
		for v in nodes[u].n:
			if prev[int(v)] < 0:
				prev[int(v)] = u
				q.append(int(v))
	if prev[b] < 0:
		return [b]
	var path := []
	var u := b
	while u != a:
		path.append(u)
		u = prev[u]
	path.append(a)
	path.reverse()
	return path

func nearest_node(x: float, z: float, need_clear: bool) -> int:
	var best := -1
	var bd := 1e9
	var fb := -1
	var fbd := 1e9
	for i in nodes.size():
		var d := U.hyp(nodes[i].x - x, nodes[i].z - z)
		if d < fbd:
			fbd = d
			fb = i
		if d < bd and (not need_clear or col.path_clear(x, z, nodes[i].x, nodes[i].z, 0.9)):
			bd = d
			best = i
	return best if best >= 0 else fb

# ---------------------------------------------------------------- weather
func wx_pick(not_name := "") -> Dictionary:
	var c := wx_states.filter(func(s): return s.n != not_name)
	var total := 0.0
	for s in c:
		total += float(s.w)
	var r := randf() * total
	for s in c:
		r -= float(s.w)
		if r <= 0.0:
			return s
	return c[0]

func wx_set(s: Dictionary, instant := false) -> void:
	wx_s = s.n
	wx_to = float(s.i)
	wx_t = U.rnd(35.0, 80.0)
	if instant:
		wx_i = wx_to

func lightning(s := 1.0) -> void:
	dir.flash_seq = [[0.0, 1.0 * s], [0.06, 0.15 * s], [0.13, 0.85 * s], [0.2, 0.1 * s], [0.32, 0.5 * s], [0.5, 0.0]]
	dir.flash_t = 0.0
	dir.thunder_at = time + U.rnd(0.8, 2.4)
	dir.thunder_vol = 0.35 + 0.3 * s

# ---------------------------------------------------------------- flow
func setup_location() -> void:
	for k in loc_lamps:
		world.lamps[int(loc_lamps[k])].on = true
	if loc_lamps.has(loc.id):
		world.lamps[int(loc_lamps[loc.id])].on = false
	child.reset(loc)

func new_game() -> void:
	var locs: Array = data.locs
	loc = locs[randi() % locs.size()]
	if args.has("loc"):
		for l in locs:
			if l.id == args.loc:
				loc = l
	var ok: Array = data.starts.filter(func(s): return U.hyp(s.x - loc.ent[0], s.z - loc.ent[1]) > 70.0)
	var st: Dictionary = ok[randi() % ok.size()] if ok.size() else data.starts[0]
	pl.reset(Vector3(st.x, world.ground_at(st.x, st.z, 0.0), st.z))
	hud.set_toggle("crouch", false)
	hud.set_toggle("light", true)
	setup_location()
	# the exit is the one farthest from the child
	var ex: Array = data.exits.duplicate()
	ex.sort_custom(func(a, b): return U.hyp(a.x - loc.ent[0], a.z - loc.ent[1]) > U.hyp(b.x - loc.ent[0], b.z - loc.ent[1]))
	exit = ex[0]
	exg.visible = false
	ex_on = false
	ex_flare.light_energy = 0.0
	world.set_dyn_halo(0, Vector3(0, -99, 0), Color(0, 0, 0), 0.0)
	mon.reset()
	place_clues()
	wx_set(wx_pick(), true)
	for c in alarms:
		c.alarm_t = 0.0
		c.cd = 0.0
		sfx.release(c.voice)
		c.voice = -1
	found = 0
	time = 0.0
	quiet = 0.0
	help_said = false
	cry_t = 6.0
	escape_t = 0.0
	nag_t = 0.0
	timers.clear()
	dir = Director.new()
	dir.next_cross = 16.0 + U.rnd(0.0, 6.0)
	dir.next_phantom = U.rnd(70.0, 95.0)
	dir.next_lightning = U.rnd(20.0, 30.0)
	dir.next_siren = U.rnd(8.0, 20.0)
	dir.esc_t = 25.0
	hud.set_obj("FIND THE CHILD", "Child location: unknown")
	hud.reset_play()
	phase = "explore"
	hud.sub("YOU", "She has to be somewhere close. Stay quiet. Stay out of sight.", 5.0)

func start_game() -> void:
	paused = false
	sfx.pause_all(false)
	hud.show_screen("hud")
	new_game()

func lose() -> void:
	if phase == "caught" or phase == "lost":
		return
	phase = "caught"
	end_t = 0.0
	mon.state = "ATTACK"
	mon.attack_t = 0.0
	deaths += 1
	buzz(280)
	var pp := pos_params(mon.pos.x, 3.0, mon.pos.z, 30.0)
	sfx.play("roar", 0.9, pp.pan, 4000.0, 0)
	pl.shake = 1.2

func win() -> void:
	phase = "won"
	end_t = 0.0
	sfx.play("chime", 0.13)
	buzz(60)

func show_end(won: bool) -> void:
	var mins := int(time / 60.0)
	records.runs += 1
	var new_best := false
	if won:
		records.wins += 1
		if records.best <= 0.0 or time < records.best:
			records.best = time
			new_best = true
	U.save_json(RECORDS_PATH, records)
	var title := "CHILD RESCUED" if won else "YOU WERE FOUND"
	var eyebrow := ("Evacuation point · %s barricade" % exit.name) if won else ("03:%02d · Somewhere in the city" % (12 + mini(47, mins)))
	var body := "You carried her through the rain and out of the city. She is safe now." if won else \
		("It caught you in the open. She is still out there, waiting for you." if child.state != "hiding" else "It caught you in the open. She is still hiding, waiting for someone to come.")
	var stats := "Time %s · Clues %d/5" % [U.fmt_t(time), found]
	if new_best:
		stats += " · New best rescue"
	elif records.best > 0.0:
		stats += " · Best " + U.fmt_t(records.best)
	hud.show_end(eyebrow, title, body, stats, "PLAY AGAIN" if won else "TRY AGAIN")
	phase = "wonEnd" if won else "lost"

func to_menu() -> void:
	paused = false
	sfx.pause_all(false)
	phase = "menu"
	menu_t = 0.0
	pl.light.light_energy = 0.0
	pl.beam.visible = false
	sfx.loop_to("drone_loop", 0.0, 0.3)
	hud.release_input()
	hud.reset_play()
	hud.show_screen("start")

func can_pause() -> bool:
	return phase == "explore" or phase == "escape"

func set_pause(on: bool) -> void:
	if on and not can_pause():
		return
	if paused == on:
		return
	paused = on
	hud.release_input()
	sfx.pause_all(on)
	if on:
		hud.show_pause("Paused · %s · Clues %d/5" % [U.fmt_t(time), found])
	else:
		hud.show_screen("hud")

func _notification(what: int) -> void:
	# pause when the app goes to the background (phone call, home button, screen off)
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		if can_pause():
			set_pause(true)

func save_settings() -> void:
	U.save_json(SETTINGS_PATH, settings)

## Graphics level in use: 0 low, 1 medium, 2 high. LOW turns off wet-street reflections, glow and
## the flashlight's shadows and renders the 3D view at a lower resolution; MEDIUM keeps them with a
## lighter reflection and resolution. AUTO starts high and steps down while the frame rate is poor
## (see _adapt).
func gfx_level() -> int:
	match String(settings.gfx):
		"low": return 0
		"medium": return 1
		"high": return 2
	return 0 if low_q else (1 if q1 else 2)

func apply_gfx() -> void:
	var lv := gfx_level()
	var vp := get_viewport()
	var touch := DisplayServer.is_touchscreen_available()
	# phones render the 3D view a little below screen resolution (the Mobile renderer can only
	# stretch it back up; FSR sharpening needs the Forward+ renderer)
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = [0.6, 0.75, 0.9][lv] if touch else [0.7, 1.0, 1.0][lv]
	vp.msaa_3d = Viewport.MSAA_DISABLED if lv == 0 else Viewport.MSAA_2X
	world.set_quality(lv)
	pl.light.shadow_enabled = lv > 0

# ---------------------------------------------------------------- clues
func _mat(c: Color, rough: float, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c.linear_to_srgb()
	m.roughness = rough
	m.metallic = metal
	return m

func _mesh(mesh: Mesh, mat: Material, p := Vector3.ZERO, rot := Vector3.ZERO, sc := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = p
	mi.rotation = rot
	mi.scale = sc
	return mi

func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 10
	s.rings = 8
	return s

func _box(x: float, y: float, z: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(x, y, z)
	return b

func _cyl(rt: float, rb: float, h: float, seg := 8) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = rt
	c.bottom_radius = rb
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c

func _make_toy() -> Node3D:
	var g := Node3D.new()
	var m := _mat(Color8(0x8a, 0x7c, 0x80), 0.95)
	g.add_child(_mesh(_sphere(0.1), m, Vector3(0, 0.08, 0), Vector3.ZERO, Vector3(1, 0.8, 0.9)))
	g.add_child(_mesh(_sphere(0.07), m, Vector3(0, 0.13, 0.07)))
	for s in [-1.0, 1.0]:
		g.add_child(_mesh(_cyl(0.02, 0.02, 0.14, 6), m, Vector3(s * 0.03, 0.24, 0.02), Vector3(0, 0, s * 0.3)))
	return g

func _make_bag() -> Node3D:
	var g := Node3D.new()
	g.add_child(_mesh(_box(0.34, 0.26, 0.16), _mat(Color8(0x7a, 0x1f, 0x24), 0.7), Vector3(0, 0.13, 0), Vector3(0, 0, 1.2)))
	g.add_child(_mesh(_box(0.24, 0.14, 0.06), _mat(Color8(0xd8, 0xb2, 0x3a), 0.6), Vector3(0.02, 0.12, 0.1), Vector3(0, 0, 1.2)))
	return g

func _make_note() -> Node3D:
	var g := Node3D.new()
	var p := PlaneMesh.new()
	p.size = Vector2(0.22, 0.3)
	var m := _mat(Color8(0xd9, 0xd4, 0xc6), 0.9)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	g.add_child(_mesh(p, m, Vector3(0, 0.02, 0), Vector3(0, 0.5, 0)))
	return g

func _glint() -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = Vector2(0.5, 0.5)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_texture = world.tex("glow")
	m.albedo_color = Color(1.0, 0.949, 0.816).linear_to_srgb()
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func place_clues() -> void:
	for c in clue_root.get_children():
		c.queue_free()
	clues.clear()
	var T: Dictionary = data.txt[loc.id]
	var ex: float = loc.ent[0]
	var ez: float = loc.ent[1]
	var spots: Array = data.cluespots.filter(func(s): return not s.under and absf(s.x) < bound - 2.0 and absf(s.z) < bound - 2.0 and col.walkable(s.x, s.z, 0.4))
	var used := [Vector2(pl.pos.x, pl.pos.z)]
	var pick := func(lo: float, hi: float) -> Dictionary:
		var c := spots.filter(func(s):
			var d := U.hyp(s.x - ex, s.z - ez)
			if d <= lo or d >= hi:
				return false
			for a in used:
				if U.hyp(a.x - s.x, a.y - s.z) <= 28.0:
					return false
			return true)
		return c[randi() % c.size()] if c.size() else spots[randi() % spots.size()]
	var toy_s: Dictionary
	if loc.id == "park":
		var parks: Array = data.cluespots.filter(func(s): return s.park)
		toy_s = parks[randi() % mini(3, parks.size())]
	else:
		toy_s = pick.call(10.0, 34.0)
	used.append(Vector2(toy_s.x, toy_s.z))
	var bag_s: Dictionary = pick.call(48.0, 110.0)
	used.append(Vector2(bag_s.x, bag_s.z))
	var note_s: Dictionary = pick.call(36.0, 1e9)
	_add_clue("toy", "Plush rabbit", T.toy, _make_toy(), toy_s.x, toy_s.z)
	_add_clue("bag", "Backpack", String(T.bag).replace("{d}", U.dir_word(ex - bag_s.x, ez - bag_s.z)), _make_bag(), bag_s.x, bag_s.z)
	_add_clue("note", "Handwritten note", T.note, _make_note(), note_s.x, note_s.z)
	# footprints leading to the hiding place
	var a: Array = loc.trail[0]
	var b: Array = loc.trail[1]
	var len := U.hyp(b[0] - a[0], b[1] - a[1])
	var n := int(floor(len / 0.75))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var q := QuadMesh.new()
	q.size = Vector2(0.11, 0.22)
	q.orientation = PlaneMesh.FACE_Y
	mm.mesh = q
	mm.instance_count = n
	var yaw := atan2(b[0] - a[0], b[1] - a[1])
	var prints := []
	for k in n:
		var t := float(k) / n
		var side := 1.0 if k % 2 else -1.0
		var x: float = lerpf(a[0], b[0], t) + cos(yaw) * 0.1 * side
		var z: float = lerpf(a[1], b[1], t) - sin(yaw) * 0.1 * side
		var y := world.ground_at(x, z, 0.0) + 0.012
		mm.set_instance_transform(k, Transform3D(Basis(Vector3.UP, yaw + U.rnd(-0.15, 0.15)), Vector3(x, y, z)))
		prints.append(Vector2(x, z))
	var fp := MultiMeshInstance3D.new()
	fp.multimesh = mm
	var pm := StandardMaterial3D.new()
	pm.albedo_texture = world.tex("print")
	pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	pm.roughness = 0.3
	pm.render_priority = 1
	fp.material_override = pm
	fp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	clue_root.add_child(fp)
	var mid: Vector2 = prints[int(prints.size() * 0.55)]
	var cp := _add_clue("prints", "Footprints", T.prints, null, mid.x, mid.y, world.ground_at(mid.x, mid.y, 0.0), 2.4)
	cp.prints = prints
	clues.append({type = "cry", title = "Distant crying", text = "", found = false, virtual = true})
	hud.set_clue_count(0)

func _add_clue(type: String, title: String, text: String, obj: Node3D, x: float, z: float, y := 0.15, r := 2.2) -> Dictionary:
	var cl := {type = type, title = title, text = text, obj = obj, x = x, z = z, y = y, r = r, found = false, virtual = false, prints = []}
	if obj:
		obj.position = Vector3(x, y, z)
		obj.rotation.y = randf() * TAU
		clue_root.add_child(obj)
	var gl := _glint()
	gl.position = Vector3(x, y + 0.35, z)
	clue_root.add_child(gl)
	cl.glint = gl
	clues.append(cl)
	return cl

func find_clue(cl: Dictionary) -> void:
	if cl.found:
		return
	buzz(18)
	cl.found = true
	cl.found_at = time
	found += 1
	hud.set_clue_count(found)
	if cl.has("glint") and cl.glint:
		cl.glint.visible = false
	if cl.get("obj") and cl.type != "prints":
		cl.obj.visible = false
	hud.toast(cl.title, cl.text, 9.0)
	sfx.play("chime", 0.13)
	hud.refresh_log()

func _update_glints(t: float) -> void:
	var bx := sin(pl.cam_yaw)
	var bz := cos(pl.cam_yaw)
	for cl in clues:
		if not cl.has("glint") or cl.found:
			continue
		var d := U.hyp(cl.x - pl.pos.x, cl.z - pl.pos.z)
		var vis := 0.0
		if d < 16.0 and absf(cl.y - pl.pos.y) < 2.0:
			var dot: float = ((cl.x - pl.pos.x) * bx + (cl.z - pl.pos.z) * bz) / maxf(d, 0.01)
			vis = 1.0 if d < 4.0 else (1.0 if pl.flash and dot > 0.85 else 0.0)
		var gl: MeshInstance3D = cl.glint
		gl.visible = vis > 0.0
		var c := Color(1.0, 0.949, 0.816).linear_to_srgb()
		c.a = vis * (0.5 + 0.5 * sin(t * 4.0 + cl.x))
		(gl.material_override as StandardMaterial3D).albedo_color = c

# ---------------------------------------------------------------- interaction
## What USE does right now: {label, fn} or {}.
func find_interact() -> Dictionary:
	if pl.hidden:
		return {label = "LEAVE", fn = _leave_hide}
	var px := pl.pos.x
	var pz := pl.pos.z
	var same := func(y: float) -> bool: return absf(y - pl.pos.y) < 1.8
	if phase == "explore" and U.hyp(child.pos.x - px, child.pos.z - pz) < 2.8 and same.call(child.pos.y):
		return {label = "HELP", fn = talk_child}
	if phase == "escape" and child.state == "wait" and U.hyp(child.pos.x - px, child.pos.z - pz) < 7.0:
		return {label = "CALL", fn = _call_child}
	if phase == "explore":
		for cl in clues:
			if cl.found or cl.virtual:
				continue
			var d := 1e9
			if cl.prints.size():
				for p in cl.prints:
					d = minf(d, U.hyp(p.x - px, p.y - pz))
			else:
				d = U.hyp(cl.x - px, cl.z - pz)
			if d < cl.r and same.call(cl.y):
				var c: Dictionary = cl
				return {label = "EXAMINE", fn = func(): find_clue(c)}
	for h in hides:
		if U.hyp(h.x - px, h.y - pz) < 2.1 and pl.pos.y > -1.0:
			return {label = "HIDE", fn = _hide}
	return {}

func _leave_hide() -> void:
	pl.hidden = false
	pl.compromised = false

func _call_child() -> void:
	child.state = "follow"
	hud.sub("YOU", "Come on. I’m right here.", 2.2)

func _hide() -> void:
	pl.hidden = true
	pl.compromised = mon.state == "CHASE" and mon.sees
	pl.crouch = true
	hud.set_toggle("crouch", true)
	hud.sub("HIDING", "Hold still.", 1.6)

func do_interact() -> void:
	if phase != "explore" and phase != "escape":
		return
	var a := find_interact()
	if a.size():
		a.fn.call()

func toggle_crouch() -> void:
	if phase != "explore" and phase != "escape":
		return
	pl.crouch = not pl.crouch
	hud.set_toggle("crouch", pl.crouch)

func toggle_flash() -> void:
	if phase != "explore" and phase != "escape" and phase != "dialog":
		return
	pl.flash = not pl.flash
	hud.set_toggle("light", pl.flash)
	sfx.play("ui_click", 0.18, 0.2)

func talk_child() -> void:
	phase = "dialog"
	child.state = "dialog"
	choice = -1
	hud.sub("YOU", "Hey… hey. Are you okay?", 2.2)
	after(2.2, _say_if_dialog.bind("CHILD", "I was scared. It’s out there…", 2.4))
	after(4.2, _offer_choices)

func _say_if_dialog(who: String, line: String, dur: float) -> void:
	if phase == "dialog":
		hud.sub(who, line, dur)

func _offer_choices() -> void:
	if phase != "dialog":
		return
	hud.show_choices(["I’m here to help.", "Let’s get out of here."])
	after(9.0, choose_line.bind(0))

func choose_line(k: int) -> void:
	if phase != "dialog" or choice >= 0:
		return
	choice = k
	hud.hide_choices()
	sfx.play("ui_click", 0.18, 0.2)
	var L := [["YOU", "I’m here to help. I’m not leaving without you.", 0.0], ["CHILD", "…Okay. Don’t let go.", 2.3]] if k == 0 else \
		[["YOU", "Let’s get out of here. Stay right behind me.", 0.0], ["CHILD", "Please don’t let it see us.", 2.3]]
	for l in L:
		after(l[2], _say_if_dialog.bind(l[0], l[1], 2.3))
	after(4.4, begin_escape)

func begin_escape() -> void:
	if phase != "dialog":
		return
	phase = "escape"
	child.state = "follow"
	child.hidden = false
	child.ti = maxi(0, pl.trail.size() - 1)
	hud.set_obj("GET THE CHILD OUT", "Head for the flare")
	after(3.5, _escape_obj_if_escaping)
	exg.visible = true
	ex_on = true
	exg.position = Vector3(exit.tx, 0.14, exit.tz)
	exg.rotation.y = PI / 2.0 if exit.alongX else 0.0
	var pp := pos_params(mon.pos.x, 3.0, mon.pos.z, 60.0)
	sfx.play("roar", maxf(0.25, pp.vol), pp.pan, pp.lp, 2)
	hud.sub("CHILD", "It heard us…", 2.5)
	mon.awareness = maxf(mon.awareness, 0.3)

func _escape_obj_if_escaping() -> void:
	if phase == "escape":
		update_escape_obj()

func update_escape_obj() -> void:
	var d := U.hyp(exit.x - pl.pos.x, exit.z - pl.pos.z)
	hud.set_obj("ESCAPE THE CITY", "Flare at the %s barricade · %d m %s" % [exit.name, int(round(d)), U.dir_word(exit.x - pl.pos.x, exit.z - pl.pos.z).to_upper()])

# ---------------------------------------------------------------- exit: truck, searchlight, flare
func _build_exit() -> void:
	exg = Node3D.new()
	exg.name = "Extraction"
	exg.visible = false
	add_child(exg)
	var tm := _mat(Color8(0x2f, 0x34, 0x30), 0.6, 0.3)
	exg.add_child(_mesh(_box(2.6, 2.6, 6.5), tm, Vector3(0, 1.6, 0)))
	exg.add_child(_mesh(_box(2.5, 1.6, 2.0), tm, Vector3(0, 1.1, 4.1)))
	var bm := ShaderMaterial.new()
	bm.shader = load("res://shaders/searchlight.gdshader")
	var beam := _mesh(_cyl(1.4, 5.0, 180.0, 16), bm, Vector3(0, 92, 0), Vector3(0, 0, 0.12))
	(beam.mesh as CylinderMesh).cap_top = false
	(beam.mesh as CylinderMesh).cap_bottom = false
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	exg.add_child(beam)
	ex_flare = OmniLight3D.new()
	ex_flare.light_color = EXIT_FLARE.linear_to_srgb()
	ex_flare.omni_range = 26.0 * World.RANGE_FIT.x
	ex_flare.omni_attenuation = World.RANGE_FIT.y
	ex_flare.light_energy = 0.0
	add_child(ex_flare)

func _update_exit(t: float) -> void:
	if ex_on:
		var k := 0.8 + 0.2 * sin(t * 23.0) * sin(t * 7.0)
		ex_flare.position = Vector3(exit.x, 0.6, exit.z)
		ex_flare.light_energy = 2.4 * k * World.RANGE_FIT.z
		world.set_dyn_halo(0, Vector3(exit.x, 0.5, exit.z), Color(1.6 * k, 0.3 * k, 0.15 * k), 5.5)

# ---------------------------------------------------------------- car alarms
func _trigger_alarm(c: Dictionary) -> void:
	c.alarm_t = 14.0
	c.cd = 60.0
	c.call_t = 0.0
	sfx.release(c.voice)
	c.voice = sfx.hold("alarm_loop")
	buzz(100)
	if not alarm_told:
		alarm_told = true
		hud.toast("CAR ALARM", "It will come to the noise. Get clear, or use it to pull it away from her.", 6.0)
	else:
		hud.sub("SOUND", "(car alarm)", 2.0)

func _car_alarms(dt: float) -> void:
	for c in alarms:
		if c.cd > 0.0:
			c.cd -= dt
		if c.alarm_t <= 0.0:
			continue
		c.alarm_t -= dt
		c.call_t -= dt
		if c.call_t <= 0.0:
			c.call_t = 3.0
			mon.hear(c.x + U.rnd(-2.0, 2.0), c.z + U.rnd(-2.0, 2.0))
		if c.voice >= 0:
			var pp := pos_params(c.x, 1.0, c.z, 26.0)
			var env := minf(1.0, c.alarm_t / 0.6)
			sfx.hold_update(c.voice, "alarm_loop", maxf(0.0001, pp.vol * 0.22 * env), clampf(pp.pan, -1.0, 1.0), minf(3000.0, pp.lp))
			if c.alarm_t <= 0.0:
				sfx.release(c.voice)
				c.voice = -1
	if (pl.move != "run" and pl.move != "sprint") or pl.pos.y < -1.0 or pl.hidden:
		return
	for c in alarms:
		if c.cd > 0.0:
			continue
		var dx := maxf(absf(pl.pos.x - c.x) - c.hx, 0.0)
		var dz := maxf(absf(pl.pos.z - c.z) - c.hz, 0.0)
		if dx * dx + dz * dz < 0.16:
			_trigger_alarm(c)
			break

# ---------------------------------------------------------------- director
func _director(dt: float) -> void:
	var P := pl
	var M := mon
	var dPM := U.hyp(P.pos.x - M.pos.x, P.pos.z - M.pos.z)
	if dPM < 45.0:
		dir.near_t += dt
		dir.far_t = 0.0
	elif dPM > 85.0:
		dir.far_t += dt
		dir.near_t = maxf(0.0, dir.near_t - dt)
	else:
		dir.near_t = maxf(0.0, dir.near_t - dt * 0.5)
		dir.far_t = maxf(0.0, dir.far_t - dt * 0.5)
	# is the monster on screen?
	var mp := Vector3(M.pos.x, 3.5, M.pos.z)
	var cp := cam.global_position
	M.visible = cam.is_position_in_frustum(mp) and dPM < 85.0 and P.pos.y > -2.0 and col.los_clear(cp.x, cp.z, M.pos.x, M.pos.z, 3.0)
	# crossing encounter: it walks across the far end of the street ahead
	if time > dir.next_cross and M.state == "PATROL" and not M.crossing and dPM > 70.0 and not M.visible and P.pos.y > -2.0 and world.in_interior(P.pos.x, P.pos.z) == null:
		dir.next_cross = time + 8.0
		var fx := sin(P.cam_yaw)
		var fz := cos(P.cam_yaw)
		var cands := []
		for i in 25:
			var I: Dictionary = nodes[i]
			var dx: float = I.x - P.pos.x
			var dz: float = I.z - P.pos.z
			var d := U.hyp(dx, dz)
			if d < 32.0 or d > 80.0 or (dx * fx + dz * fz) / d < 0.8 or not col.los_clear(P.pos.x, P.pos.z, I.x, I.z, 3.0):
				continue
			for a in I.n:
				for b in I.n:
					if a == b:
						continue
					var A: Dictionary = nodes[a]
					var B: Dictionary = nodes[b]
					var ax: float = B.x - A.x
					var az: float = B.z - A.z
					var al := U.hyp(ax, az)
					if absf((ax * dx + az * dz) / (al * d)) > 0.3:
						continue
					if (A.x - I.x) * (B.x - I.x) + (A.z - I.z) * (B.z - I.z) >= 0.0:
						continue
					if col.los_clear(P.pos.x, P.pos.z, A.x, A.z, 3.0) or U.hyp(A.x - P.pos.x, A.z - P.pos.z) < 40.0:
						continue
					cands.append([i, int(a), int(b)])
		if cands.size():
			var c: Array = cands[randi() % cands.size()]
			var A: Dictionary = nodes[c[1]]
			var I: Dictionary = nodes[c[0]]
			var B: Dictionary = nodes[c[2]]
			M.pos = Vector3(A.x, 0.0, A.z)
			M.yaw = atan2(I.x - A.x, I.z - A.z)
			M.crossing = true
			M.path = [Vector2(I.x, I.z), Vector2(B.x, B.z)]
			M.cur = c[2]
			M.prev = c[0]
			M.pause_t = 0.0
			M.speed = 1.5
			dir.crossing = {i = c[0], flashed = false}
			dir.next_cross = time + U.rnd(85.0, 130.0)
	if dir.crossing.size():
		var I: Dictionary = nodes[dir.crossing.i]
		if not dir.crossing.flashed and U.hyp(M.pos.x - I.x, M.pos.z - I.z) < 7.0 and M.visible:
			dir.crossing.flashed = true
			if randf() < 0.8:
				lightning(1.0)
	# phantom footsteps behind you
	if time > dir.next_phantom and dPM > 90.0 and M.state == "PATROL" and P.pos.y > -2.0:
		dir.next_phantom = time + U.rnd(75.0, 120.0)
		var bx := P.pos.x - sin(P.cam_yaw) * 22.0
		var bz := P.pos.z - cos(P.cam_yaw) * 22.0
		var pp := pos_params(bx, 0.0, bz, 22.0)
		for k in 4:
			after(k * 0.62, _phantom_step.bind(pp.pan + U.rnd(-0.1, 0.1)))
	# lightning and sirens
	if time > dir.next_lightning:
		dir.next_lightning = time + (U.rnd(16.0, 38.0) if wx_i > 0.85 else U.rnd(30.0, 65.0))
		if wx_i > 0.5:
			lightning(U.rnd(0.5, 1.0) * (0.5 + 0.5 * wx_i))
	if time > dir.next_siren:
		dir.next_siren = time + U.rnd(35.0, 70.0)
		sfx.play("siren", 0.035, U.rnd(-0.9, 0.9))
	# it vocalises now and then
	M.vocal_t -= dt
	if M.vocal_t <= 0.0:
		M.vocal_t = U.rnd(9.0, 18.0)
		if dPM < 70.0:
			M.vocal(0.8)
	# escape: it hunts
	if phase == "escape":
		dir.esc_t -= dt
		if dir.esc_t <= 0.0:
			dir.esc_t = U.rnd(24.0, 34.0)
			if M.state == "PATROL" and dPM > 30.0:
				M.hear(P.pos.x + U.rnd(-22.0, 22.0), P.pos.z + U.rnd(-22.0, 22.0))
	# crying clue and the quiet near her hiding place
	if phase == "explore":
		var under: bool = loc.y < -2.0
		var dL := U.hyp(P.pos.x - loc.spot[0], P.pos.z - loc.spot[1])
		var in_range := dL < 40.0
		if under:
			in_range = dL < 60.0 if P.pos.y < -2.0 else U.hyp(P.pos.x - loc.ent[0], P.pos.z - loc.ent[1]) < 30.0
		cry_t -= dt
		if in_range and cry_t <= 0.0:
			cry_t = U.rnd(7.0, 11.0)
			var above := under and P.pos.y > -2.0
			var sx: float = loc.ent[0] if above else loc.spot[0]
			var sz: float = loc.ent[1] if above else loc.spot[1]
			var pp := pos_params(sx, loc.y + 0.6, sz, 12.0)
			sfx.play("sob", maxf(0.05, pp.vol * 0.8), pp.pan, minf(pp.lp, 1500.0))
			var cc: Dictionary = clues.filter(func(c): return c.type == "cry")[0]
			if not cc.found:
				var dw := U.dir_word(loc.spot[0] - P.pos.x, loc.spot[1] - P.pos.z)
				cc.text = String(data.txt[loc.id].cry).replace("{d}", dw)
				cc.x = P.pos.x
				cc.z = P.pos.z
				find_clue(cc)
			else:
				hud.sub("SOUND", "(faint crying)", 2.0)
		var same_lvl: bool = absf(P.pos.y - loc.y) < 2.0
		var q := 1.0 if same_lvl and dL < 15.0 else 0.0
		quiet = lerpf(quiet, q, minf(1.0, dt * 0.8))
		if q > 0.0 and not help_said and dL < 13.0:
			help_said = true
			hud.sub("A SMALL VOICE", "Help…", 3.2)
			var pp := pos_params(loc.spot[0], loc.y + 0.6, loc.spot[1], 6.0)
			sfx.play("sob", pp.vol, pp.pan, pp.lp)
	else:
		quiet = lerpf(quiet, 0.0, minf(1.0, dt * 0.5))
	_lightning_playback(dt)

func _phantom_step(pan: float) -> void:
	sfx.play("thud", 0.5, pan, 420.0)

func _lightning_playback(dt: float) -> void:
	if dir.flash_seq.size():
		dir.flash_t += dt
		var v := 0.0
		for k in dir.flash_seq.size() - 1:
			var a: Array = dir.flash_seq[k]
			var b: Array = dir.flash_seq[k + 1]
			if dir.flash_t >= a[0] and dir.flash_t < b[0]:
				v = lerpf(a[1], b[1], (dir.flash_t - a[0]) / (b[0] - a[0]))
				break
		if dir.flash_t > 0.5:
			dir.flash_seq = []
			v = 0.0
		world.flash = v
	if dir.thunder_at > 0.0 and time > dir.thunder_at:
		dir.thunder_at = -1.0
		sfx.play("thunder", dir.thunder_vol, U.rnd(-0.5, 0.5))

# ---------------------------------------------------------------- sound mix
func _audio_mix(dt: float) -> void:
	var under := pl.pos.y < -2.0
	var inside: bool = world.in_interior(pl.pos.x, pl.pos.z) != null
	if phase == "menu":
		under = cam.global_position.y < -2.0
		inside = false
	var q := 1.0 - quiet * 0.8
	var rv: float = q * settings.rain / 100.0 * pow(wx_i, 0.8)
	sfx.loop_to("rain_hiss_loop", (0.03 if under else 0.05 if inside else 0.085) * rv, 0.6, 350.0 if under else 1000.0 if inside else 3000.0 + 1600.0 * wx_i)
	sfx.loop_to("rain_body_loop", (0.06 if under else 0.13) * rv, 0.6, 250.0 if under else 650.0 if inside else 2200.0)
	sfx.loop_to("wind_loop", (0.03 if under else 0.08 + 0.06 * maxf(0.0, sin(time * 0.13))) * q, 1.0)
	var playing := phase == "explore" or phase == "escape"
	var dPM := U.hyp(pl.pos.x - mon.pos.x, pl.pos.z - mon.pos.z)
	var ten := maxf(1.0 if mon.state == "CHASE" else 0.0, clampf(1.0 - dPM / 55.0, 0.0, 1.0)) if playing else 0.0
	sfx.loop_to("drone_loop", ten * 0.16, 0.8 if playing else 0.5)
	heart_t -= dt
	var close := 1.0 if mon.state == "CHASE" else clampf(1.0 - (dPM - 6.0) / 24.0, 0.0, 1.0)
	if close > 0.05 and playing and heart_t <= 0.0:
		heart_t = lerpf(1.1, 0.4, close)
		sfx.play("heart", 0.2 + 0.4 * close)
		if close > 0.55:
			buzz(28)
	hud.danger = (0.55 + 0.25 * sin(time * 8.0) if mon.state == "CHASE" else close * 0.35) if playing else 0.0

# ---------------------------------------------------------------- main loop
func _process(raw: float) -> void:
	var dt := minf(raw, 0.05)
	clock += dt
	if not paused:
		_tick(dt, clock)
	_adapt(raw)
	if args.has("shot"):
		_shot_check()

func _tick(dt: float, t: float) -> void:
	var ref := pl.pos
	if phase == "menu":
		menu_t += dt
		_menu_cam(menu_t)
		mon.actor.visible = false
		child.actor.visible = false
		pl.actor.visible = false
		pl.light.light_energy = 0.0
		pl.beam.visible = false
		ref = cam.global_position
		_audio_mix(dt)
	else:
		mon.actor.visible = true
		child.actor.visible = true
		pl.actor.visible = true
		var playing := phase in ["explore", "escape", "dialog", "caught"]
		if playing:
			time += dt
			_run_timers()
			pl.update(dt)
			if phase == "explore" or phase == "escape":
				_car_alarms(dt)
			mon.update(dt)
			child.update(dt)
			if phase != "caught":
				_director(dt)
			pl.update_camera(dt)
			pl.update_flash(dt, t)
			_audio_mix(dt)
			hud.update_play(dt)
			_update_glints(t)
			if phase == "escape":
				var dx := U.hyp(pl.pos.x - exit.x, pl.pos.z - exit.z)
				if dx < 7.0:
					var dc := U.hyp(child.pos.x - pl.pos.x, child.pos.z - pl.pos.z)
					if dc < 9.0 and child.state != "wait":
						win()
					elif time > nag_t:
						nag_t = time + 5.0
						hud.sub("YOU", "Not without her. Go back for her.", 3.0)
				escape_t -= dt
				if escape_t <= 0.0:
					escape_t = 0.5
					if hud.obj_title() == "ESCAPE THE CITY":
						update_escape_obj()
		if phase == "caught":
			end_t += dt
			hud.fade = clampf((end_t - 0.9) / 1.0, 0.0, 1.0)
			if end_t > 2.1:
				show_end(false)
		elif phase == "won":
			end_t += dt
			time += dt
			pl.update(dt)
			child.update(dt)
			pl.update_camera(dt)
			pl.update_flash(dt, t)
			_audio_mix(dt)
			hud.fade = clampf((end_t - 0.6) / 1.6, 0.0, 1.0)
			if end_t > 2.4:
				show_end(true)
		elif phase == "lost" or phase == "wonEnd":
			sfx.loop_to("drone_loop", 0.0, 0.5)
	# weather
	wx_t -= dt
	if wx_t <= 0.0:
		var s := wx_pick(wx_s)
		var was := wx_to
		wx_set(s)
		if (phase == "explore" or phase == "escape") and absf(float(s.i) - was) > 0.2:
			hud.toast("WEATHER", data.wxMsg[s.n], 5.0)
	wx_i += clampf(wx_to - wx_i, -dt / 14.0, dt / 14.0)
	_update_exit(t)
	world.update(dt, t, ref, wx_i, cam)
	pl.lit = world.lit_near

func _menu_cam(t: float) -> void:
	var z := 40.0 - fmod(t * 1.6, 150.0)
	cam.position = Vector3(-50.5 + sin(t * 0.1) * 1.2, 2.4 + sin(t * 0.3) * 0.1, z)
	cam.look_at(Vector3(-52.5, 3.2, z - 30.0))
	pl.cam_yaw = PI

## AUTO graphics: after a few seconds of play, step down if the frame rate is poor.
func _adapt(raw: float) -> void:
	if phase == "menu" or paused or low_q or settings.gfx != "auto" or args.has("noadapt"):
		return
	fps_acc += raw
	fps_n += 1
	fps_check += raw
	if fps_check > 5.0:
		var fps := fps_n / fps_acc
		fps_acc = 0.0
		fps_n = 0
		fps_check = 0.0
		if fps < 28.0:
			if not q1:
				q1 = true
			else:
				low_q = true
			apply_gfx()

# ---------------------------------------------------------------- testing
var _frames := 0
func _shot_check() -> void:
	_frames += 1
	if _frames == int(args.get("frames", "60")):
		if args.has("stats"):
			print("draw calls %d, primitives %d, objects %d" % [RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME), RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)])
		get_viewport().get_texture().get_image().save_png(String(args.shot))
		print("saved ", args.shot)
		get_tree().quit()
