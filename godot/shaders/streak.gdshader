// Long reflections of lights on the wet street, turned toward the camera.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform sampler2D tex : filter_linear;
uniform float len = 10.0;
global uniform float rain_amount;
void vertex() {
	vec3 o = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec2 to = cam.xz - o.xz;
	float d = length(to) + 0.001;
	vec2 f = to / d;
	vec2 rgt = vec2(f.y, -f.x);
	float sc = (d > 120.0 || cam.y < -1.0) ? 0.0 : 1.0;
	float lz = sc * clamp(d / 25.0, 0.35, 1.2);
	vec2 c = o.xz + f * (len / 2.0 + 0.6);
	vec2 p = c + rgt * VERTEX.x * sc + f * VERTEX.z * lz;
	vec3 w = vec3(p.x, 0.16, p.y);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(w, 1.0);
}
void fragment() {
	if ((CAMERA_VISIBLE_LAYERS & uint(1 << 19)) != uint(0)) { discard; }
	ALBEDO = COLOR.rgb * texture(tex, UV).a * (0.46 + 0.83 * rain_amount);
}
