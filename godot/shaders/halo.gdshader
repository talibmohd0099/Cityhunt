// Glowing light points (street lamps, windows far away, police lights) that shine through the fog.
// Each MultiMesh instance is a camera-facing quad sized in screen pixels like the browser version.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;
uniform float att = 0.0048;
varying vec3 col;
varying float alpha;
void vertex() {
	vec3 center = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float d = max(-center.z, 0.1);
	float scale = VIEWPORT_SIZE.y * abs(PROJECTION_MATRIX[1][1]) * 0.5;   // the Vulkan projection flips y
	float size = INSTANCE_CUSTOM.x;
	float px = clamp(size * scale / d, 1.5, 300.0);
	alpha = exp(-d * att) * min(1.0, (size * scale / d) / 1.5);
	col = COLOR.rgb;
	vec3 v = center + vec3(VERTEX.xy * px * d / scale, 0.0);
	POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
}
void fragment() {
	vec2 c = UV - 0.5;
	float r = dot(c, c) * 4.0;
	float a = exp(-r * 9.0) + 0.28 * exp(-r * 2.2);
	a *= 1.0 - smoothstep(0.75, 1.0, r);
	ALBEDO = col * a * alpha;
}
