// Falling rain: thin streaks that always surround the camera (from Lost City). The car's speed makes
// the drops rush past and slant towards the camera.
// Every drop is 6 vertices at the origin; COLOR holds its random seed and UV which corner it is.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
uniform float amount = 0.65;
uniform vec3 color = vec3(0.604, 0.663, 0.741);
uniform float travel = 0.0;   // metres driven
uniform float slant = 0.0;    // how far the streak leans back (car speed / drop speed)
void vertex() {
	vec4 s = COLOR;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	float v = 19.0 + 6.0 * fract(s.a * 7.31 + s.r * 3.1);
	float y = 16.0 - mod(TIME * v + s.g * 24.0, 24.0);
	float x = mod(s.r * 40.0 + TIME * 0.64, 40.0) - 20.0;
	float z = mod(s.b * 40.0 + travel, 40.0) - 30.0;
	vec3 base = cam + vec3(x, y, z);
	vec3 top = base + vec3(-0.032, 0.55, -0.55 * slant);
	vec4 cb = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(base, 1.0));
	vec4 ct = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(top, 1.0));
	if (s.a > amount || cb.w < 0.2 || ct.w < 0.2) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		vec2 d = (ct.xy / ct.w - cb.xy / cb.w) * VIEWPORT_SIZE;
		vec2 n = normalize(vec2(-d.y, d.x) + vec2(1e-5, 0.0));
		vec4 c = UV.y > 0.5 ? ct : cb;
		c.xy += n * UV.x * (1.2 / VIEWPORT_SIZE) * c.w;
		POSITION = c;
	}
}
void fragment() {
	ALBEDO = color;
	ALPHA = 0.08 + 0.1 * amount;
}
