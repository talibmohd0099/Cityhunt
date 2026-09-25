## Auto-play test: drives whole runs by itself and checks each step. Prints "ok"/"FAIL" per check and
## ends with "DONE fails=N" (exit code 1 if anything failed).
##   godot --headless --path getaway --fixed-fps 30 -s res://tests/autoplay.gd -- --seed=1
## 1. the start screen shows and a tap starts a run
## 2. dragging steers the car
## 3. the auto-driver survives a minute of traffic while the speed and score climb
## 4. driving straight into traffic ends in a crash and the BUSTED screen, with the best score saved
## 5. a tap starts a clean new run
## --shots=dir  with rendering on (no --headless), saves screenshots along the way
extends SceneTree

var g: Game
var f := 0
var stage := "boot"
var st_f := 0
var fails := 0
var mark := {}
var shots := ""
var shot_q: Array = []   # [frame, name]

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			shots = a.substr(8)
	root.add_child(load("res://scenes/main.tscn").instantiate())

## Queues a screenshot a few frames from now (with --shots=dir, when rendering).
func shoot(name: String, delay := 2) -> void:
	if shots != "":
		shot_q.append([f + delay, name])

func check(ok: bool, what: String) -> void:
	print("   %s   %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		fails += 1

func go(s: String) -> void:
	stage = s
	st_f = f

func tap() -> void:
	var e := InputEventScreenTouch.new()
	e.position = Vector2(195, 500)
	e.pressed = true
	root.push_input(e)
	var r := InputEventScreenTouch.new()
	r.position = e.position
	r.pressed = false
	root.push_input(r)

## Straight to the game's input handler: without a window (headless) the viewport's stretch would
## scale the drag unpredictably.
func drag(dx: float) -> void:
	var e := InputEventScreenDrag.new()
	e.position = Vector2(195, 600)
	e.relative = Vector2(dx, 0)
	g._unhandled_input(e)

func secs() -> float:
	return (f - st_f) / 30.0

func _process(_d: float) -> bool:
	f += 1
	for q in shot_q.duplicate():
		if f >= q[0]:
			root.get_texture().get_image().save_png("%s/%s.png" % [shots, q[1]])
			shot_q.erase(q)
	if g == null:
		g = root.get_node_or_null("Game")
		return false
	match stage:
		"boot":
			if f == 12:
				shoot("start")
			if f > 20:
				check(g.state == Game.MENU, "start screen shows")
				check(g.hud.menu.visible, "start panel is visible")
				tap()
				go("started")
		"started":
			if secs() > 0.3:
				check(g.state == Game.PLAY, "a tap starts the run")
				check(g.hud.score_lbl.visible and not g.hud.menu.visible, "the score replaces the start screen")
				mark.x = g.target_x
				drag(-40.0)
				go("dragged")
		"dragged":
			if secs() > 0.5:
				check(abs(g.target_x - (mark.x + g.drag_metres(-40.0))) < 0.01 and g.target_x < mark.x, "dragging left moves the steering target left (%.2f -> %.2f)" % [mark.x, g.target_x])
				check(g.px < mark.x - 0.5, "the car follows (x %.2f)" % g.px)
				g.bot = true
				mark.speed = g.speed
				go("drive")
		"drive":
			if f - st_f == 600:
				shoot("drive")
			if f % 300 == 0:
				var n := 0
				for c in g.traffic:
					if c.active:
						n += 1
				print("[%5.1f] score %d  %d km/h  cars %d  close calls %d  x %.1f" % [g.t, g.score(), int(g.speed * 3.6), n, g.near_misses, g.px])
			if g.state != Game.PLAY:
				check(false, "the auto-driver survives a minute (crashed at %.1f s)" % g.t)
				go("wait_over")
			elif secs() > 60.0:
				check(true, "the auto-driver survives a minute")
				check(g.speed > mark.speed + 10.0, "the speed builds up (%d -> %d km/h)" % [int(mark.speed * 3.6), int(g.speed * 3.6)])
				check(g.score() > 2000, "the score climbs (%d)" % g.score())
				mark.score = g.score()
				g.bot = false
				go("ram")
		"ram":
			# steer at the nearest car coming the other way
			var target = null
			for c in g.traffic:
				if c.active and c.oncoming and c.node.position.z < -8.0:
					if target == null or c.node.position.z > target.node.position.z:
						target = c
			if target != null:
				g.target_x = target.node.position.x
			if g.state == Game.CRASH:
				shoot("crash", 4)
				check(true, "driving into traffic crashes (%.1f s later)" % secs())
				go("wait_over")
			elif secs() > 25.0:
				check(false, "driving into traffic crashes")
				go("end")
		"wait_over":
			if g.state == Game.OVER:
				check(g.hud.over.visible, "the BUSTED screen shows")
				check(g.best >= g.score() and g.best > 0, "the best score is kept (%d)" % g.best)
				var cfg := ConfigFile.new()
				check(cfg.load(Game.SAVE) == OK and int(cfg.get_value("records", "best", 0)) == g.best, "the best score is saved")
				tap()
				check(g.state == Game.OVER, "a tap right after the crash doesn't restart")
				go("retry")
			elif secs() > 5.0:
				check(false, "the BUSTED screen shows")
				go("end")
		"retry":
			if f - st_f == 30:
				shoot("busted")
			if secs() > 1.2:
				check(g.hud.over_tap.visible, "the retry prompt appears")
				tap()
				go("restarted")
		"restarted":
			if secs() > 0.3:
				check(g.state == Game.PLAY, "a tap starts a new run")
				check(g.score() < 50 and g.near_misses == 0, "the new run starts from zero (%d)" % g.score())
				var crowd := 0
				for c in g.traffic:
					if c.active and abs(c.node.position.z) < 20.0:
						crowd += 1
				check(crowd == 0, "no car is left next to the start")
				go("end")
		"end":
			print("DONE fails=%d" % fails)
			quit(1 if fails > 0 else 0)
	return false
