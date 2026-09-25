// Night-time building: a grid of windows, some lit, a shop floor with a glowing sign, drawn from the
// box's own local position (metres), so any building size works. Colour and lighting pattern per
// building come from instance uniforms.
shader_type spatial;
render_mode diffuse_burley;
instance uniform vec3 wall = vec3(0.22, 0.2, 0.19);
instance uniform float seed = 0.0;
instance uniform float height = 20.0;
instance uniform vec3 sign_col = vec3(1.0, 0.3, 0.2);
global uniform float rain_amount;
varying vec3 lp;
varying vec3 ln;
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7)) + seed * 17.13) * 43758.5453);
}
void vertex() {
	lp = VERTEX;
	ln = NORMAL;
}
void fragment() {
	float u = abs(ln.x) > 0.5 ? lp.z : lp.x;
	float v = lp.y + height * 0.5;              // height above the pavement
	vec3 col = wall;
	vec3 emi = vec3(0.0);
	float rough = 0.85;
	if (abs(ln.y) > 0.5) {
		col *= 0.4;                              // roof
	} else if (v > 4.4) {
		// upper floors: 3 m bays, 3.3 m storeys
		vec2 g = vec2(u / 3.0, (v - 4.4) / 3.3);
		vec2 c = floor(g);
		vec2 f = fract(g);
		float win = step(0.26, f.x) * step(f.x, 0.74) * step(0.3, f.y) * step(f.y, 0.84);
		float h = hash(c);
		float lit = step(0.72, h) * win;
		vec3 warm = mix(vec3(1.0, 0.62, 0.3), vec3(0.6, 0.72, 1.0), step(0.93, h));
		col = mix(col, vec3(0.02, 0.025, 0.03), win);
		rough = mix(rough, 0.08, win);
		emi = warm * lit * (0.25 + 0.6 * fract(h * 7.1)) * (0.7 + 0.3 * f.y);
		// a floor band between storeys
		col *= 1.0 - 0.25 * (1.0 - step(0.08, f.y));
		// rain runs down the wall
		col *= 1.0 - 0.25 * rain_amount;
	} else {
		// ground floor: shop windows and a sign above them
		float bay = floor(u / 6.0);
		float f = fract(u / 6.0);
		float h = hash(vec2(bay, 91.0));
		float glass = step(0.1, f) * step(f, 0.9) * step(0.35, v) * step(v, 3.0);
		float sgn = step(0.18, f) * step(f, 0.82) * step(3.3, v) * step(v, 3.95) * step(0.3, h);
		col = mix(col * 0.7, vec3(0.02), glass);
		rough = mix(rough, 0.1, glass);
		emi = glass * step(0.45, h) * vec3(0.9, 0.72, 0.5) * 0.25;
		vec3 sc = mix(sign_col, sign_col.brg, step(0.65, h));
		emi += sgn * sc * 1.6;
	}
	ALBEDO = col;
	ROUGHNESS = rough;
	EMISSION = emi;
}
