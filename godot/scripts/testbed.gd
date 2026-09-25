## Test bed for checking the city and the characters without the game on top.
## Screenshot mode: godot --path godot -- --testbed --shot=out.png --cam=x,y,z --look=x,y,z [--weather=0.65] [--frames=20]
extends Node3D

var world: World
var cam: Camera3D
var args := {}
var frames := 0
var t := 0.0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and "=" in a:
			args[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
	if args.has("bare"):
		_bare_stage()
	else:
		world = World.new()
		world.name = "World"
		add_child(world)
	cam = Camera3D.new()
	cam.fov = 62.0
	cam.near = 0.1
	cam.far = 950.0
	cam.cull_mask = 0xFFFFF & ~World.REFL_LAYER
	add_child(cam)
	cam.current = true
	var p := _vec("cam", Vector3(-50.5, 2.4, 20.0))
	cam.position = p
	cam.look_at(_vec("look", Vector3(-52.5, 3.2, -10.0)))
	if args.has("chars"):
		_chars_test()
	if world == null:
		return
	world.setup_reflection()
	# test overrides: --env.glow_intensity=2 sets that Environment property, --hide=skyline,build hides meshes
	if args.has("hide"):
		for n in world.find_children("*", "GeometryInstance3D", true, false):
			for pre in String(args.hide).split(","):
				if String(n.name).begins_with(pre):
					(n as Node3D).visible = false
	for k in args:
		if String(k).begins_with("env."):
			world.env.set(String(k).substr(4), str_to_var(String(args[k])))
	# colour grade, grain and a touch of lens fringing, like the browser version
	var grade_layer := CanvasLayer.new()
	grade_layer.layer = -1
	add_child(grade_layer)
	var grade := ColorRect.new()
	grade.set_anchors_preset(Control.PRESET_FULL_RECT)
	grade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gm := ShaderMaterial.new()
	gm.shader = load("res://shaders/grade.gdshader")
	grade.material = gm
	grade_layer.add_child(grade)

var actors: Array[Actor] = []

## Test mode: the three characters side by side, --chars=speed (m/s), --crouch=0..1, --sad=0..1
func _chars_test() -> void:
	var at := _vec("at", Vector3(-51.0, 0.0, 14.0))
	var i := 0
	for k in String(args.get("only", "player,child,beast")).split(","):
		var a := Actor.new(k)
		add_child(a)
		a.position = at + Vector3(-2.0 + 2.2 * i, 0.0, 0.0)
		a.position.y = world.ground_at(a.position.x, a.position.z, 1.0) if world else 0.0
		a.rotation.y = float(args.get("yaw", "0.6"))
		actors.append(a)
		i += 1

## Test mode: a plain lit stage instead of the city, for checking characters.
func _bare_stage() -> void:
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.35, 0.38, 0.42)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.65)
	we.environment = e
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.5, 0)
	add_child(sun)
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	floor.mesh = pm
	add_child(floor)

func _vec(key: String, def: Vector3) -> Vector3:
	if not args.has(key):
		return def
	var v := String(args[key]).split(",")
	return Vector3(float(v[0]), float(v[1]), float(v[2]))

func _process(dt: float) -> void:
	t += dt
	if world:
		world.update(dt, t, cam.global_position, float(args.get("weather", "0.65")), cam)
	frames += 1
	for a in actors:
		if args.has("clip"):
			a.tree.active = false
			a.anim.play(String(args.clip))
			a.anim.seek(float(args.get("seek", "0.3")), true)
			a.anim.pause()
			continue
		if args.has("rest"):
			a.tree.active = false
			a.anim.stop()
			a.skel.reset_bone_poses()
			continue
		a.loco(float(args.chars), float(args.get("crouch", "0")), float(args.get("sad", "0")))
	if args.has("shot") and frames == int(args.get("frames", "20")):
		var img := get_viewport().get_texture().get_image()
		img.save_png(String(args.shot))
		if args.has("reflshot"):
			world.refl_vp.get_texture().get_image().save_png(String(args.reflshot))
		print("saved ", args.shot)
		get_tree().quit()
