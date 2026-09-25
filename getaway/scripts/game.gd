## Getaway: drag to steer through night traffic, the police right behind you. The car stays at z = 0
## and the street and traffic move past it. Speed builds up the longer you last; passing a car closely
## scores a bonus, and close calls in a row multiply it.
class_name Game
extends Node3D

enum { MENU, PLAY, CRASH, OVER }

const LANES := [-5.25, -1.75, 1.75, 5.25]
const ONCOMING := [true, true, false, false]      # the two left lanes come towards you
const LANE_SPEED := [15.0, 12.0, 9.0, 12.0]       # traffic speed in each lane (m/s)
const X_LIMIT := 6.1
const START_SPEED := 24.0                          # 86 km/h
const MAX_SPEED := 58.0                            # 209 km/h
const ACCEL := 0.3                                 # m/s gained every second
const SPAWN_Z := -230.0
const STEER_SPAN := 18.0                           # metres of steering for a drag across the whole screen
const PLAYER := {length = 4.3, width = 2.0}
const NEAR_GAP := 0.9                              # passing closer than this (m) is a close call
const SAVE := "user://getaway.cfg"
const PARKED := Vector3(0, -500, 500)
const COLOURS := [Color(0.01, 0.01, 0.012), Color(0.7, 0.7, 0.68), Color(0.35, 0.36, 0.38), Color(0.02, 0.05, 0.14),
	Color(0.2, 0.2, 0.21), Color(0.02, 0.07, 0.04), Color(0.4, 0.02, 0.02), Color(0.55, 0.5, 0.42)]

var state := MENU
var rng := RandomNumberGenerator.new()
var models: CarModels
var city: City
var hud: Hud
var audio: GameAudio
var player: Node3D
var cam: Camera3D
var police: Array[OmniLight3D] = []
var traffic: Array = []      # {node, paints, vm, oncoming, lane, len, wid, active, gap}
var speed := 0.0
var t := 0.0                 # seconds into the run
var dist := 0.0
var bonus := 0
var combo := 0
var combo_t := 0.0
var near_misses := 0
var best := 0
var px := LANES[2]
var target_x: float = LANES[2]
var vx := 0.0
var spawn_t := 0.0
var crash_t := 0.0
var spin := 0.0
var shake := 0.0
var hit_car = null
var bot := false             # steer automatically (the start screen's demo drive, and the auto-play test)
var keys := 0.0
var shot := ""               # --shot=file.png: save a screenshot after --frames=N frames and quit
var shot_frames := 120
var frame := 0

func _ready() -> void:
	var seed := 1
	var autoplay := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			seed = int(a.substr(7))
		elif a.begins_with("--shot="):
			shot = a.substr(7)
		elif a.begins_with("--frames="):
			shot_frames = int(a.substr(9))
		elif a == "--play":
			autoplay = true
	rng.seed = seed
	models = CarModels.new()
	city = City.new()
	add_child(city)
	city.build(models, seed)
	_player()
	_camera()
	_traffic_pool()
	audio = GameAudio.new()
	add_child(audio)
	hud = Hud.new()
	add_child(hud)
	var cfg := ConfigFile.new()
	if cfg.load(SAVE) == OK:
		best = int(cfg.get_value("records", "best", 0))
	_to_menu()
	if autoplay:
		start()
		bot = true

# ---------------------------------------------------------------- states
func _to_menu() -> void:
	state = MENU
	bot = true
	speed = 22.0
	_reset_run()
	hud.show_menu(best)

func start() -> void:
	state = PLAY
	bot = false
	speed = START_SPEED
	_reset_run()
	hud.show_play(best)
	audio.play("ui_click", 0.6)

func _reset_run() -> void:
	t = 0.0
	dist = 0.0
	bonus = 0
	combo = 0
	combo_t = 0.0
	near_misses = 0
	spawn_t = 0.0
	crash_t = 0.0
	spin = 0.0
	shake = 0.0
	hit_car = null
	vx = 0.0
	px = LANES[2]
	target_x = px
	for c in traffic:
		_deactivate(c)
	# a few cars already on the road ahead
	for i in 6:
		_try_spawn(-60.0 - i * 28.0)

func score() -> int:
	return int(dist) + bonus

func _crash(c) -> void:
	state = CRASH
	crash_t = 0.0
	hit_car = c
	spin = (1.0 if c.node.position.x < px else -1.0) * rng.randf_range(2.5, 4.0)
	shake = 1.0
	audio.play("boom_1", 0.7)
	audio.play("shatter_%d" % (1 + rng.randi() % 2), 0.9)
	audio.play("thud_1", 1.0, 0.7)
	Input.vibrate_handheld(300)

func _game_over() -> void:
	state = OVER
	var s := score()
	var new_best := s > best
	if new_best:
		best = s
		var cfg := ConfigFile.new()
		cfg.set_value("records", "best", best)
		cfg.save(SAVE)
	hud.show_over(s, best, new_best)
	get_tree().create_timer(0.8).timeout.connect(func():
		if state == OVER:
			hud.allow_retry())

# ---------------------------------------------------------------- input
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventScreenTouch and e.pressed:
		if state == MENU:
			start()
		elif state == OVER and hud.over_tap.visible:
			start()
	elif e is InputEventScreenDrag and state == PLAY:
		target_x = clamp(target_x + drag_metres(e.relative.x), -X_LIMIT, X_LIMIT)

## How far a drag of dx pixels steers, the same on any screen size.
func drag_metres(dx: float) -> float:
	return dx / max(get_viewport().get_visible_rect().size.x, 1.0) * STEER_SPAN

# ---------------------------------------------------------------- frame
func _process(delta: float) -> void:
	var dt: float = min(delta, 0.05)
	match state:
		PLAY:
			t += dt
			speed = min(START_SPEED + ACCEL * t, MAX_SPEED)
		CRASH:
			crash_t += dt
			speed = move_toward(speed, 0.0, 60.0 * dt)
			if crash_t > 1.3:
				_game_over()
		OVER:
			speed = move_toward(speed, 0.0, 60.0 * dt)
	if state == PLAY or state == MENU:
		_steer(dt)
	var dz := speed * dt
	if state == PLAY:
		dist += dz
	city.advance(dz, speed)
	_move_traffic(dt)
	if state == PLAY or state == MENU:
		spawn_t -= dt
		if spawn_t <= 0.0:
			_try_spawn(SPAWN_Z)
			var d: float = clamp(t / 100.0, 0.0, 1.0)
			spawn_t = lerp(0.85, 0.36, d) * (1.4 if state == MENU else 1.0)
	if combo_t > 0.0:
		combo_t -= dt
		if combo_t <= 0.0:
			combo = 0
	_place_player(dt)
	_update_camera(dt)
	_update_police()
	_update_audio()
	if state == PLAY:
		hud.set_score(score(), speed * 3.6)
	frame += 1
	if shot != "" and frame == shot_frames:
		get_viewport().get_texture().get_image().save_png(shot)
		print("saved ", shot, "  score ", score(), "  speed ", int(speed * 3.6), " km/h")
		get_tree().quit()

func _steer(dt: float) -> void:
	if bot:
		target_x = _bot_target()
	else:
		keys = Input.get_axis("ui_left", "ui_right")
		if keys != 0.0:
			target_x = clamp(target_x + keys * 16.0 * dt, -X_LIMIT, X_LIMIT)
	var want: float = clamp((target_x - px) * 9.0, -17.0, 17.0)
	vx = lerp(vx, want, 1.0 - exp(-14.0 * dt))
	px = clamp(px + vx * dt, -X_LIMIT, X_LIMIT)

func _place_player(dt: float) -> void:
	player.position.x = px
	if state == CRASH or state == OVER:
		player.rotation.y += spin * dt
		spin = move_toward(spin, 0.0, 5.0 * dt)
		player.rotation.z = 0.0
	else:
		player.rotation.y = -atan2(vx, max(speed, 1.0)) * 1.3
		player.rotation.z = -vx * 0.008

# ---------------------------------------------------------------- traffic
func _traffic_pool() -> void:
	# cars coming towards you show their headlights, cars you overtake their tail lights
	var kinds := []
	for i in 7:
		kinds.append(["gls", true, false])
	for i in 2:
		kinds.append(["agera", true, false])
	for i in 8:
		kinds.append(["gls", false, false])
	for i in 2:
		kinds.append(["gls", false, true])
	for i in 2:
		kinds.append(["agera", false, false])
	for k in kinds:
		var node := models.make(k[0], Color(0.5, 0.5, 0.5), {halos = "head" if k[1] else "tail", taxi = k[2], scale = 0.95 if k[0] == "gls" else 1.0})
		node.position = PARKED
		add_child(node)
		var paints := []
		for mi in node.get_node("Body").get_children():
			if mi is MeshInstance3D and (mi.material_override == models.mats.paint or mi.material_override == models.mats.far):
				paints.append(mi)
		var spec: Dictionary = CarModels.SPEC[k[0]]
		var sc: float = 0.95 if k[0] == "gls" else 1.0
		traffic.append({node = node, paints = paints, vm = k[0], oncoming = k[1], taxi = k[2], lane = 0,
			len = spec.length * sc, wid = spec.width * sc, active = false, gap = 99.0})

## Closing speed of a car in this lane (how fast it comes towards the player).
func _closing(lane: int) -> float:
	return speed + LANE_SPEED[lane] if ONCOMING[lane] else speed - LANE_SPEED[lane]

func _try_spawn(z: float) -> void:
	var lane := rng.randi() % 4
	# same lane: keep a gap
	for c in traffic:
		if c.active and c.lane == lane and abs(c.node.position.z - z) < 30.0:
			return
	# never close every lane at once: count the lanes with a car arriving about when this one would
	var eta: float = -z / max(_closing(lane), 1.0)
	var busy := {lane: true}
	for c in traffic:
		if c.active and c.node.position.z < 0.0:
			var e: float = -c.node.position.z / max(_closing(c.lane), 1.0)
			if abs(e - eta) < 1.0:
				busy[c.lane] = true
	var allowed := 3 if t > 25.0 else 2
	if busy.size() > allowed:
		return
	var pick := []
	for c in traffic:
		if not c.active and c.oncoming == ONCOMING[lane]:
			pick.append(c)
	if pick.is_empty():
		return
	var c = pick[rng.randi() % pick.size()]
	c.active = true
	c.lane = lane
	c.gap = 99.0

	c.node.position = Vector3(LANES[lane] + rng.randf_range(-0.25, 0.25), 0, z)
	c.node.rotation = Vector3(0, PI if c.oncoming else 0.0, 0)
	var col: Color = Color(0.75, 0.5, 0.03) if c.taxi else COLOURS[rng.randi() % COLOURS.size()]
	for mi in c.paints:
		mi.set_instance_shader_parameter("paint", Vector3(col.r, col.g, col.b))

func _deactivate(c) -> void:
	c.active = false
	c.node.position = PARKED   # (hiding the car instead stops its model showing again, so it waits out of sight)

func _move_traffic(dt: float) -> void:
	for c in traffic:
		if not c.active:
			continue
		var n: Node3D = c.node
		if c == hit_car:
			# knocked aside by the crash
			n.position.z += (speed - LANE_SPEED[c.lane] * 0.3) * dt
			n.rotation.y += -spin * 0.6 * dt
			continue
		n.position.z += _closing(c.lane) * dt
		if n.position.z > 18.0:
			_deactivate(c)
			continue
		if state != PLAY and state != MENU:
			continue
		var dz: float = abs(n.position.z)
		var reach: float = (c.len + PLAYER.length) * 0.5
		var gap: float = abs(n.position.x - px) - (c.wid + PLAYER.width) * 0.5
		if dz < reach - 0.25:
			if gap < -0.12:
				if state == PLAY:
					_crash(c)
					return
				else:
					_deactivate(c)   # the demo drive never crashes
					continue
			c.gap = min(c.gap, gap)
		elif n.position.z > reach and c.gap < NEAR_GAP:
			# it has just gone past, closely
			var g: float = c.gap
			c.gap = 99.0
			if state == PLAY:
				_near_miss(c, g)

func _near_miss(c, g: float) -> void:
	near_misses += 1
	combo = combo + 1 if combo_t > 0.0 else 1
	combo_t = 2.5
	var pts: int = 25 * combo * (2 if c.oncoming else 1)
	bonus += pts
	var txt := "CLOSE CALL +%d" % pts
	if combo > 1:
		txt = "x%d  +%d" % [combo, pts]
	hud.popup(txt, Color(1.0, 0.85, 0.3) if combo < 3 else Color(1.0, 0.45, 0.25))
	audio.play("whoosh", 0.8, rng.randf_range(0.9, 1.1))
	audio.play("chime", 0.25, 1.0 + 0.12 * min(combo - 1, 6))

## The demo driver: heads for the lane whose next car arrives last, as long as the lanes on the way
## are clear long enough to cross them.
func _bot_target() -> float:
	var arrive := [99.0, 99.0, 99.0, 99.0]
	for c in traffic:
		if c.active and c != hit_car:
			var z: float = c.node.position.z
			var reach: float = (c.len + PLAYER.length) * 0.5 + 0.5
			if z < reach:
				var e: float = max(-(z + reach), 0.0) / max(_closing(c.lane), 1.0)
				arrive[c.lane] = min(arrive[c.lane], e)
	var cur := 0
	for i in 4:
		if abs(LANES[i] - px) < abs(LANES[cur] - px):
			cur = i
	var best_lane := cur
	var best_score := -1.0
	for i in 4:
		var ok := true
		var step := 1 if i > cur else -1
		var j := cur
		while j != i:
			j += step
			var cross: float = abs(LANES[j] - px) / 12.0 + 0.25
			if arrive[j] < cross:
				ok = false
		if not ok:
			continue
		var s: float = min(arrive[i], 6.0) - 0.15 * abs(i - cur) + (0.3 if not ONCOMING[i] else 0.0)
		if s > best_score:
			best_score = s
			best_lane = i
	return LANES[best_lane]

# ---------------------------------------------------------------- player, camera, police
func _player() -> void:
	player = models.make("agera", Color(0.55, 0.012, 0.015), {halos = "tail", shadow = false})
	add_child(player)
	var L: Dictionary = CarModels.SPEC.agera
	for side in [-1.0, 1.0]:
		var s := SpotLight3D.new()
		s.position = Vector3(L.head.z * side, L.head.y, -L.head.x)
		s.rotation_degrees = Vector3(-4, 0, 0)
		s.light_color = Color(1.0, 0.93, 0.82)
		s.light_energy = 5.0
		s.spot_range = 45.0
		s.spot_angle = 26.0
		s.spot_attenuation = 0.8
		player.add_child(s)
	# police lights just behind, flashing red and blue on the road and the car
	for k in 2:
		var o := OmniLight3D.new()
		o.light_color = Color(1.0, 0.08, 0.06) if k == 0 else Color(0.15, 0.3, 1.0)
		o.omni_range = 16.0
		o.omni_attenuation = 1.2
		o.position = Vector3(-1.0 if k == 0 else 1.0, 2.0, 9.5)
		add_child(o)
		police.append(o)

func _camera() -> void:
	cam = Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.fov = 66.0
	cam.far = 400.0
	add_child(cam)
	cam.current = true

func _update_camera(dt: float) -> void:
	shake = move_toward(shake, 0.0, 1.6 * dt)
	var j := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), 0) * shake * 0.25
	var f: float = clamp((speed - START_SPEED) / (MAX_SPEED - START_SPEED), 0.0, 1.0)
	cam.fov = 66.0 + 10.0 * f   # wider as the speed builds
	var base := Vector3(px * 0.6, 4.6, 8.2)
	cam.position = base + j
	cam.look_at(Vector3(px * 0.7, 0.4, -14.0) + j * 0.5, Vector3.UP)

func _update_police() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var on := int(now * 5.0) % 2
	var level := 2.6 if state == PLAY or state == MENU else 5.0
	for k in 2:
		police[k].light_energy = level * (1.0 if on == k else 0.08)
	hud.police(on, 0.35 if state == PLAY else (0.8 if state != MENU else 0.15))

func _update_audio() -> void:
	var f: float = clamp(speed / MAX_SPEED, 0.0, 1.0)
	var running := state == PLAY or state == MENU
	audio.set_loop("engine_loop", (0.35 + 0.35 * f) if running else 0.12, 0.8 + 1.6 * f)
	audio.set_loop("siren_loop", 0.22 if state == PLAY else (0.45 if state != MENU else 0.08))
