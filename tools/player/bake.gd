## Bakes the player character: the Microsoft Rocketbox man "Male_Adult_07" (MIT licence) and his
## motion-capture clips, read straight from a checkout of github.com/microsoft/Microsoft-Rocketbox.
##   godot --headless --path tools/player -s res://bake.gd -- <rocketbox checkout>
## Writes godot/assets/player/man.scn: the skeleton, the skinned mesh (7.6k triangles, materials are
## set by the game) and an AnimationPlayer holding every clip in place, with the character's travel
## taken out of the hips. What the game needs to move him the way the capture did is in the scene's
## "clips" metadata:
## - cycle clips (walks, jog, run, sprint, crouch walk): one gait cycle stretched to exactly 1 s that
##   starts as the left heel lands, so any two blend in step; with the real speed and stride length
## - once clips (starts, stops, turns, crouching down and up): the travel and turn per frame (root
##   motion), plus where they join a cycle
## - loop clips (idles): as captured
extends SceneTree

const AVATAR := "Assets/Avatars/Adults/Male_Adult_07/Export/Male_Adult_07.fbx"
const ANIMS := "Assets/Animations/all_animations_max_motextr_%s/%s.max.fbx"
const OUT := "../../godot/assets/player/man.scn"
const FPS := 30.0
# the crouch walk made from the walk (see crouch_walk())
const CROUCH_DROP := 0.24
const CROUCH_STRIDE := 0.85
const CROUCH_LEAN := 0.75

# name: [capture folder (static = in place, xy = travels, xyz = travels and turns), clip, kind, options]
const CLIPS := {
	"idle": ["static", "m_idle_neutral_01", "loop"],
	"walk_slow": ["xy", "m_walk_slow_01", "cycle"],
	"walk": ["xy", "m_walk_neutral", "cycle"],
	"walk_fast": ["xy", "m_walk_fast_02", "cycle"],
	"jog": ["xy", "m_run_slow_02", "cycle"],
	"run": ["xy", "m_run_neutral", "cycle"],
	"sprint": ["xy", "m_run_fast_01", "cycle"],
	"walk_start": ["xy", "m_walk_start", "once", {"to": "walk"}],
	"run_start": ["xy", "m_run_start", "once", {"to": "run"}],
	"walk_stop": ["xy", "m_walk_stop", "once", {"from": "walk"}],
	"run_stop": ["xy", "m_run_stop", "once", {"from": "run"}],
	"turn_l90": ["xyz", "m_turn_left_90", "once"],
	"turn_r90": ["xyz", "m_turn_right_90", "once"],
	"turn_l180": ["xyz", "m_turn_left_180", "once"],
	"turn_r180": ["xyz", "m_turn_right_180", "once"],
	"turn_l60_walk": ["xyz", "m_turn_left_60_to_walk", "once", {"to": "walk"}],
	"turn_r60_walk": ["xyz", "m_turn_right_60_to_walk", "once", {"to": "walk"}],
	"turn_l120_walk": ["xyz", "m_turn_left_120_to_walk", "once", {"to": "walk"}],
	"turn_r120_walk": ["xyz", "m_turn_right_120_to_walk", "once", {"to": "walk"}],
	"turn_l180_walk": ["xyz", "m_turn_left_180_to_walk", "once", {"to": "walk"}],
	"turn_r180_walk": ["xyz", "m_turn_right_180_to_walk", "once", {"to": "walk"}],
	"crouch_in": ["xy", "m_crouch_in", "once", {"trim": true}],
	"crouch_idle": ["static", "m_crouch_idle", "loop"],
	"crouch_out": ["xy", "m_crouch_out", "once", {"trim": true}],
}

var rb := ""
var sk: Skeleton3D
var nb := 0
var rest: Array[Transform3D] = []
var lfoot := -1
var rfoot := -1

## A captured clip sampled every frame: per frame the local rotation of every bone (rest where the
## clip has no track), the hips' position, and the root (travel x, z and turn) under the body.
class Clip:
	var name: String
	var kind: String
	var length: float
	var rot: Array = []       # [frame] -> Array[Quaternion] per bone
	var hips: Array = []      # [frame] -> Vector3 (Bip01, in place)
	var root: Array = []      # [frame] -> Vector3(x, z, yaw)
	var tracked: Array = []   # bone indices the capture animates

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <rocketbox checkout>")
		quit(1)
		return
	rb = args[0]
	var av := load_fbx(rb.path_join(AVATAR))
	sk = av.find_children("*", "Skeleton3D", true, false)[0]
	nb = sk.get_bone_count()
	for b in nb:
		assert(sk.get_bone_parent(b) < b)
		rest.append(sk.get_bone_rest(b))
	lfoot = sk.find_bone("Bip01 L Foot")
	rfoot = sk.find_bone("Bip01 R Foot")
	var clips := {}
	for name in CLIPS:
		var c: Array = CLIPS[name]
		clips[name] = read_clip(name, c[0], c[1], c[2], c[3] if c.size() > 3 else {})
	var meta := {}
	var lib := AnimationLibrary.new()
	for name in clips:
		var c: Clip = clips[name]
		var opt: Dictionary = CLIPS[name][3] if CLIPS[name].size() > 3 else {}
		var m := {"kind": c.kind, "len": c.length}
		if c.kind == "cycle":
			m.merge(make_cycle(c))
		elif c.kind == "loop":
			seal_loop(c)
		if c.kind == "once":
			var r := PackedFloat32Array()
			for v in c.root:
				r.append_array([v.x, v.y, v.z])
			m.root = r
		meta[name] = m
	clips.crouch_walk = crouch_walk(clips.walk)
	meta.crouch_walk = {"kind": "cycle", "len": 1.0, "speed": meta.walk.speed * CROUCH_STRIDE, "stride": meta.walk.stride * CROUCH_STRIDE, "cycle": meta.walk.cycle, "r_phase": meta.walk.r_phase}
	# where the once clips meet the cycles (after the cycles are final)
	for name in clips:
		var c: Clip = clips[name]
		var opt: Dictionary = CLIPS[name][3] if CLIPS.has(name) and CLIPS[name].size() > 3 else {}
		if opt.has("to"):
			var cyc: Clip = clips[opt.to]
			meta[name].to = opt.to
			meta[name].to_phase = best_phase(cyc, features(c, c.rot.size() - 1))
			# its speed as it ends: a straight line through the last third of a second
			var k := c.root.size() - 1
			var a: Vector3 = c.root[k - 10]
			var b: Vector3 = c.root[k]
			meta[name].to_speed = Vector2(b.x - a.x, b.y - a.y).length() / (10.0 / FPS)
		if opt.has("from"):
			var cyc: Clip = clips[opt.from]
			var entry := PackedFloat32Array()
			var last := int(c.rot.size() * 0.45)
			for i in 24:
				var f := cycle_features(cyc, i / 24.0)
				var best := 0
				var bd := INF
				for k in last:
					var d := dist(f, features(c, k))
					if d < bd:
						bd = d
						best = k
				entry.append(best / FPS)
			meta[name].from = opt.from
			meta[name].entry = entry
	for name in clips:
		lib.add_animation(name, to_animation(clips[name]))
		var m: Dictionary = meta[name]
		print("%-15s %-5s %5.2fs  %s" % [name, m.kind, m.len, str({"speed": snappedf(m.get("speed", 0.0), 0.01), "stride": snappedf(m.get("stride", 0.0), 0.01), "r_phase": snappedf(m.get("r_phase", 0.0), 0.01), "to_phase": snappedf(m.get("to_phase", -1.0), 0.01), "to_speed": snappedf(m.get("to_speed", -1.0), 0.01), "entry": m.get("entry", [])})])
	save_scene(av, lib, meta)
	quit()

func load_fbx(path: String) -> Node:
	var doc := FBXDocument.new()
	var st := FBXState.new()
	var err := doc.append_from_file(path, st)
	assert(err == OK, "can't read " + path)
	return doc.generate_scene(st)

func find_track(an: Animation, path: String, type: int) -> int:
	for t in an.get_track_count():
		if str(an.track_get_path(t)) == path and an.track_get_type(t) == type:
			return t
	return -1

func read_clip(name: String, folder: String, file: String, kind: String, opt: Dictionary) -> Clip:
	var sc := load_fbx(rb.path_join(ANIMS % [folder, file]))
	var ap: AnimationPlayer = sc.find_children("*", "AnimationPlayer", true, false)[0]
	var an := ap.get_animation(ap.get_animation_list()[0])
	var c := Clip.new()
	c.name = name
	c.kind = kind
	var n := int(round(an.length * FPS))
	var rt: Array[int] = []
	for b in nb:
		var t := find_track(an, "Skeleton3D:" + sk.get_bone_name(b), Animation.TYPE_ROTATION_3D)
		rt.append(t)
		if t >= 0:
			c.tracked.append(b)
	var hp := find_track(an, "Skeleton3D:Bip01", Animation.TYPE_POSITION_3D)
	var mp := find_track(an, "MotionExtractionHelper", Animation.TYPE_POSITION_3D)
	var mr := find_track(an, "MotionExtractionHelper", Animation.TYPE_ROTATION_3D)
	var raw_hips: Array[Vector3] = []
	var travel: Array[Vector2] = []
	var turn: Array[float] = []
	for k in n + 1:
		var t := minf(k / FPS, an.length)
		var q: Array[Quaternion] = []
		for b in nb:
			q.append(an.rotation_track_interpolate(rt[b], t) if rt[b] >= 0 else rest[b].basis.get_rotation_quaternion())
		c.rot.append(q)
		raw_hips.append(an.position_track_interpolate(hp, t) if hp >= 0 else rest[0].origin)
		var m := an.position_track_interpolate(mp, t) if mp >= 0 else Vector3.ZERO
		travel.append(Vector2(m.x, m.z))
		# the helper's turn: its euler y is -90 degrees when the character faces +z
		var y := (an.rotation_track_interpolate(mr, t).get_euler().y + PI * 0.5) if mr >= 0 else 0.0
		if k > 0:
			y = turn[k - 1] + angle_difference(turn[k - 1], y)
		turn.append(y)
	# the root under the body: a straight line for cycles (the sway stays in the hips), the hips'
	# own travel for everything else
	for k in n + 1:
		var p: Vector2
		if kind == "cycle":
			p = travel[0].lerp(travel[n], float(k) / n)
		elif kind == "loop":
			p = Vector2.ZERO
		else:
			p = travel[k]
		var y0 := turn[k] - turn[0] if kind == "once" else 0.0
		c.root.append(Vector3(p.x - travel[0].x, p.y - travel[0].y, y0))
	# in place: the hips relative to the root
	for k in n + 1:
		var r: Vector3 = c.root[k]
		var inv := Transform3D(Basis(Vector3.UP, r.z), Vector3(r.x, 0.0, r.y)).affine_inverse()
		var h := raw_hips[k]
		var hq: Quaternion = c.rot[k][0]
		var local := inv * Transform3D(Basis(hq), h - Vector3(travel[0].x, 0.0, travel[0].y))
		c.hips.append(local.origin)
		c.rot[k][0] = local.basis.get_rotation_quaternion()
	c.length = n / FPS
	if opt.get("trim", false):
		trim(c)
	return c

## Cuts the long still start and end off a crouch clip (they are 4.5 s, the move itself is ~1.5 s).
func trim(c: Clip) -> void:
	var n := c.hips.size() - 1
	var h0: float = c.hips[0].y
	var h1: float = c.hips[n].y
	var a := 0
	while a < n and absf(c.hips[a].y - h0) < 0.015:
		a += 1
	var b := n
	while b > 0 and absf(c.hips[b].y - h1) < 0.015:
		b -= 1
	a = maxi(0, a - int(FPS * 0.35))
	b = mini(n, b + int(FPS * 0.35))
	c.rot = c.rot.slice(a, b + 1)
	c.hips = c.hips.slice(a, b + 1)
	var r0: Vector3 = c.root[a]
	var root: Array = []
	for k in range(a, b + 1):
		var r: Vector3 = c.root[k]
		var d := Vector2(r.x - r0.x, r.y - r0.y).rotated(r0.z)
		root.append(Vector3(d.x, d.y, r.z - r0.z))
	c.root = root
	c.length = (b - a) / FPS

## Global transforms of every bone for one frame of a clip (in place, root at the origin).
func pose(c: Clip, k: int) -> Array[Transform3D]:
	var g: Array[Transform3D] = []
	for b in nb:
		var l := Transform3D(Basis(c.rot[k][b]), c.hips[k] if b == 0 else rest[b].origin)
		g.append(g[sk.get_bone_parent(b)] * l if b > 0 else l)
	return g

## Makes the end of a loop meet its start: the difference is spread over the whole clip.
func seal_loop(c: Clip) -> void:
	var n := c.rot.size() - 1
	var fix: Array[Quaternion] = []
	for b in nb:
		fix.append((c.rot[0][b] * c.rot[n][b].inverse()).normalized())
	var dh: Vector3 = c.hips[0] - c.hips[n]
	for k in n + 1:
		var w := float(k) / n
		for b in nb:
			c.rot[k][b] = (Quaternion.IDENTITY.slerp(fix[b], w) * c.rot[k][b]).normalized()
		c.hips[k] += dh * w

## One gait cycle: sealed, restarted at the left heel strike and stretched to 1 s.
func make_cycle(c: Clip) -> Dictionary:
	var n := c.rot.size() - 1
	var travel: Vector3 = c.root[n]
	var stride := Vector2(travel.x, travel.y).length()
	var cycle := c.length
	seal_loop(c)
	# heel strike = the foot furthest ahead of the hips
	var zl: Array[float] = []
	var zr: Array[float] = []
	var fwd := Vector3(travel.x, 0.0, travel.y).normalized()
	for k in n:
		var g := pose(c, k)
		zl.append((g[lfoot].origin - g[0].origin).dot(fwd))
		zr.append((g[rfoot].origin - g[0].origin).dot(fwd))
	var tl := peak(zl)
	var tr := peak(zr)
	var rot: Array = []
	var hips: Array = []
	for j in n + 1:
		var t := fposmod(tl + float(j) / n * n, n)
		var k0 := int(floor(t)) % n
		var k1 := (k0 + 1) % n
		var w: float = t - floor(t)
		var q: Array[Quaternion] = []
		for b in nb:
			q.append((c.rot[k0][b] as Quaternion).slerp(c.rot[k1][b], w))
		rot.append(q)
		hips.append((c.hips[k0] as Vector3).lerp(c.hips[k1], w))
	c.rot = rot
	c.hips = hips
	c.length = 1.0
	c.root = []
	return {"speed": stride / cycle, "stride": stride, "cycle": cycle, "r_phase": fposmod(tr - tl, n) / n}

## No crouch walk was captured, so one is made from the walk: the hips go down and back, the back
## bends forward with the head held up to look ahead, the arms swing less, and each leg is solved
## again (two-bone IK) so the foot follows the walk's own foot path, a little shorter, at the same
## angle. The timing, the weight shifts and the rhythm stay the captured walk's.
func crouch_walk(src: Clip) -> Clip:
	var c := Clip.new()
	c.name = "crouch_walk"
	c.kind = "cycle"
	c.length = 1.0
	c.tracked = src.tracked.duplicate()
	var bone := func(s: String) -> int: return sk.find_bone("Bip01 " + s)
	var lean := {bone.call("Spine"): CROUCH_LEAN * 0.3, bone.call("Spine1"): CROUCH_LEAN * 0.4, bone.call("Spine2"): CROUCH_LEAN * 0.3, bone.call("Neck"): -CROUCH_LEAN * 0.35, bone.call("Head"): -CROUCH_LEAN * 0.4}
	var arms := [bone.call("L UpperArm"), bone.call("R UpperArm")]
	var thighs := {bone.call("L Thigh"): lfoot, bone.call("R Thigh"): rfoot}
	var calves := {bone.call("L Calf"): lfoot, bone.call("R Calf"): rfoot}
	var n := src.rot.size()
	var mean := {}
	for b in arms:
		var acc := Quaternion(0, 0, 0, 0)
		for k in n:
			var q: Quaternion = src.rot[k][b]
			if acc.dot(q) < 0.0:
				q = -q
			acc += q
		mean[b] = acc.normalized()
	for k in n:
		var g0 := pose(src, k)
		var hips: Vector3 = src.hips[k] + Vector3(0.0, -CROUCH_DROP, -0.07)
		var loc: Array[Quaternion] = []
		loc.assign(src.rot[k])
		var g: Array[Transform3D] = []
		var knee := {}
		for b in nb:
			var par := sk.get_bone_parent(b)
			var pg := g[par] if par >= 0 else Transform3D.IDENTITY
			if b in arms:
				loc[b] = loc[b].slerp(mean[b], 0.45)
			var gb := pg * Transform3D(Basis(loc[b]), hips if b == 0 else rest[b].origin)
			if lean.has(b):
				gb.basis = Basis(Vector3.RIGHT, lean[b]) * gb.basis
			if thighs.has(b):
				# the knee: where the two leg bones meet on the way to the ankle, bending the way
				# the captured knee bends, a little more forward
				var foot: int = thighs[b]
				var calf := sk.get_bone_parent(foot)
				var a0: Vector3 = g0[foot].origin
				# a little more lift in the swing: with bent knees the toes would skim the ground
				var ankle := Vector3(a0.x, a0.y + clampf((a0.y - 0.115) * 0.5, 0.0, 0.05), a0.z * CROUCH_STRIDE)
				var l1 := rest[calf].origin.length()
				var l2 := rest[foot].origin.length()
				var h := gb.origin
				var d := clampf(h.distance_to(ankle), absf(l1 - l2) + 0.01, l1 + l2 - 0.005)
				var u := (ankle - h).normalized()
				var pole: Vector3 = (g0[calf].origin - (g0[b].origin + g0[foot].origin) * 0.5).normalized() + Vector3(0, 0, 0.8)
				pole = (pole - u * pole.dot(u)).normalized()
				var along := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
				var kp := h + u * along + pole * sqrt(maxf(l1 * l1 - along * along, 0.0))
				knee[foot] = [kp, ankle]
				gb.basis = Basis(Quaternion((gb.basis * rest[calf].origin).normalized(), (kp - h).normalized())) * gb.basis
			elif calves.has(b):
				var ka: Array = knee[calves[b]]
				gb.basis = Basis(Quaternion((gb.basis * rest[calves[b]].origin).normalized(), (ka[1] - gb.origin).normalized())) * gb.basis
			elif b == lfoot or b == rfoot:
				gb.basis = g0[b].basis
			loc[b] = (pg.basis.inverse() * gb.basis).get_rotation_quaternion()
			g.append(gb)
		c.rot.append(loc)
		c.hips.append(hips)
	return c

## Frame (with sub-frame precision) where a cyclic series peaks.
func peak(s: Array[float]) -> float:
	var n := s.size()
	var k := 0
	for i in n:
		if s[i] > s[k]:
			k = i
	var a := s[(k - 1 + n) % n]
	var b := s[k]
	var d := s[(k + 1) % n]
	var den := a - 2.0 * b + d
	return float(k) + (0.5 * (a - d) / den if absf(den) > 1e-6 else 0.0)

## What a pose looks like for matching one clip to another: where the feet are and where they go.
func features(c: Clip, k: int) -> PackedFloat32Array:
	var k2 := mini(k + 1, c.rot.size() - 1)
	var k1 := k2 - 1
	var g1 := pose(c, k1)
	var g2 := pose(c, k2)
	var dt := (1.0 / FPS) * (1.0 if c.kind != "cycle" else 1.0)
	return feat(g1, g2, dt)

func cycle_features(c: Clip, phase: float) -> PackedFloat32Array:
	# a cycle is stretched to 1 s: its frames are phase * (frames), and a frame lasts cycle/frames
	var n := c.rot.size() - 1
	var k := int(round(phase * n)) % n
	return feat(pose(c, k), pose(c, (k + 1) % n), 1.0 / FPS)

func feat(g1: Array[Transform3D], g2: Array[Transform3D], dt: float) -> PackedFloat32Array:
	var f := PackedFloat32Array()
	for b in [lfoot, rfoot]:
		var p: Vector3 = g2[b].origin - g2[0].origin * Vector3(1, 0, 1)
		var v: Vector3 = (g2[b].origin - g1[b].origin) / dt
		f.append_array([p.x, p.y, p.z, v.x * 0.15, v.y * 0.15, v.z * 0.15])
	return f

func dist(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var s := 0.0
	for i in a.size():
		s += (a[i] - b[i]) * (a[i] - b[i])
	return s

func best_phase(cyc: Clip, f: PackedFloat32Array) -> float:
	var best := 0.0
	var bd := INF
	for i in 64:
		var d := dist(f, cycle_features(cyc, i / 64.0))
		if d < bd:
			bd = d
			best = i / 64.0
	return best

func to_animation(c: Clip) -> Animation:
	var an := Animation.new()
	var n := c.rot.size() - 1
	an.length = c.length
	an.loop_mode = Animation.LOOP_NONE if c.kind == "once" else Animation.LOOP_LINEAR
	var dt := c.length / n
	var t := an.add_track(Animation.TYPE_POSITION_3D)
	an.track_set_path(t, "Skeleton3D:" + sk.get_bone_name(0))
	for k in n + 1:
		an.position_track_insert_key(t, k * dt, c.hips[k])
	for b in c.tracked:
		# bones the capture leaves at rest (face, eyes) get no track at all
		var r0 := rest[b].basis.get_rotation_quaternion()
		var moves := false
		var still := true
		for k in n + 1:
			var q: Quaternion = c.rot[k][b]
			if absf(q.dot(r0)) < 0.99999:
				moves = true
			if absf(q.dot(c.rot[0][b])) < 0.99999:
				still = false
		if not moves:
			continue
		t = an.add_track(Animation.TYPE_ROTATION_3D)
		an.track_set_path(t, "Skeleton3D:" + sk.get_bone_name(b))
		if still:
			an.rotation_track_insert_key(t, 0.0, c.rot[0][b])
			continue
		for k in n + 1:
			an.rotation_track_insert_key(t, k * dt, c.rot[k][b])
	return an

func save_scene(av: Node, lib: AnimationLibrary, meta: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Man"
	var s := sk.duplicate() as Skeleton3D
	for ch in s.get_children():
		s.remove_child(ch)
	s.name = "Skeleton3D"
	root.add_child(s)
	var mi: MeshInstance3D = av.find_children("*", "MeshInstance3D", true, false)[0].duplicate()
	mi.name = "Body"
	var mesh: ArrayMesh = mi.mesh
	for i in mesh.get_surface_count():
		mesh.surface_set_material(i, null)
	s.add_child(mi)
	mi.skeleton = NodePath("..")
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	root.add_child(ap)
	ap.add_animation_library("", lib)
	for n in [s, mi, ap]:
		n.owner = root
	root.set_meta("clips", meta)
	var ps := PackedScene.new()
	ps.pack(root)
	var out := ProjectSettings.globalize_path("res://").path_join(OUT).simplify_path()
	var err := ResourceSaver.save(ps, out, ResourceSaver.FLAG_COMPRESS)
	print("saved %s (%d KB) err=%d" % [out, FileAccess.get_file_as_bytes(out).size() / 1024, err])
