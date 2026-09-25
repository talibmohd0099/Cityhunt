// Soft pools of lamp light on the ground.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, shadows_disabled;
uniform sampler2D tex : filter_linear;
void fragment() {
	if ((CAMERA_VISIBLE_LAYERS & uint(1 << 19)) != uint(0)) { discard; }
	ALBEDO = COLOR.rgb * texture(tex, UV).a;
}
