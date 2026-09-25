// The evacuation truck's searchlight: a tall faint shaft of light over the exit.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
varying float vt;
void vertex() {
	vt = (VERTEX.y + 90.0) / 180.0;
}
void fragment() {
	float f = abs(dot(NORMAL, VIEW));
	float a = (1.0 - vt) * 0.14 * f * f;
	ALBEDO = vec3(0.85, 0.9, 1.0) * a;
}
