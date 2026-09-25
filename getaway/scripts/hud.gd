## Score, speed, near-miss pop-ups and the start / busted screens. Sized for a 390 x 844 portrait view.
class_name Hud
extends CanvasLayer

var title_font: Font
var num_font: Font
var score_lbl: Label
var best_lbl: Label
var speed_lbl: Label
var popup_lbl: Label
var hint_lbl: Label
var menu: Control
var menu_best: Label
var over: Control
var over_score: Label
var over_best: Label
var over_tap: Label
var popup_t := 0.0
var hint_t := 0.0
var flash: Array[TextureRect] = []   # red and blue police glow at the bottom corners

func _ready() -> void:
	var fv := FontVariation.new()
	fv.base_font = load("res://assets/fonts/BigShouldersDisplay.ttf")
	fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 800}
	title_font = fv
	num_font = load("res://assets/fonts/BarlowCondensed-Bold.ttf")
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	for k in 2:
		var g := GradientTexture2D.new()
		g.fill = GradientTexture2D.FILL_RADIAL
		g.fill_from = Vector2(0.0 if k == 0 else 1.0, 1.0)
		g.fill_to = Vector2(0.75 if k == 0 else 0.25, 0.45)
		var grad := Gradient.new()
		var c := Color(1.0, 0.1, 0.08) if k == 0 else Color(0.15, 0.35, 1.0)
		grad.colors = PackedColorArray([Color(c, 0.55), Color(c, 0.0)])
		g.gradient = grad
		var tr := TextureRect.new()
		tr.texture = g
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.modulate.a = 0.0
		root.add_child(tr)
		flash.append(tr)
	score_lbl = _label(root, num_font, 64, Color(1, 1, 1))
	_place(score_lbl, 0.0, 1.0, 34.0, 110.0)
	best_lbl = _label(root, num_font, 20, Color(0.75, 0.78, 0.85, 0.9))
	_place(best_lbl, 0.0, 1.0, 104.0, 130.0)
	speed_lbl = _label(root, num_font, 30, Color(1, 1, 1, 0.92))
	speed_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	speed_lbl.anchor_left = 0.5
	speed_lbl.anchor_right = 1.0
	speed_lbl.anchor_top = 1.0
	speed_lbl.anchor_bottom = 1.0
	speed_lbl.offset_left = 0
	speed_lbl.offset_right = -22
	speed_lbl.offset_top = -70
	speed_lbl.offset_bottom = -26
	popup_lbl = _label(root, title_font, 40, Color(1.0, 0.85, 0.3))
	_place(popup_lbl, 0.0, 1.0, 250.0, 330.0)
	popup_lbl.modulate.a = 0.0
	hint_lbl = _label(root, num_font, 26, Color(1, 1, 1, 0.85))
	hint_lbl.text = "‹  DRAG TO STEER  ›"
	_place(hint_lbl, 0.0, 1.0, 560.0, 600.0)
	hint_lbl.modulate.a = 0.0
	# start screen
	menu = _panel(root)
	var t := _label(menu, title_font, 86, Color(1, 1, 1))
	t.text = "GETAWAY"
	_place(t, 0.0, 1.0, 150.0, 250.0)
	var sub := _label(menu, num_font, 22, Color(0.85, 0.88, 0.95))
	sub.text = "The police are right behind you.\nDrag to steer through the traffic.\nPass cars closely for bonus points."
	_place(sub, 0.0, 1.0, 262.0, 360.0)
	menu_best = _label(menu, num_font, 24, Color(1.0, 0.85, 0.3))
	_place(menu_best, 0.0, 1.0, 390.0, 420.0)
	var go := _label(menu, title_font, 38, Color(1, 1, 1))
	go.text = "TAP TO DRIVE"
	_place(go, 0.0, 1.0, 640.0, 700.0)
	_blink(go)
	# busted screen
	over = _panel(root)
	var b := _label(over, title_font, 92, Color(1.0, 0.25, 0.2))
	b.text = "BUSTED"
	_place(b, 0.0, 1.0, 170.0, 270.0)
	over_score = _label(over, num_font, 58, Color(1, 1, 1))
	_place(over_score, 0.0, 1.0, 300.0, 370.0)
	over_best = _label(over, num_font, 24, Color(1.0, 0.85, 0.3))
	_place(over_best, 0.0, 1.0, 372.0, 404.0)
	over_tap = _label(over, title_font, 38, Color(1, 1, 1))
	over_tap.text = "TAP TO TRY AGAIN"
	_place(over_tap, 0.0, 1.0, 640.0, 700.0)
	_blink(over_tap)
	over.visible = false
	show_menu(0)

func _process(delta: float) -> void:
	if popup_t > 0.0:
		popup_t -= delta
		popup_lbl.modulate.a = clamp(popup_t / 0.4, 0.0, 1.0)
		popup_lbl.position.y -= 18.0 * delta
	if hint_t > 0.0:
		hint_t -= delta
		hint_lbl.modulate.a = clamp(hint_t / 0.6, 0.0, 1.0)

## The police lights behind the car, flashing at the screen's bottom corners (level 0..1).
func police(on: int, level: float) -> void:
	for k in 2:
		flash[k].modulate.a = level * (1.0 if on == k else 0.1)

func show_menu(best: int) -> void:
	menu.visible = true
	over.visible = false
	score_lbl.visible = false
	best_lbl.visible = false
	speed_lbl.visible = false
	menu_best.text = "BEST  %d" % best if best > 0 else ""

func show_play(best: int) -> void:
	menu.visible = false
	over.visible = false
	score_lbl.visible = true
	best_lbl.visible = true
	speed_lbl.visible = true
	best_lbl.text = "BEST %d" % best if best > 0 else ""
	hint_t = 3.0

func show_over(score: int, best: int, new_best: bool) -> void:
	over.visible = true
	score_lbl.visible = false
	best_lbl.visible = false
	speed_lbl.visible = false
	over_score.text = str(score)
	over_best.text = "NEW BEST!" if new_best else "BEST  %d" % best
	over_tap.visible = false

## The retry prompt appears a moment after the crash, so a tap meant for steering doesn't restart.
func allow_retry() -> void:
	over_tap.visible = true

func set_score(score: int, kmh: float) -> void:
	score_lbl.text = str(score)
	speed_lbl.text = "%d km/h" % int(kmh)

## A near-miss pop-up in the middle of the screen, floating up.
func popup(text: String, col: Color) -> void:
	popup_lbl.text = text
	popup_lbl.add_theme_color_override("font_color", col)
	popup_lbl.position.y = 250.0
	popup_t = 1.1

func _panel(parent: Control) -> Control:
	var c := ColorRect.new()
	c.color = Color(0.02, 0.025, 0.04, 0.55)
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(c)
	return c

func _label(parent: Control, font: Font, size: int, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l

## Spans the label across the screen between two heights (in the 844-high portrait layout).
func _place(l: Label, ax0: float, ax1: float, y0: float, y1: float) -> void:
	l.anchor_left = ax0
	l.anchor_right = ax1
	l.offset_left = 0
	l.offset_right = 0
	l.offset_top = y0
	l.offset_bottom = y1

func _blink(l: Label) -> void:
	var tw := l.create_tween().set_loops()
	tw.tween_property(l, "modulate:a", 0.35, 0.7)
	tw.tween_property(l, "modulate:a", 1.0, 0.7)
