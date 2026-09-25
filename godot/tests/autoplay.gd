## Auto-play test. Plays whole runs by steering the player along the street graph: all clues,
## find the child, talk, escape with her to the flare, the end screen, then play again, pause and menu.
## Prints "ok"/"FAIL" per check and ends with "DONE fails=N".
##   godot --headless --path godot --fixed-fps 20 -s res://tests/autoplay.gd -- --mode=win --seed=3
## --mode=win   the creature is held far away, so the run must end in a rescue
## --mode=lose  the creature starts next to the player, so the run must end with being found
## --mode=wild  the creature hunts freely; either ending is fine
## --shots=dir  with rendering on (no --headless), saves screenshots at key moments
extends SceneTree

var g: Game
var f := 0
var stage := "boot"
var wp: Array = []
var mode := "win"
var st_t := 0.0
var targets: Array = []
var last_p := Vector2()
var still_t := 0.0
var runs := 0
var fails := 0
var tlog := 0.0
var last_ms := ""
var shots := ""
var shot_q: Array = []   # [frame, name]

## Queues a screenshot a few frames from now (with --shots=dir, when rendering).
func shoot(name: String, delay := 3) -> void:
	if shots != "":
		shot_q.append([f + delay, name])

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			mode = a.substr(7)
		if a.begins_with("--shots="):
			shots = a.substr(8)
	root.add_child(load("res://scenes/main.tscn").instantiate())

func finish() -> bool:
	print("DONE fails=%d" % fails)
	quit(1 if fails > 0 else 0)
	return false

func say(s: String) -> void:
	print("[%6.1f] %-8s %s" % [g.time if g else 0.0, stage, s])

func check(ok: bool, what: String) -> void:
	if ok:
		print("   ok   ", what)
	else:
		fails += 1
		print("   FAIL ", what)

func route_to(x: float, z: float) -> void:
	var a := g.nearest_node(g.pl.pos.x, g.pl.pos.z, true)
	var b := g.nearest_node(x, z, true)
	wp = []
	for i in g.bfs(a, b):
		wp.append(Vector2(g.nodes[i].x, g.nodes[i].z))
	wp.append(Vector2(x, z))
	still_t = 0.0

## Hand-made waypoints through the subway: down the stairs, through the hall, to the room or the tunnel end.
func under_path() -> Array:
	var w := [Vector2(16, 14.5), Vector2(16, 17), Vector2(16, 29), Vector2(16, 31.5)]
	if g.loc.id == "subroom":
		w += [Vector2(10, 32.8), Vector2(6, 32.8), Vector2(2.6, 34.6)]
	else:
		w += [Vector2(24, 35), Vector2(41, 40.6), Vector2(84, 41), Vector2(90.0, 40.8)]
	return w

func route_child() -> void:
	if g.loc.y > -1.0:
		# in through the door: the outside end of her footprint trail, the entrance, then the spot
		var o: Array = g.loc.trail[0]
		route_to(o[0], o[1])
		wp += [Vector2(g.loc.ent[0], g.loc.ent[1]), Vector2(g.child.pos.x, g.child.pos.z)]
		return
	route_to(16, 14.5)
	wp.pop_back()
	wp += under_path()

func route_exit() -> void:
	if g.pl.pos.y < -1.0:
		var w := under_path()
		w.reverse()
		w.pop_front()
		wp = w
		var a := g.nearest_node(16, 14.5, true)
		var b := g.nearest_node(g.exit.x, g.exit.z, true)
		for i in g.bfs(a, b):
			wp.append(Vector2(g.nodes[i].x, g.nodes[i].z))
		wp.append(Vector2(g.exit.x, g.exit.z))
		return
	var bx = g.loc.get("box")
	if bx is Dictionary and g.pl.pos.x > bx.x0 - 0.5 and g.pl.pos.x < bx.x1 + 0.5 and g.pl.pos.z > bx.z0 - 0.5 and g.pl.pos.z < bx.z1 + 0.5:
		var o: Array = g.loc.trail[0]
		wp = [Vector2(g.loc.ent[0], g.loc.ent[1]), Vector2(o[0], o[1])]
		var a := g.nearest_node(o[0], o[1], true)
		var b := g.nearest_node(g.exit.x, g.exit.z, true)
		for i in g.bfs(a, b):
			wp.append(Vector2(g.nodes[i].x, g.nodes[i].z))
		wp.append(Vector2(g.exit.x, g.exit.z))
		return
	route_to(g.exit.x, g.exit.z)

var cur_wp := Vector2(INF, INF)

## A point to walk via when something (a parked car, a bench) blocks the straight line.
func detour(p: Vector2, t: Vector2):
	var d := (t - p).normalized()
	var n := Vector2(-d.y, d.x)
	for k in [1.5, 2.5, 3.5, 5.0, 7.0]:
		for j in [0.0, 1.5, 3.0]:
			for sgn in [1.0, -1.0]:
				var q: Vector2 = p + n * k * sgn + d * j
				if g.col.walkable(q.x, q.y, 0.45) and g.col.path_clear(p.x, p.y, q.x, q.y, 0.4) and g.col.path_clear(q.x, q.y, t.x, t.y, 0.4):
					return q
	return null

## Walks around whatever blocks the straight line (cars, shelves, fences) on a half-metre grid.
func grid_path(a: Vector2, b: Vector2) -> Array:
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(14, 14)
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2(14, 14)
	var cs := 0.5
	var ag := AStarGrid2D.new()
	ag.region = Rect2i(0, 0, int((hi.x - lo.x) / cs) + 1, int((hi.y - lo.y) / cs) + 1)
	ag.cell_size = Vector2(cs, cs)
	ag.offset = lo
	ag.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	ag.update()
	for i in ag.region.size.x:
		for j in ag.region.size.y:
			var q := lo + Vector2(i, j) * cs
			if not g.col.walkable(q.x, q.y, 0.36):
				ag.set_point_solid(Vector2i(i, j))
	var ia := Vector2i(((a - lo) / cs).round())
	var ib := Vector2i(((b - lo) / cs).round())
	ag.set_point_solid(ia, false)
	ag.set_point_solid(ib, false)
	var path := ag.get_point_path(ia, ib)
	var out := []
	for k in range(3, path.size(), 3):
		out.append(path[k])
	if path.size():
		out.append(b)
	return out

func steer(dt: float, run := 0.9) -> bool:
	var inp: Dictionary = g.hud.input
	inp.jx = 0.0
	inp.jy = 0.0
	if wp.is_empty():
		return true
	var p := Vector2(g.pl.pos.x, g.pl.pos.z)
	while wp.size() > 1 and p.distance_to(wp[0]) < 1.0:
		wp.pop_front()
	if wp.size() == 1 and p.distance_to(wp[0]) < 1.0:
		wp.clear()
		return true
	# street nodes can sit under a parked car: skip those
	while wp.size() > 1 and g.pl.pos.y > -1.0 and not g.col.walkable(wp[0].x, wp[0].y, 0.4):
		wp.pop_front()
	if wp[0] != cur_wp:
		cur_wp = wp[0]
		if g.pl.pos.y > -1.0 and not g.col.path_clear(p.x, p.y, cur_wp.x, cur_wp.y, 0.4):
			var pts := grid_path(p, cur_wp)
			if pts.size():
				wp = pts + wp.slice(1)
				cur_wp = wp[0]
	var d: Vector2 = wp[0] - p
	g.pl.cam_yaw = atan2(d.x, d.y)
	inp.jy = run
	if p.distance_to(last_p) < 0.02:
		still_t += dt
		if still_t > 3.0:
			say("stuck at %s heading for %s, skipping ahead" % [p, wp[0]])
			g.pl.pos.x = wp[0].x
			g.pl.pos.z = wp[0].y
			still_t = 0.0
	else:
		still_t = 0.0
	last_p = p
	return false

func hold_monster() -> void:
	# keep it on the far side of the city, patrolling
	var far := 0
	var fd := 0.0
	for i in g.nodes.size():
		var d := Vector2(g.nodes[i].x - g.pl.pos.x, g.nodes[i].z - g.pl.pos.z).length()
		if d > fd:
			fd = d
			far = i
	g.mon.pos = Vector3(g.nodes[far].x, 0, g.nodes[far].z)
	g.mon.state = "PATROL"
	g.mon.awareness = 0.0
	g.mon.path.clear()

func _process(dt: float) -> bool:
	f += 1
	for q in shot_q.duplicate():
		if f >= q[0]:
			shot_q.erase(q)
			root.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [shots, q[1]])
			print("   shot ", q[1])
	if g == null:
		var m := root.get_child(root.get_child_count() - 1)
		if m.get_child_count():
			g = m.get_child(0) as Game
		return false
	st_t += dt
	if mode == "win" and g.phase in ["explore", "dialog", "escape"]:
		hold_monster()
	if g.mon.state != last_ms and g.phase != "menu":
		last_ms = g.mon.state
		say("creature -> %s at %.0fm (awareness %.2f, player %s %s)" % [last_ms, Vector2(g.mon.pos.x - g.pl.pos.x, g.mon.pos.z - g.pl.pos.z).length(), g.mon.awareness, g.pl.move, "hidden" if g.pl.hidden else ""])
	if mode == "wild" and g.phase in ["caught", "lost"] and stage in ["clues", "child", "dialog", "wait_escape", "escape"]:
		say("caught while %s" % stage)
		stage = "wait_end"
		st_t = 0.0
	tlog -= dt
	if tlog <= 0.0 and g.phase in ["explore", "escape"]:
		tlog = 10.0
		var dc := Vector2(g.child.pos.x - g.pl.pos.x, g.child.pos.z - g.pl.pos.z).length()
		var dm := Vector2(g.mon.pos.x - g.pl.pos.x, g.mon.pos.z - g.pl.pos.z).length()
		say("player %s  child %s %.0fm  creature %s %.0fm  clues %d  obj '%s'" % [Vector2(g.pl.pos.x, g.pl.pos.z).round(), g.child.state, dc, g.mon.state, dm, g.found, g.hud.obj_title()])
	match stage:
		"boot":
			if g.phase == "menu" and f > 10:
				check(g.hud.screens.start.visible, "start screen shows")
				g.start_game()
				runs += 1
				wp.clear()
				check(g.phase == "explore", "START begins a run")
				check(g.hud.play.visible and not g.hud.screens.start.visible, "HUD replaces the start screen")
				say("location %s, exit %s" % [g.loc.id, g.exit.name])
				if mode == "lose":
					stage = "wait_caught"
					g.mon.pos = g.pl.pos + Vector3(8, 0, 0)
					g.mon.start_chase()
				else:
					targets = g.clues.filter(func(c): return not c.virtual)
					stage = "clues"
				st_t = 0.0
		"clues":
			if wp.is_empty() and targets.size():
				var c: Dictionary = targets[0]
				route_to(c.x, c.z)
				say("heading for %s at (%.0f, %.0f)" % [c.title, c.x, c.z])
			if steer(dt):
				var c: Dictionary = targets.pop_front()
				var act := g.find_interact()
				check(act.get("label", "") == "EXAMINE", "EXAMINE offered at the %s (got '%s')" % [c.title, act.get("label", "")])
				var before := g.found
				g.do_interact()
				if runs == 1 and before <= 1:
					shoot("clue", 20)
				check(g.found == before + 1 and c.found, "%s found, %d/5" % [c.title, g.found])
				if targets.is_empty():
					stage = "child"
					route_child()
					say("heading for the child (%s) at %s" % [g.loc.id, Vector2(g.child.pos.x, g.child.pos.z).round()])
		"child":
			var d := Vector2(g.child.pos.x - g.pl.pos.x, g.child.pos.z - g.pl.pos.z).length()
			if steer(dt) or d < 2.0:
				wp.clear()
				steer(dt)
				var act := g.find_interact()
				check(act.get("label", "") == "HELP", "HELP offered next to the child (got '%s', %.1fm, dy %.1f)" % [act.get("label", ""), d, g.child.pos.y - g.pl.pos.y])
				g.do_interact()
				check(g.phase == "dialog", "talking starts the dialogue")
				stage = "dialog"
				st_t = 0.0
		"dialog":
			if g.hud.choices_box.visible and shot_q.is_empty() and not has_meta("chose"):
				set_meta("chose", true)
				shoot("choices", 2)
				return false
			if g.hud.choices_box.visible and shot_q.is_empty():
				remove_meta("chose")
				check(g.hud.choices_box.get_child_count() == 2, "two replies offered")
				g.choose_line(1)
				stage = "wait_escape"
			elif st_t > 8.0:
				check(false, "reply choices appeared")
				stage = "wait_escape"
		"wait_escape":
			if g.phase == "escape":
				check(g.exg.visible, "flare and truck appear at the exit")
				check(g.hud.obj_title() == "GET THE CHILD OUT", "objective changes to GET THE CHILD OUT")
				route_exit()
				say("escaping to the %s barricade at (%.0f, %.0f)" % [g.exit.name, g.exit.x, g.exit.z])
				if runs == 1:
					shoot("escape_start", 10)
					shoot("escape_street", 400)
				stage = "escape"
				st_t = 0.0
			elif st_t > 12.0:
				check(false, "escape began after the dialogue (phase %s)" % g.phase)
				return finish()
		"escape":
			if g.phase == "won":
				say("reached the exit with her")
				if runs == 1:
					shoot("at_exit", 1)
				stage = "wait_end"
				st_t = 0.0
				return false
			if g.phase in ["caught", "lost"]:
				say("caught during the escape")
				stage = "wait_end"
				return false
			if g.child.state == "wait":
				# she fell behind: go back and call her
				var dc := Vector2(g.child.pos.x - g.pl.pos.x, g.child.pos.z - g.pl.pos.z).length()
				if dc > 5.0:
					if wp.is_empty() or wp[-1].distance_to(Vector2(g.child.pos.x, g.child.pos.z)) > 1.0:
						say("she stopped following, going back")
						# back along our own trail
						var tl: Array = g.pl.trail
						var cpos := Vector2(g.child.pos.x, g.child.pos.z)
						var k := 0
						for i in tl.size():
							if Vector2(tl[i].x, tl[i].z).distance_to(cpos) < Vector2(tl[k].x, tl[k].z).distance_to(cpos):
								k = i
						wp = []
						for i in range(tl.size() - 1, k - 1, -1):
							wp.append(Vector2(tl[i].x, tl[i].z))
						wp.append(cpos)
					steer(dt, 0.6)
				else:
					var act := g.find_interact()
					if act.get("label", "") == "CALL":
						g.do_interact()
						say("called her")
					route_exit()
				return false
			if wp.is_empty() or wp[-1].distance_to(Vector2(g.exit.x, g.exit.z)) > 1.0:
				route_exit()
			var dc2 := Vector2(g.child.pos.x - g.pl.pos.x, g.child.pos.z - g.pl.pos.z).length()
			steer(dt, 0.9 if dc2 < 6.0 else 0.4)
			if st_t > 240.0:
				check(false, "reached the exit within 4 minutes")
				return finish()
		"pause_shot":
			if shot_q.is_empty():
				g.set_pause(false)
				check(not g.paused and g.hud.play.visible, "resume returns to the HUD")
				g.to_menu()
				check(g.phase == "menu" and g.hud.screens.start.visible, "MENU returns to the start screen")
				stage = "boot"
				f = 0
				shot_q.clear()
		"wait_caught":
			if st_t > 1.2 and st_t < 1.3 and runs == 1:
				shoot("creature_close", 0)
			if g.phase in ["caught", "lost"]:
				say("caught")
				stage = "wait_end"
				st_t = 0.0
			elif st_t > 40.0:
				check(false, "creature catches a player standing still")
				return finish()
		"wait_end":
			if g.phase in ["wonEnd", "lost"]:
				var won := g.phase == "wonEnd"
				check(g.hud.screens.end.visible, "end screen shows (%s)" % ("rescued" if won else "found"))
				if runs == 1 and shots != "" and not has_meta("end_shot"):
					set_meta("end_shot", true)
					shoot("end_" + mode, 2)
					return false
				if not shot_q.is_empty():
					return false
				say("end: %s / %s / %s" % [g.hud.end_title.text, g.hud.end_sub.text, g.hud.end_stats.text])
				check(int(g.records.runs) >= 1, "records saved: %s" % g.records)
				if mode == "win":
					check(won, "the run ends in a rescue")
				if mode == "lose":
					check(not won, "the run ends with being found")
				if runs >= 2:
					return finish()
				# play again, then a quick pause / menu round trip
				g.start_game()
				runs += 1
				check(g.phase == "explore" and g.found == 0 and g.hud.clue_lbl.text == "0", "PLAY AGAIN starts a clean run")
				check(g.child.state == "hiding" and not g.exg.visible, "child hiding and exit hidden again")
				g.set_pause(true)
				check(g.paused and g.hud.screens.pause.visible, "pause shows the pause screen")
				if shots != "":
					# hold the pause for a frame so it can be captured
					stage = "pause_shot"
					shoot("pause", 3)
					return false
				g.set_pause(false)
				check(not g.paused and g.hud.play.visible, "resume returns to the HUD")
				g.to_menu()
				check(g.phase == "menu" and g.hud.screens.start.visible, "MENU returns to the start screen")
				stage = "boot"
				f = 0
			elif st_t > 10.0:
				check(false, "end screen within 10 s (phase %s)" % g.phase)
				return finish()
	if g.time > 600.0:
		check(false, "finished within 10 minutes of game time")
		return finish()
	return false
