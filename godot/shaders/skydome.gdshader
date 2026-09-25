// Night sky with drifting storm clouds that light up with lightning.
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, fog_disabled, shadows_disabled;
uniform vec3 hor = vec3(0.098, 0.098, 0.112);
uniform float flash = 0.0;
varying vec3 dir;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) { vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y); }
float fbm(vec2 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 4; i++) { v += a * noise(p); p *= 2.03; a *= 0.5; } return v; }
void vertex() { dir = VERTEX; }
void fragment() {
	vec3 d = normalize(dir); float h = d.y;
	vec3 zen = vec3(0.012, 0.014, 0.02);
	vec3 c = mix(hor, zen, smoothstep(0.0, 0.5, h));
	if (h > 0.0) {
		vec2 uv = d.xz / (h + 0.12) * 0.8 + vec2(TIME * 0.006, TIME * 0.003);
		float cl = smoothstep(0.38, 0.85, fbm(uv * 1.4));
		vec3 lit = vec3(0.12, 0.095, 0.08) * (1.0 - smoothstep(0.0, 0.7, h) * 0.7);
		c = mix(c, lit, cl * 0.8);
		c += flash * vec3(0.5, 0.55, 0.72) * (0.2 + cl * 1.1);
	} else c = hor;
	ALBEDO = c;
	DEPTH = 0.0;
}
