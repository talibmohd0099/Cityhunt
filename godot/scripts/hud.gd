## Everything on screen that isn't the 3D city: the play HUD (objective, compass, awareness eye,
## minimap, subtitles, clue log), the touch controls, and the start, pause, end and settings screens.
## Laid out like the browser version, in the same fonts and colours.
class_name Hud
extends CanvasLayer

const INK := Color("07080a")
const TEXT := Color("dde1e6")
const MUTED := Color("858b94")
const SODIUM := Color("e9a444")
const DANGER := Color("d8412f")
const GLASS := Color(12 / 255.0, 14 / 255.0, 17 / 255.0, 0.46)
const LINE := Color(221 / 255.0, 225 / 255.0, 230 / 255.0, 0.2)
const FONTS := "res://assets/fonts/"
const JR := 56.0

var g: Game
var touch := false
var input := {jx = 0.0, jy = 0.0, kx = 0.0, ky = 0.0, krun = false, ksprint = false, sprint = false, look_dx = 0.0, look_dy = 0.0}
var danger := 0.0
var fade := 0.0

# fonts
var f_display: FontVariation
var f_cond: Font
var f_cond_b: Font
var f_cond_m: Font
var f_body: Font
var f_body_m: Font

# layers
var root: Control
var play: Control
var vignette: ColorRect
var danger_rect: ColorRect
var fade_rect: ColorRect
var screens := {}

# play HUD parts
var obj_t: Label
var obj_s: Label
var compass: Control
var aware: Control
var clue_btn: Control
var clue_lbl: Label
var pause_btn: Control
var log_panel: PanelContainer
var log_box: VBoxContainer
var map_rect: TextureRect
var map_mat: ShaderMaterial
var map_over: Control
var choices_box: VBoxContainer
var subs: RichTextLabel
var sub_t := 0.0
var toast_box: PanelContainer
var toast_t_lbl: Label
var toast_b_lbl: Label
var toast_t := 0.0
var stam_bg: ColorRect
var stam_fg: ColorRect
var controls: Control
var buttons := {}          # name -> {rect: Control, on: bool, hold: bool, ready: bool, dim: bool, label: String}
var joy_center := Vector2()
var joy_knob := Vector2()
var joy_id := -1
var looks := {}            # touch index -> last position
var btn_touch := {}        # touch index -> button name (for SPRINT hold)
var use_label := "USE"
var cur_act: Dictionary = {}
var safe := Rect2()        # safe-area insets as left, top, right, bottom (in canvas units)

# settings dialog
var set_ctrls := {}

func _init(p_g: Game) -> void:
	g = p_g
	layer = 10
	touch = OS.has_feature("mobile") or g.args.has("touch")

func _ready() -> void:
	_fonts()
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _theme()
	add_child(root)
	vignette = _overlay("vignette")
	danger_rect = _overlay("danger")
	danger_rect.modulate.a = 0.0
	_build_play()
	# the fade to black sits over the game and HUD but under the end, pause and settings screens
	fade_rect = ColorRect.new()
	fade_rect.color = Color.BLACK
	fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade_rect.modulate.a = 0.0
	root.add_child(fade_rect)
	_build_start()
	_build_end()
	_build_pause()
	_build_settings()
	get_viewport().size_changed.connect(_layout)
	_layout()

# ---------------------------------------------------------------- look
func _fonts() -> void:
	f_display = FontVariation.new()
	f_display.base_font = load(FONTS + "BigShouldersDisplay.ttf")
	var ts := TextServerManager.get_primary_interface()
	f_display.variation_opentype = {ts.name_to_tag("wght"): 800}
	f_cond = load(FONTS + "BarlowCondensed-SemiBold.ttf")
	f_cond_b = load(FONTS + "BarlowCondensed-Bold.ttf")
	f_cond_m = load(FONTS + "BarlowCondensed-Medium.ttf")
	f_body = load(FONTS + "Barlow-Regular.ttf")
	f_body_m = load(FONTS + "Barlow-Medium.ttf")

## A font with extra letter spacing (CSS letter-spacing in em at the given size).
func _spaced(base: Font, em: float, size: int) -> FontVariation:
	var v := FontVariation.new()
	v.base_font = base
	if base is FontVariation:
		v = (base as FontVariation).duplicate()
	v.spacing_glyph = int(round(em * size))
	return v

func _theme() -> Theme:
	var t := Theme.new()
	t.default_font = f_body
	t.default_font_size = 15
	t.set_color("font_color", "Label", TEXT)
	return t

func _sb(bg: Color, border := Color(0, 0, 0, 0), bw := 0, radius := 4) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_corner_radius_all(radius)
	return s

func _label(text: String, font: Font, size: int, color := TEXT, em := 0.0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _spaced(font, em, size) if em != 0.0 else font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _shadow(l: Control, px := 6) -> void:
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.add_theme_constant_override("shadow_outline_size", px)

func _overlay(kind: String) -> ColorRect:
	var r := ColorRect.new()
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	var sh := Shader.new()
	var inner := 0.45 if kind == "vignette" else 0.4
	var col := "vec4(0.0,0.0,0.0,0.72)" if kind == "vignette" else "vec4(120.0/255.0,10.0/255.0,6.0/255.0,0.55)"
	sh.code = "shader_type canvas_item;\nvoid fragment(){ float r=length((UV-0.5)*2.0)/sqrt(2.0); vec4 c=%s; COLOR=vec4(c.rgb, c.a*clamp((r-%f)/(1.0-%f),0.0,1.0)); }" % [col, inner, inner]
	m.shader = sh
	r.material = m
	root.add_child(r)
	return r

func _button(text: String, primary: bool, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	if primary:
		b.add_theme_font_override("font", _spaced(f_display, 0.14, 26))
		b.add_theme_font_size_override("font_size", 26)
		for st in ["normal", "hover", "focus"]:
			b.add_theme_stylebox_override(st, _pad(_sb(SODIUM, Color(0, 0, 0, 0), 0, 3), 38, 12))
		b.add_theme_stylebox_override("pressed", _pad(_sb(SODIUM.darkened(0.12), Color(0, 0, 0, 0), 0, 3), 38, 12))
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(c, Color("140f08"))
		b.custom_minimum_size = Vector2(0, 56)
	else:
		b.add_theme_font_override("font", _spaced(f_cond_b, 0.16, 16))
		b.add_theme_font_size_override("font_size", 16)
		for st in ["normal", "hover", "focus"]:
			b.add_theme_stylebox_override(st, _pad(_sb(Color(8 / 255.0, 9 / 255.0, 11 / 255.0, 0.55), LINE, 1, 3), 20, 12))
		b.add_theme_stylebox_override("pressed", _pad(_sb(Color(221 / 255.0, 225 / 255.0, 230 / 255.0, 0.14), LINE, 1, 3), 20, 12))
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(c, TEXT)
		b.custom_minimum_size = Vector2(0, 48)
	b.pressed.connect(func(): g.sfx.play("ui_click", 0.18, 0.2); cb.call())
	return b

func _pad(s: StyleBoxFlat, h: int, v: int) -> StyleBoxFlat:
	s.content_margin_left = h
	s.content_margin_right = h
	s.content_margin_top = v
	s.content_margin_bottom = v
	return s

# ---------------------------------------------------------------- play HUD
func _build_play() -> void:
	play = Control.new()
	play.set_anchors_preset(Control.PRESET_FULL_RECT)
	play.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(play)
	# objective
	var ob := VBoxContainer.new()
	ob.name = "Obj"
	ob.position = Vector2(16, 14)
	ob.add_theme_constant_override("separation", 6)
	ob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	obj_t = _label("FIND THE CHILD", _spaced(f_display, 0.05, 28), 28, TEXT)
	_shadow(obj_t, 10)
	obj_s = _label("CHILD LOCATION: UNKNOWN", f_cond, 13, SODIUM, 0.14)
	_shadow(obj_s, 6)
	ob.add_child(obj_t)
	ob.add_child(obj_s)
	play.add_child(ob)
	# compass, awareness eye
	compass = Control.new()
	compass.size = Vector2(180, 22)
	compass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	compass.draw.connect(_draw_compass)
	play.add_child(compass)
	aware = Control.new()
	aware.size = Vector2(34, 18)
	aware.mouse_filter = Control.MOUSE_FILTER_IGNORE
	aware.draw.connect(_draw_aware)
	aware.modulate.a = 0.0
	play.add_child(aware)
	# clue button and pause button
	clue_btn = PanelContainer.new()
	clue_btn.add_theme_stylebox_override("panel", _pad(_sb(GLASS, LINE, 1, 4), 12, 8))
	clue_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ch := HBoxContainer.new()
	ch.add_theme_constant_override("separation", 0)
	ch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cl1 := _label("CLUES ", f_cond, 13, TEXT, 0.14)
	clue_lbl = _label("0", f_cond_b, 13, SODIUM, 0.14)
	var cl3 := _label("/5", f_cond, 13, TEXT, 0.14)
	ch.add_child(cl1)
	ch.add_child(clue_lbl)
	ch.add_child(cl3)
	clue_btn.add_child(ch)
	play.add_child(clue_btn)
	pause_btn = Control.new()
	pause_btn.size = Vector2(40, 36)
	pause_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pause_btn.draw.connect(func():
		pause_btn.draw_style_box(_sb(GLASS, LINE, 1, 4), Rect2(Vector2.ZERO, pause_btn.size))
		pause_btn.draw_rect(Rect2(14.5, 12, 3.5, 12), TEXT)
		pause_btn.draw_rect(Rect2(21, 12, 3.5, 12), TEXT))
	play.add_child(pause_btn)
	# minimap
	map_rect = TextureRect.new()
	map_rect.texture = _map_texture()
	map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	map_rect.stretch_mode = TextureRect.STRETCH_SCALE
	map_rect.size = Vector2(104, 104)
	map_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_mat = ShaderMaterial.new()
	map_mat.shader = load("res://shaders/minimap.gdshader")
	map_rect.material = map_mat
	play.add_child(map_rect)
	map_over = Control.new()
	map_over.size = Vector2(104, 104)
	map_over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_over.draw.connect(_draw_map_over)
	play.add_child(map_over)
	# clue log
	log_panel = PanelContainer.new()
	log_panel.add_theme_stylebox_override("panel", _pad(_sb(Color(8 / 255.0, 9 / 255.0, 11 / 255.0, 0.88), LINE, 1, 4), 16, 14))
	log_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_box = VBoxContainer.new()
	log_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sc.add_child(log_box)
	log_panel.add_child(sc)
	log_panel.visible = false
	play.add_child(log_panel)
	# dialogue choices
	choices_box = VBoxContainer.new()
	choices_box.add_theme_constant_override("separation", 8)
	choices_box.visible = false
	play.add_child(choices_box)
	# subtitles
	subs = RichTextLabel.new()
	subs.bbcode_enabled = true
	subs.fit_content = true
	subs.scroll_active = false
	subs.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subs.add_theme_font_override("normal_font", f_body_m)
	subs.add_theme_font_size_override("normal_font_size", 19)
	subs.add_theme_color_override("default_color", TEXT)
	subs.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	subs.add_theme_constant_override("shadow_outline_size", 10)
	subs.add_theme_constant_override("shadow_offset_y", 2)
	subs.mouse_filter = Control.MOUSE_FILTER_IGNORE
	subs.modulate.a = 0.0
	play.add_child(subs)
	# toast
	toast_box = PanelContainer.new()
	var tsb := _pad(_sb(Color(8 / 255.0, 9 / 255.0, 11 / 255.0, 0.84), LINE, 1, 3), 16, 12)
	tsb.border_width_left = 3
	tsb.border_color = LINE
	toast_box.add_theme_stylebox_override("panel", tsb)
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 4)
	toast_t_lbl = _label("", f_cond_b, 12, SODIUM, 0.16)
	toast_b_lbl = _label("", f_body, 15, TEXT)
	toast_b_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tv.add_child(toast_t_lbl)
	tv.add_child(toast_b_lbl)
	toast_box.add_child(tv)
	toast_box.modulate.a = 0.0
	play.add_child(toast_box)
	# stamina
	stam_bg = ColorRect.new()
	stam_bg.color = Color(221 / 255.0, 225 / 255.0, 230 / 255.0, 0.14)
	stam_bg.size = Vector2(120, 3)
	stam_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stam_fg = ColorRect.new()
	stam_fg.color = TEXT
	stam_fg.size = Vector2(120, 3)
	stam_fg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stam_bg.add_child(stam_fg)
	stam_bg.modulate.a = 0.0
	play.add_child(stam_bg)
	# touch controls
	controls = Control.new()
	controls.set_anchors_preset(Control.PRESET_FULL_RECT)
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	controls.draw.connect(_draw_controls)
	play.add_child(controls)
	for n in ["crouch", "light", "sprint", "use"]:
		buttons[n] = {rect = Rect2(), on = n == "light", hold = false, ready = false, dim = n == "use"}

func _layout() -> void:
	var vs := root.get_viewport_rect().size
	# safe area (notches, rounded corners), converted to canvas units
	var scr := Vector2(DisplayServer.window_get_size())
	var sa := DisplayServer.get_display_safe_area()
	var k := vs.x / maxf(scr.x, 1.0)
	safe = Rect2(maxf(0.0, sa.position.x) * k, maxf(0.0, sa.position.y) * k, maxf(0.0, scr.x - sa.end.x) * k, maxf(0.0, scr.y - sa.end.y) * k)
	if sa.size.x <= 0.0 or sa.size.x > scr.x + 1.0:
		safe = Rect2()
	var L := 16.0 + safe.position.x
	var T := 14.0 + safe.position.y
	var R := safe.size.x
	var B := safe.size.y
	var ob := play.get_node("Obj") as Control
	ob.position = Vector2(L, T)
	obj_t.custom_minimum_size.x = 0
	obj_t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	obj_t.size.x = maxf(160.0, vs.x * 0.5 - 110.0)
	ob.size.x = maxf(160.0, vs.x * 0.5 - 110.0)
	var cw := minf(vs.x * 0.3, 180.0)
	compass.size = Vector2(cw, 22)
	compass.position = Vector2((vs.x - cw) / 2.0, 12.0 + safe.position.y)
	aware.position = Vector2((vs.x - 34.0) / 2.0, 40.0 + safe.position.y)
	pause_btn.position = Vector2(vs.x - 16.0 - R - 40.0, 12.0 + safe.position.y)
	clue_btn.reset_size()
	clue_btn.position = Vector2(vs.x - 64.0 - R - clue_btn.size.x, 12.0 + safe.position.y)
	map_rect.position = Vector2(vs.x - 16.0 - R - 104.0, 58.0 + safe.position.y)
	map_over.position = map_rect.position
	var lw := minf(360.0, vs.x - 32.0)
	log_panel.position = Vector2(vs.x - 16.0 - R - lw, 56.0 + safe.position.y)
	log_panel.size = Vector2(lw, vs.y * 0.52)
	(log_panel.get_child(0) as ScrollContainer).custom_minimum_size = Vector2(lw - 32.0, 0)
	var chw := minf(340.0, vs.x - 32.0)
	_pin_bottom(choices_box, chw, 84.0 + B)
	_pin_bottom(subs, clampf(vs.x - 400.0, 260.0, 560.0), 22.0 + B)
	var tw := minf(vs.x * 0.84, 440.0)
	toast_box.size = Vector2(tw, 0)
	toast_box.position = Vector2((vs.x - tw) / 2.0, 64.0 + safe.position.y)
	stam_bg.position = Vector2((vs.x - 120.0) / 2.0, vs.y - 18.0 - B - 3.0)
	# round buttons, measured from the bottom-right corner like the browser version
	var br := Vector2(vs.x - R, vs.y - B)
	buttons.use.rect = Rect2(br - Vector2(18 + 88, 24 + 88), Vector2(88, 88))
	buttons.sprint.rect = Rect2(br - Vector2(122 + 76, 18 + 76), Vector2(76, 76))
	buttons.light.rect = Rect2(br - Vector2(112 + 64, 112 + 64), Vector2(64, 64))
	buttons.crouch.rect = Rect2(br - Vector2(24 + 66, 128 + 66), Vector2(66, 66))
	if joy_id < 0:
		joy_center = Vector2(92.0 + safe.position.x, vs.y - 120.0 - B)
	for s in screens.values():
		_layout_screen(s)
	controls.queue_redraw()

## Centres c horizontally at width w and pins its bottom edge `bottom` px above the screen's,
## so it grows upward as its content grows.
func _pin_bottom(c: Control, w: float, bottom: float) -> void:
	c.anchor_left = 0.5
	c.anchor_right = 0.5
	c.anchor_top = 1.0
	c.anchor_bottom = 1.0
	c.grow_horizontal = Control.GROW_DIRECTION_BOTH
	c.grow_vertical = Control.GROW_DIRECTION_BEGIN
	c.offset_left = -w / 2.0
	c.offset_right = w / 2.0
	c.offset_bottom = -bottom
	c.offset_top = -bottom

# ---------------------------------------------------------------- drawing
func _draw_compass() -> void:
	var yaw := g.pl.cam_yaw
	var bearing := fmod(rad_to_deg(atan2(sin(yaw), -cos(yaw))) + 360.0, 360.0)
	var w := compass.size.x
	var x0 := w / 2.0 - 45.0 - (360.0 + bearing) * 2.0
	var names := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	for k in 24:
		var n: String = names[k % 8]
		var cx := x0 + 45.0 + 90.0 * k
		if cx < -40.0 or cx > w + 40.0:
			continue
		var edge := clampf(minf(cx, w - cx) / (w * 0.25), 0.0, 1.0)
		var font: Font = f_cond_b if n.length() == 1 else f_cond
		var c := TEXT if n.length() == 1 else Color(TEXT, 0.75)
		c.a *= edge
		var sz := font.get_string_size(n, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
		compass.draw_string(font, Vector2(cx - sz.x / 2.0, 15), n, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, c)
	compass.draw_rect(Rect2(w / 2.0, 17, 1, 5), SODIUM)

func _bez(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, n := 10) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n + 1:
		var t := float(i) / n
		var u := 1.0 - t
		out.append(p0 * u * u * u + p1 * 3.0 * u * u * t + p2 * 3.0 * u * t * t + p3 * t * t * t)
	return out

func _draw_aware() -> void:
	var m := g.mon
	var a := 1.0 if m.state == "CHASE" else m.awareness
	var c := DANGER if m.state == "CHASE" else (SODIUM if m.state == "SEARCH" or m.state == "INVESTIGATE" else TEXT)
	var pts := _bez(Vector2(2, 9), Vector2(8, 1), Vector2(26, 1), Vector2(32, 9))
	pts.append_array(_bez(Vector2(32, 9), Vector2(26, 17), Vector2(8, 17), Vector2(2, 9)))
	aware.draw_polyline(pts, c, 1.6, true)
	aware.draw_circle(Vector2(17, 9), 1.4 + a * 3.2, c)

func _draw_map_over() -> void:
	var R := 52.0
	var zoom := R / 48.0
	var th := PI + g.pl.cam_yaw
	var P := g.pl.pos
	var ctr := Vector2(R, R)
	var to_map := func(x: float, z: float) -> Vector2:
		return ctr + Vector2(x - P.x, z - P.z).rotated(th) * zoom
	map_over.draw_circle(ctr, R - 0.5, LINE, false, 1.0, true)
	var C := g.child
	if C.state in ["follow", "wait", "scared"]:
		var p: Vector2 = to_map.call(C.pos.x, C.pos.z)
		if p.distance_to(ctr) < R - 2.0:
			map_over.draw_circle(p, maxf(1.6 * zoom, 1.5), Color("ffd23a"))
	if g.phase == "escape" and g.exit.size():
		var e: Vector2 = to_map.call(g.exit.x, g.exit.z) - ctr
		if e.length() > R - 4.5:
			e = e.normalized() * (R - 4.5)
		map_over.draw_circle(ctr + e, 3.0, Color(1.0, 70 / 255.0, 40 / 255.0, 0.6 + 0.4 * sin(g.time * 6.0)))
	# player arrow
	var a := g.pl.yaw - g.pl.cam_yaw
	var arrow := PackedVector2Array([Vector2(0, -4.5), Vector2(3, 3.5), Vector2(0, 1.75), Vector2(-3, 3.5)])
	for i in arrow.size():
		arrow[i] = ctr + arrow[i].rotated(-a)
	map_over.draw_colored_polygon(arrow, Color.WHITE)
	# north
	var n := Vector2(sin(th), -cos(th)) * (R - 5.5)
	var sz := f_cond_b.get_string_size("N", HORIZONTAL_ALIGNMENT_LEFT, -1, 9)
	map_over.draw_string(f_cond_b, ctr + n + Vector2(-sz.x / 2.0, 3.2), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, SODIUM)

func _map_texture() -> ImageTexture:
	var S := 520
	var K := S / 260.0
	var img := Image.create(S, S, false, Image.FORMAT_RGBA8)
	img.fill(Color("07080a"))
	var X := func(v: float) -> int: return int((v + 130.0) * K)
	var d := g.data
	var bnd: float = d.BOUND
	img.fill_rect(Rect2i(X.call(-bnd), X.call(-bnd), int(bnd * 2 * K), int(bnd * 2 * K)), Color("4a4d52"))
	var XS: Array = d.XS
	var ZS: Array = d.ZS
	var XW: Array = d.XW
	var ZW: Array = d.ZW
	var swk := 3.2
	var special := {"1,1": "park", "2,2": "plaza"}
	for i in 4:
		for j in 4:
			var x0: float = XS[i] + XW[i] / 2.0 + swk
			var x1: float = XS[i + 1] - XW[i + 1] / 2.0 - swk
			var z0: float = ZS[j] + ZW[j] / 2.0 + swk
			var z1: float = ZS[j + 1] - ZW[j + 1] / 2.0 - swk
			var sp: String = special.get("%d,%d" % [i, j], "")
			img.fill_rect(Rect2i(X.call(x0 - swk), X.call(z0 - swk), int((x1 - x0 + 2 * swk) * K), int((z1 - z0 + 2 * swk) * K)), Color("6b6e73"))
			img.fill_rect(Rect2i(X.call(x0), X.call(z0), int((x1 - x0) * K), int((z1 - z0) * K)), Color("1f3322") if sp == "park" else Color("3a3530") if sp == "plaza" else Color("17191d"))
	var h: Dictionary = d.HOLE
	img.fill_rect(Rect2i(X.call(h.x0), X.call(h.z0), int((h.x1 - h.x0) * K), int((h.z1 - h.z0) * K)), Color("e9a444"))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _icon(n: String, c: Vector2, col: Color) -> void:
	var s := 26.0 / 24.0
	var o := c - Vector2(13, 13)
	var P := func(pts: Array) -> PackedVector2Array:
		var out := PackedVector2Array()
		for p in pts:
			out.append(o + Vector2(p[0], p[1]) * s)
		return out
	var w := 1.8
	match n:
		"crouch":
			controls.draw_arc(o + Vector2(13, 5) * s, 2.0 * s, 0, TAU, 16, col, w, true)
			controls.draw_polyline(P.call([[11, 9], [8, 14], [13, 14], [15, 20]]), col, w, true)
			controls.draw_polyline(P.call([[8, 14], [6, 20]]), col, w, true)
			controls.draw_polyline(P.call([[13, 9], [17, 12]]), col, w, true)
		"light":
			controls.draw_polyline(P.call([[5, 9], [11, 9], [14, 6], [18, 6], [18, 18], [14, 18], [11, 15], [5, 15], [5, 9]]), col, w, true)
			controls.draw_polyline(P.call([[20, 9], [22, 8]]), col, w, true)
			controls.draw_polyline(P.call([[20, 15], [22, 16]]), col, w, true)
			controls.draw_polyline(P.call([[20, 12], [23, 12]]), col, w, true)
		"sprint":
			controls.draw_arc(o + Vector2(15, 4.5) * s, 2.0 * s, 0, TAU, 16, col, w, true)
			controls.draw_polyline(P.call([[9, 21], [12, 15], [9, 12], [12, 8], [15, 11], [19, 11]]), col, w, true)
			controls.draw_polyline(P.call([[12, 15], [16, 16], [17, 21]]), col, w, true)
			controls.draw_polyline(P.call([[6, 11], [9, 8]]), col, w, true)
		"use":
			var hand := [[8, 13], [8, 6], [8.2, 5.2], [9.5, 4.5], [10.8, 5.2], [11, 6], [11, 11], [11, 4.5], [11.2, 3.7], [12.5, 3], [13.8, 3.7], [14, 4.5], [14, 11], [14, 6], [14.2, 5.2], [15.5, 4.5], [16.8, 5.2], [17, 6], [17, 13], [16.6, 16], [15, 18.6], [11, 20], [8, 19], [5, 15], [3.5, 12.5], [3.6, 11.4], [4.6, 10.9], [5.8, 11], [8, 13]]
			controls.draw_polyline(P.call(hand), col, w, true)

func _draw_controls() -> void:
	if not touch:
		return
	# joystick
	var active := joy_id >= 0
	var base_a := 1.0 if active else 0.55
	controls.draw_circle(joy_center, 66, Color(10 / 255.0, 12 / 255.0, 15 / 255.0, 0.22 * base_a))
	controls.draw_circle(joy_center, 66, Color(221 / 255.0, 225 / 255.0, 230 / 255.0, 0.22 * base_a), false, 1.5, true)
	controls.draw_circle(joy_center + joy_knob, 29, Color(221 / 255.0, 225 / 255.0, 230 / 255.0, 0.28 * base_a))
	controls.draw_circle(joy_center + joy_knob, 29, Color(221 / 255.0, 225 / 255.0, 230 / 255.0, 0.45 * base_a), false, 1.5, true)
	# round buttons
	var labels := {crouch = "CROUCH", light = "LIGHT", sprint = "SPRINT", use = use_label}
	for n in buttons:
		var b: Dictionary = buttons[n]
		var r: Rect2 = b.rect
		var c := r.get_center()
		var rad := r.size.x / 2.0
		var fill := Color(10 / 255.0, 12 / 255.0, 15 / 255.0, 0.42)
		var edge := Color(221 / 255.0, 225 / 255.0, 230 / 255.0, 0.3)
		var fg := TEXT
		var alpha := 1.0
		if b.on:
			edge = SODIUM
			fg = SODIUM
			fill = Color(233 / 255.0, 164 / 255.0, 68 / 255.0, 0.13)
		if b.hold:
			fill = Color(221 / 255.0, 225 / 255.0, 230 / 255.0, 0.18)
		if n == "use":
			if b.ready:
				edge = SODIUM
				fill = SODIUM
				fg = Color("15110a")
			elif b.dim:
				alpha = 0.4
		fill.a *= alpha
		edge.a *= alpha
		fg.a *= alpha
		controls.draw_circle(c, rad, fill)
		controls.draw_circle(c, rad - 0.75, edge, false, 1.5, true)
		_icon(n, c - Vector2(0, 7), fg)
		var t: String = labels[n]
		var font := _spaced(f_cond_b, 0.14, 11)
		var sz := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
		controls.draw_string(font, c + Vector2(-sz.x / 2.0, 18), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, fg)

# ---------------------------------------------------------------- API for the game
func sub(who: String, text: String, dur := 3.0) -> void:
	subs.text = "[center][font=%s][font_size=16][color=#e9a444]%s[/color][/font_size][/font]  %s[/center]" % [f_cond_b.resource_path, who, text]
	subs.modulate.a = 1.0
	sub_t = dur

func toast(title: String, body: String, dur := 7.0) -> void:
	toast_t_lbl.text = title.to_upper()
	toast_b_lbl.text = body
	var sb := toast_box.get_theme_stylebox("panel") as StyleBoxFlat
	sb.border_color = LINE
	toast_box.reset_size()
	toast_box.size.x = minf(root.get_viewport_rect().size.x * 0.84, 440.0)
	toast_t = dur

func set_obj(t: String, s: String) -> void:
	obj_t.text = t
	obj_s.text = s.to_upper()

func obj_title() -> String:
	return obj_t.text

func set_clue_count(n: int) -> void:
	clue_lbl.text = str(n)

func set_toggle(n: String, on: bool) -> void:
	buttons[n].on = on
	controls.queue_redraw()

func reset_play() -> void:
	log_panel.visible = false
	hide_choices()
	danger = 0.0
	fade = 0.0
	sub_t = 0.0
	subs.modulate.a = 0.0
	toast_t = 0.0
	toast_box.modulate.a = 0.0
	release_input()

func show_choices(lines: Array) -> void:
	for c in choices_box.get_children():
		c.queue_free()
	for i in lines.size():
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "%d   %s" % [i + 1, lines[i]]
		b.add_theme_font_override("font", f_body_m)
		b.add_theme_font_size_override("font_size", 16)
		b.add_theme_stylebox_override("normal", _pad(_sb(Color(8 / 255.0, 9 / 255.0, 11 / 255.0, 0.78), Color(233 / 255.0, 164 / 255.0, 68 / 255.0, 0.55), 1, 4), 16, 10))
		b.add_theme_stylebox_override("hover", b.get_theme_stylebox("normal"))
		b.add_theme_stylebox_override("pressed", _pad(_sb(Color(233 / 255.0, 164 / 255.0, 68 / 255.0, 0.25), Color(233 / 255.0, 164 / 255.0, 68 / 255.0, 0.55), 1, 4), 16, 10))
		b.custom_minimum_size = Vector2(0, 44)
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		choices_box.add_child(b)
	choices_box.visible = true

func hide_choices() -> void:
	choices_box.visible = false

func refresh_log() -> void:
	if not log_panel.visible:
		return
	for c in log_box.get_children():
		c.queue_free()
	log_box.add_child(_label("WHAT YOU KNOW", f_cond, 12, MUTED, 0.18))
	var got: Array = g.clues.filter(func(c): return c.found)
	got.sort_custom(func(a, b): return a.found_at < b.found_at)
	if got.is_empty():
		var l := _label("Nothing yet. Look for things she left behind, and listen.", f_body, 14, MUTED)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		log_box.add_child(l)
		return
	for c in got:
		log_box.add_child(HSeparator.new())
		log_box.add_child(_label(String(c.title).to_upper(), f_cond, 13, SODIUM, 0.1))
		var p := _label(c.text, f_body, 14, TEXT)
		p.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		log_box.add_child(p)

func release_input() -> void:
	input.jx = 0.0
	input.jy = 0.0
	input.sprint = false
	input.look_dx = 0.0
	input.look_dy = 0.0
	joy_id = -1
	joy_knob = Vector2.ZERO
	looks.clear()
	btn_touch.clear()
	buttons.sprint.hold = false
	_layout()

## Per-frame HUD update while playing (hudUpdate in the browser version).
func update_play(_dt: float) -> void:
	compass.queue_redraw()
	var m := g.mon
	var a := 1.0 if m.state == "CHASE" else m.awareness
	var near := U.hyp(g.pl.pos.x - m.pos.x, g.pl.pos.z - m.pos.z) < 45.0
	aware.modulate.a = 1.0 if a > 0.08 or m.state == "SEARCH" or (m.state == "INVESTIGATE" and near) else 0.0
	aware.queue_redraw()
	cur_act = g.find_interact() if g.phase == "explore" or g.phase == "escape" else {}
	var lbl: String = cur_act.label if cur_act.size() else "USE"
	var rdy := cur_act.size() > 0
	if lbl != use_label or rdy != buttons.use.ready:
		use_label = lbl
		buttons.use.ready = rdy
		buttons.use.dim = not rdy
		controls.queue_redraw()
	# minimap
	map_mat.set_shader_parameter("player", Vector2(g.pl.pos.x, g.pl.pos.z))
	map_mat.set_shader_parameter("theta", PI + g.pl.cam_yaw)
	map_mat.set_shader_parameter("alpha", 0.35 if g.pl.pos.y < -2.0 else 0.9)
	map_over.queue_redraw()
	# stamina
	var st := g.pl.stamina
	stam_bg.modulate.a = move_toward(stam_bg.modulate.a, 1.0 if st < 0.99 else 0.0, _dt / 0.4)
	stam_fg.size.x = 120.0 * st
	stam_fg.color = DANGER if g.pl.exhaust else TEXT

func _process(dt: float) -> void:
	# message timers run on game time, like the rest of the game (capped per frame, stopped while paused)
	var gdt := 0.0 if g.paused else minf(dt, 0.05)
	if sub_t > 0.0:
		sub_t -= gdt
	subs.modulate.a = move_toward(subs.modulate.a, 1.0 if sub_t > 0.0 else 0.0, dt / 0.35)
	if toast_t > 0.0:
		toast_t -= gdt
	toast_box.modulate.a = move_toward(toast_box.modulate.a, 1.0 if toast_t > 0.0 else 0.0, dt / 0.35)
	danger_rect.modulate.a = move_toward(danger_rect.modulate.a, danger, dt / 0.25)
	fade_rect.modulate.a = fade
	if g.phase == "explore" or g.phase == "escape" or g.phase == "dialog":
		_keys()

# ---------------------------------------------------------------- input
func _keys() -> void:
	var r := 1.0 if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT) else 0.0
	var l := 1.0 if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT) else 0.0
	var f := 1.0 if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP) else 0.0
	var b := 1.0 if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN) else 0.0
	input.kx = r - l
	input.ky = f - b
	input.krun = Input.is_key_pressed(KEY_SHIFT) or Input.is_key_pressed(KEY_SPACE)
	input.ksprint = Input.is_key_pressed(KEY_SPACE)

func _playing() -> bool:
	return play.visible and not g.paused and g.phase in ["explore", "escape", "dialog", "caught"]

func _input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		_key(ev)
		return
	if not _playing():
		return
	if ev is InputEventScreenTouch:
		var vs := root.get_viewport_rect().size
		if ev.pressed:
			_touch_down(ev.index, ev.position, vs)
		else:
			_touch_up(ev.index)
		get_viewport().set_input_as_handled()
	elif ev is InputEventScreenDrag:
		if ev.index == joy_id:
			_joy_move(ev.position)
		elif looks.has(ev.index):
			var last: Vector2 = looks[ev.index]
			input.look_dx += ev.position.x - last.x
			input.look_dy += ev.position.y - last.y
			looks[ev.index] = ev.position
		get_viewport().set_input_as_handled()

func _touch_down(i: int, p: Vector2, vs: Vector2) -> void:
	for n in buttons:
		var r: Rect2 = buttons[n].rect
		if touch and p.distance_to(r.get_center()) <= r.size.x / 2.0 + 4.0:
			_press(n, i)
			return
	if Rect2(pause_btn.position, pause_btn.size).grow(4).has_point(p):
		g.set_pause(true)
		return
	if Rect2(clue_btn.position, clue_btn.size).grow(4).has_point(p):
		log_panel.visible = not log_panel.visible
		refresh_log()
		return
	if log_panel.visible and Rect2(log_panel.position, log_panel.size).has_point(p):
		log_panel.visible = false
		return
	if choices_box.visible:
		var k := 0
		for c in choices_box.get_children():
			if Rect2(choices_box.position + c.position, c.size).has_point(p):
				g.choose_line(k)
				return
			k += 1
	if p.y < 70.0:
		return
	if p.x < vs.x * 0.46 and joy_id < 0 and touch:
		joy_id = i
		joy_center = p
		_joy_move(p)
	else:
		looks[i] = p

func _touch_up(i: int) -> void:
	if i == joy_id:
		joy_id = -1
		input.jx = 0.0
		input.jy = 0.0
		joy_knob = Vector2.ZERO
		_layout()
	looks.erase(i)
	if btn_touch.get(i, "") == "sprint":
		input.sprint = false
		buttons.sprint.hold = false
		controls.queue_redraw()
	btn_touch.erase(i)

func _joy_move(p: Vector2) -> void:
	var d := p - joy_center
	if d.length() > JR:
		d = d.normalized() * JR
	joy_knob = d
	input.jx = d.x / JR
	input.jy = -d.y / JR
	controls.queue_redraw()

func _press(n: String, i: int) -> void:
	btn_touch[i] = n
	match n:
		"sprint":
			input.sprint = true
			buttons.sprint.hold = true
		"crouch":
			g.toggle_crouch()
		"light":
			g.toggle_flash()
		"use":
			g.do_interact()
	controls.queue_redraw()

func _key(ev: InputEventKey) -> void:
	var k := ev.keycode
	if k == KEY_ESCAPE or k == KEY_P:
		if screens.settings.visible:
			close_settings()
		elif g.paused:
			g.set_pause(false)
		else:
			g.set_pause(true)
		return
	if g.paused or not play.visible:
		return
	match k:
		KEY_C, KEY_CTRL:
			g.toggle_crouch()
		KEY_F:
			g.toggle_flash()
		KEY_E, KEY_ENTER:
			g.do_interact()
		KEY_1:
			if g.phase == "dialog":
				g.choose_line(0)
		KEY_2:
			if g.phase == "dialog":
				g.choose_line(1)
		KEY_TAB:
			log_panel.visible = not log_panel.visible
			refresh_log()

# ---------------------------------------------------------------- screens
func _screen(name: String, bg: String) -> VBoxContainer:
	var s := Control.new()
	s.name = name
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	s.mouse_filter = Control.MOUSE_FILTER_STOP if bg != "start" else Control.MOUSE_FILTER_IGNORE
	root.add_child(s)
	if bg == "start":
		var tr := TextureRect.new()
		var gt := GradientTexture2D.new()
		var gr := Gradient.new()
		gr.offsets = PackedFloat32Array([0.0, 0.3, 0.62, 1.0])
		gr.colors = PackedColorArray([Color(INK, 0.0), Color(INK, 0.0), Color(INK, 0.55), Color(INK, 0.92)])
		gt.gradient = gr
		gt.fill_from = Vector2(0, 0)
		gt.fill_to = Vector2(0, 1)
		gt.width = 4
		gt.height = 256
		tr.texture = gt
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		s.add_child(tr)
	else:
		var c := ColorRect.new()
		c.color = Color(0, 0, 0, 0.86) if bg == "end" else Color(4 / 255.0, 5 / 255.0, 7 / 255.0, 0.74)
		c.set_anchors_preset(Control.PRESET_FULL_RECT)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		s.add_child(c)
	var v := VBoxContainer.new()
	v.name = "Box"
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.add_child(v)
	s.set_meta("kind", bg)
	screens[name] = s
	return v

func _layout_screen(s: Control) -> void:
	if not s.has_node("Box"):
		return
	# pinned with anchors so the box grows to fit its text: up from the bottom on the start screen,
	# out from the middle on the others
	var v := s.get_node("Box") as VBoxContainer
	var start: bool = s.get_meta("kind") == "start"
	v.anchor_left = 0.0
	v.anchor_right = 1.0
	v.offset_left = 20.0 + safe.position.x
	v.offset_right = -20.0 - safe.size.x
	v.anchor_top = 1.0 if start else 0.5
	v.anchor_bottom = v.anchor_top
	v.grow_vertical = Control.GROW_DIRECTION_BEGIN if start else Control.GROW_DIRECTION_BOTH
	v.offset_bottom = -36.0 - safe.size.y if start else 0.0
	v.offset_top = v.offset_bottom

func _big(text: String, size: int) -> Label:
	var l := _label(text, _spaced(f_display, 0.02, size), size, TEXT)
	l.add_theme_constant_override("line_spacing", -int(size * 0.14))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_outline_size", 16)
	l.add_theme_constant_override("shadow_offset_y", 4)
	return l

func _gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

func _row(btns: Array) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 12)
	for b in btns:
		r.add_child(b)
	return r

func _wrap(l: Label, max_w := 612.0) -> Label:
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = max_w
	l.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return l

var start_records: Label
func _build_start() -> void:
	var v := _screen("start", "start")
	v.add_child(_label("03:12 · PASSING STORMS · CURFEW IN EFFECT", f_cond, 13, SODIUM, 0.24))
	v.add_child(_gap(6))
	v.add_child(_big("LOST CITY", 94))
	v.add_child(_gap(14))
	v.add_child(_wrap(_label("A child is lost somewhere in these streets. Something far larger is out there with her. Find her, keep her close, and get her out of the city.", f_body, 18, TEXT)))
	v.add_child(_gap(12))
	var meta := RichTextLabel.new()
	meta.bbcode_enabled = true
	meta.fit_content = true
	meta.scroll_active = false
	meta.add_theme_font_override("normal_font", _spaced(f_cond_m, 0.08, 14))
	meta.add_theme_font_override("bold_font", _spaced(f_cond, 0.08, 14))
	meta.add_theme_font_size_override("normal_font_size", 14)
	meta.add_theme_font_size_override("bold_font_size", 14)
	meta.add_theme_color_override("default_color", MUTED)
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if touch:
		meta.text = "[color=#dde1e6][b]Left thumb[/b][/color] moves · [color=#dde1e6][b]Right thumb[/b][/color] looks · push the stick all the way to run · headphones on"
	else:
		meta.text = "[color=#dde1e6][b]WASD[/b][/color] walk · [color=#dde1e6][b]Shift[/b][/color] run · [color=#dde1e6][b]Space[/b][/color] sprint · [color=#dde1e6][b]Drag[/b][/color] look · [color=#dde1e6][b]C[/b][/color] crouch · [color=#dde1e6][b]F[/b][/color] light · [color=#dde1e6][b]E[/b][/color] interact"
	v.add_child(meta)
	start_records = _label("", f_cond_m, 14, MUTED, 0.08)
	v.add_child(_gap(6))
	v.add_child(start_records)
	v.add_child(_gap(20))
	v.add_child(_row([_button("START", true, g.start_game), _button("SETTINGS", false, open_settings)]))

var end_eyebrow: Label
var end_title: Label
var end_sub: Label
var end_stats: Label
var again_btn: Button
func _build_end() -> void:
	var v := _screen("end", "end")
	end_eyebrow = _label("", f_cond, 13, SODIUM, 0.24)
	end_title = _big("YOU WERE FOUND", 66)
	end_sub = _wrap(_label("", f_body, 18, TEXT))
	end_stats = _label("", f_cond, 14, MUTED, 0.14)
	again_btn = _button("TRY AGAIN", true, g.start_game)
	for c in [end_eyebrow, _gap(6), end_title, _gap(16), end_sub, _gap(14), end_stats, _gap(22), _row([again_btn, _button("MENU", false, g.to_menu)])]:
		v.add_child(c)

var pause_info: Label
func _build_pause() -> void:
	var v := _screen("pause", "pause")
	pause_info = _label("PAUSED", f_cond, 13, SODIUM, 0.24)
	for c in [pause_info, _gap(6), _big("PAUSED", 66), _gap(22), _row([_button("RESUME", true, func(): g.set_pause(false)), _button("SETTINGS", false, open_settings), _button("RESTART", false, g.start_game), _button("MENU", false, g.to_menu)])]:
		v.add_child(c)

func _build_settings() -> void:
	var s := Control.new()
	s.name = "settings"
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	s.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(s)
	screens.settings = s
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: close_settings())
	s.add_child(dim)
	var center := CenterContainer.new()
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	s.add_child(center)
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _pad(_sb(Color("0c0e11"), LINE, 1, 6), 20, 14))
	box.custom_minimum_size = Vector2(400, 0)
	center.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	box.add_child(v)
	v.add_child(_label("SETTINGS", _spaced(f_display, 0.06, 26), 26, TEXT))
	v.add_child(_gap(4))
	set_ctrls.vol = _slider_row(v, "VOLUME", 0, 100, 5, func(x): g.settings.vol = x; g.sfx.set_master(x / 100.0), func(x): return "%d%%" % x)
	set_ctrls.rain = _slider_row(v, "RAIN SOUND", 0, 100, 5, func(x): g.settings.rain = x, func(x): return "%d%%" % x)
	set_ctrls.sens = _slider_row(v, "LOOK SPEED", 40, 200, 10, func(x): g.settings.sens = x, func(x): return "%.1f×" % (x / 100.0))
	# graphics
	var gr := _set_row(v, "GRAPHICS")
	var seg := HBoxContainer.new()
	seg.add_theme_constant_override("separation", 0)
	set_ctrls.gfx = {}
	for q in ["auto", "low", "high"]:
		var b := Button.new()
		b.text = q.to_upper()
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_override("font", _spaced(f_cond_b, 0.12, 13))
		b.add_theme_font_size_override("font_size", 13)
		b.add_theme_stylebox_override("normal", _pad(_sb(Color(0, 0, 0, 0), LINE, 1, 0), 12, 6))
		b.add_theme_stylebox_override("hover", _pad(_sb(Color(0, 0, 0, 0), LINE, 1, 0), 12, 6))
		b.add_theme_stylebox_override("pressed", _pad(_sb(SODIUM, SODIUM, 1, 0), 12, 6))
		b.add_theme_stylebox_override("hover_pressed", _pad(_sb(SODIUM, SODIUM, 1, 0), 12, 6))
		b.add_theme_color_override("font_color", MUTED)
		b.add_theme_color_override("font_hover_color", MUTED)
		b.add_theme_color_override("font_pressed_color", Color("140f08"))
		b.add_theme_color_override("font_hover_pressed_color", Color("140f08"))
		b.custom_minimum_size = Vector2(0, 32)
		b.pressed.connect(func():
			var was_low: bool = g.settings.gfx == "low"
			g.settings.gfx = q
			g.low_q = false
			g.q1 = false
			g.apply_gfx()
			_sync_settings())
		seg.add_child(b)
		set_ctrls.gfx[q] = b
	gr.add_child(seg)
	# vibration
	var vr := _set_row(v, "VIBRATION")
	var cb := CheckBox.new()
	cb.focus_mode = Control.FOCUS_NONE
	cb.toggled.connect(func(on): g.settings.vib = on; if on: g.buzz(30))
	vr.add_child(cb)
	set_ctrls.vib = cb
	v.add_child(_gap(12))
	var done := _button("DONE", true, close_settings)
	done.add_theme_font_size_override("font_size", 22)
	v.add_child(done)
	s.visible = false

func _set_row(v: VBoxContainer, name: String) -> HBoxContainer:
	v.add_child(HSeparator.new())
	var r := HBoxContainer.new()
	r.custom_minimum_size = Vector2(0, 40)
	r.add_theme_constant_override("separation", 14)
	var l := _label(name, f_cond, 15, TEXT, 0.1)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	r.add_child(l)
	v.add_child(r)
	return r

func _slider_row(v: VBoxContainer, name: String, lo: float, hi: float, step: float, on_change: Callable, fmt: Callable) -> Dictionary:
	var r := _set_row(v, name)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = step
	sl.custom_minimum_size = Vector2(170, 28)
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.focus_mode = Control.FOCUS_NONE
	sl.add_theme_stylebox_override("slider", _sb(Color(1, 1, 1, 0.14), Color(0, 0, 0, 0), 0, 2))
	var fill := _sb(SODIUM, Color(0, 0, 0, 0), 0, 2)
	sl.add_theme_stylebox_override("grabber_area", fill)
	sl.add_theme_stylebox_override("grabber_area_highlight", fill)
	var out := _label("", f_cond_m, 15, MUTED, 0.1)
	out.custom_minimum_size = Vector2(48, 0)
	out.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	out.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sl.value_changed.connect(func(x):
		on_change.call(x)
		out.text = fmt.call(x))
	r.add_child(sl)
	r.add_child(out)
	return {slider = sl, out = out, fmt = fmt}

func _sync_settings() -> void:
	for k in ["vol", "rain", "sens"]:
		var c: Dictionary = set_ctrls[k]
		c.slider.set_value_no_signal(float(g.settings[k]))
		c.out.text = c.fmt.call(float(g.settings[k]))
	for q in set_ctrls.gfx:
		set_ctrls.gfx[q].set_pressed_no_signal(g.settings.gfx == q)
	set_ctrls.vib.set_pressed_no_signal(bool(g.settings.vib))

func open_settings() -> void:
	_sync_settings()
	screens.settings.visible = true
	_layout_screen(screens.settings)

func close_settings() -> void:
	screens.settings.visible = false
	g.save_settings()

func show_screen(name: String) -> void:
	for k in ["start", "end", "pause"]:
		screens[k].visible = k == name
	screens.settings.visible = false
	play.visible = name == "hud"
	vignette.visible = true
	if name == "start":
		fade = 0.0
		danger = 0.0
		var r: Dictionary = g.records
		if int(r.runs) > 0:
			start_records.text = "%d RESCUED IN %d %s" % [int(r.wins), int(r.runs), "ATTEMPT" if int(r.runs) == 1 else "ATTEMPTS"]
			if float(r.best) > 0.0:
				start_records.text += " · BEST RESCUE " + U.fmt_t(float(r.best))
			start_records.visible = true
		else:
			start_records.visible = false
	for k in screens:
		_layout_screen(screens[k])

func show_end(eyebrow: String, title: String, body: String, stats: String, again: String) -> void:
	end_eyebrow.text = eyebrow.to_upper()
	end_title.text = title
	end_sub.text = body
	end_stats.text = stats.to_upper()
	again_btn.text = again
	show_screen("end")

func show_pause(info: String) -> void:
	pause_info.text = info.to_upper()
	show_screen("pause")
