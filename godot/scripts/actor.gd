## A rigged character exported from the browser version (player, child or beast) with its walk cycle
## blended by speed: idle, walk and run, crouched versions, and the child's frightened idle.
class_name Actor
extends Node3D

var kind: String
var model: Node3D
var skel: Skeleton3D
var anim: AnimationPlayer
var tree: AnimationTree
var walk_speed := 1.45
var run_speed := 4.2
var has_crouch := false
var has_sad := false
var hook: PoseHook
var rest_rot: Array[Quaternion] = []   # each bone's rotation in the bind pose, character space

func _init(p_kind: String) -> void:
	kind = p_kind
	name = p_kind.capitalize()

func _ready() -> void:
	model = load("res://assets/baked/%s.glb" % kind).instantiate()
	add_child(model)
	skel = model.find_children("*", "Skeleton3D", true, false)[0]
	anim = model.find_children("*", "AnimationPlayer", true, false)[0]
	for a in anim.get_animation_list():
		anim.get_animation(a).loop_mode = Animation.LOOP_LINEAR
	has_crouch = anim.has_animation("crouch_idle")
	has_sad = anim.has_animation("sad_idle")
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).extra_cull_margin = 2.0
	_build_tree()
	for i in skel.get_bone_count():
		rest_rot.append(skel.get_bone_global_rest(i).basis.get_rotation_quaternion())
	hook = PoseHook.new()
	skel.add_child(hook)

## Called after the animation every frame, for pose tweaks (see PoseHook).
func set_pose_fn(fn: Callable) -> void:
	hook.fn = fn

func _anim_node(bt: AnimationNodeBlendTree, id: String, clip: String, ts: bool) -> String:
	var a := AnimationNodeAnimation.new()
	a.animation = clip
	bt.add_node(id, a)
	if not ts:
		return id
	var t := AnimationNodeTimeScale.new()
	bt.add_node(id + "_ts", t)
	bt.connect_node(id + "_ts", 0, id)
	return id + "_ts"

func _build_tree() -> void:
	var bt := AnimationNodeBlendTree.new()
	var idle := _anim_node(bt, "idle", "idle", false)
	var walk := _anim_node(bt, "walk", "walk", true)
	var run := _anim_node(bt, "run", "run", true)
	var loco := AnimationNodeBlend3.new()
	bt.add_node("loco", loco)
	bt.connect_node("loco", 0, idle)
	bt.connect_node("loco", 1, walk)
	bt.connect_node("loco", 2, run)
	var out := "loco"
	if has_crouch:
		var ci := _anim_node(bt, "cidle", "crouch_idle", false)
		var cw := _anim_node(bt, "cwalk", "crouch_walk", true)
		var cl := AnimationNodeBlend2.new()
		bt.add_node("cloco", cl)
		bt.connect_node("cloco", 0, ci)
		bt.connect_node("cloco", 1, cw)
		var cb := AnimationNodeBlend2.new()
		bt.add_node("crouch", cb)
		bt.connect_node("crouch", 0, out)
		bt.connect_node("crouch", 1, "cloco")
		out = "crouch"
	if has_sad:
		var si := _anim_node(bt, "sidle", "sad_idle", false)
		if anim.has_animation("crouch_sad"):
			var cs := _anim_node(bt, "csidle", "crouch_sad", false)
			var sc := AnimationNodeBlend2.new()
			bt.add_node("sadc", sc)
			bt.connect_node("sadc", 0, si)
			bt.connect_node("sadc", 1, cs)
			si = "sadc"
		var sb := AnimationNodeBlend2.new()
		bt.add_node("sad", sb)
		bt.connect_node("sad", 0, out)
		bt.connect_node("sad", 1, si)
		out = "sad"
	bt.connect_node("output", 0, out)
	tree = AnimationTree.new()
	tree.name = "AnimationTree"
	model.add_child(tree)
	tree.anim_player = tree.get_path_to(anim)
	tree.tree_root = bt
	tree.active = true

## Blend the walk cycle for a ground speed in m/s; crouch and sad are 0..1.
func loco(speed: float, crouch := 0.0, sad := 0.0) -> void:
	var ws := walk_speed
	var rs := run_speed
	var amount := -1.0
	var wr := 0.0
	if speed > 0.05:
		if speed < ws:
			amount = -1.0 + speed / ws
		else:
			wr = minf(1.0, (speed - ws) / (rs - ws))
			amount = wr
	tree.set("parameters/loco/blend_amount", amount)
	var walk_ts := maxf(0.6, speed / ws) if speed < ws else maxf(0.6, speed / ws * (1.0 - wr) + wr)
	tree.set("parameters/walk_ts/scale", walk_ts)
	tree.set("parameters/run_ts/scale", maxf(0.7, speed / rs))
	if has_crouch:
		tree.set("parameters/cloco/blend_amount", clampf(speed / ws, 0.0, 1.0))
		tree.set("parameters/cwalk_ts/scale", maxf(0.6, speed / ws))
		tree.set("parameters/crouch/blend_amount", crouch)
	if has_sad:
		tree.set("parameters/sad/blend_amount", sad)
		if anim.has_animation("crouch_sad"):
			tree.set("parameters/sadc/blend_amount", crouch)

## Turn a bone about an axis given in character space; its children follow (rigRotate in the browser version).
func rotate_bone(n: String, axis: Vector3, angle: float) -> void:
	var i := bone(n)
	if i < 0:
		return
	var g := skel.get_bone_global_pose(i)
	g.basis = Basis(axis.normalized(), angle) * g.basis
	skel.set_bone_global_pose(i, g)

## Point a bone like its bind pose turned so that -X runs along dir (character space), blended by w
## (rigAimDir in the browser version).
func aim_bone(n: String, dir: Vector3, w: float) -> void:
	var i := bone(n)
	if i < 0 or w <= 0.001:
		return
	var target := Quaternion(Vector3(-1, 0, 0), dir.normalized()) * rest_rot[i]
	var p := skel.get_bone_parent(i)
	var pq := skel.get_bone_global_pose(p).basis.get_rotation_quaternion() if p >= 0 else Quaternion()
	var local := (pq.inverse() * target).normalized()
	var cur := skel.get_bone_pose_rotation(i)
	skel.set_bone_pose_rotation(i, cur.slerp(local, w) if w < 1.0 else local)

func bone(n: String) -> int:
	return skel.find_bone("mixamorig" + n)

## World position of a bone.
func bone_pos(n: String) -> Vector3:
	return skel.global_transform * skel.get_bone_global_pose(bone(n)).origin

func find_node3d(n: String) -> Node3D:
	var list := model.find_children(n, "Node3D", true, false)
	return list[0] if list.size() else null
