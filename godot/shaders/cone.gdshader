// Faint light shafts under street lamps.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform vec3 tint = vec3(1.0, 0.65, 0.31);
varying float vd;
void vertex() {
	vd = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}
void fragment() {
	float f = abs(dot(NORMAL, VIEW));
	float a = pow(UV.y, 1.6) * pow(f, 1.5) * 0.075 * exp(-vd * 0.016) * smoothstep(0.0, 3.0, vd);
	ALBEDO = tint * a;
}
