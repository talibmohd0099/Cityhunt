// Paint and glass of the real car models: clear-coated, wet, with rain beads sitting on the panels.
// The colour (and the police livery) is set per car with instance uniforms, so every car shares one material.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
instance uniform vec3 paint = vec3(0.5);       // linear colour
instance uniform float livery = 0.0;           // 1: police, white doors
uniform bool glass = false;
uniform bool use_vcolor = false;               // the simpler built-in vans and buses: colour per vertex, glass is the near-black parts
uniform bool far = false;                      // distant stand-in: vertex alpha 1 paint, 0.5 glass, 0 dark trim
uniform sampler2D drops_tex : filter_linear_mipmap, repeat_enable;
uniform vec4 band = vec4(-1.35, 1.2, 0.5, 1.02);   // police door band in model space: x from, x to, y from, y to
global uniform float rain_amount;
varying vec3 lpos;
varying vec3 lnrm;

void vertex() {
	lpos = VERTEX;
	lnrm = NORMAL;
}

void fragment() {
	vec3 c = paint;
	bool is_glass = glass;
	bool trim = false;
	if (use_vcolor) {
		c = COLOR.rgb;
		is_glass = max(c.r, max(c.g, c.b)) < 0.025;
	} else if (far) {
		is_glass = COLOR.a > 0.25 && COLOR.a < 0.75;
		trim = COLOR.a < 0.25;
	}
	if (livery > 0.5) {
		float b = step(band.x, lpos.x) * step(lpos.x, band.y) * step(band.z, lpos.y) * step(lpos.y, band.w);
		c = mix(c, vec3(0.8, 0.8, 0.78), b);
	}
	// beads: projected from above and from the sides, following the panel's facing (4 mm to 3 cm)
	vec3 an = abs(lnrm);
	vec3 w = an * an;
	w /= w.x + w.y + w.z;
	vec2 dy = texture(drops_tex, lpos.xz * 4.0).rg * 2.0 - 1.0;
	vec2 dx = texture(drops_tex, lpos.zy * vec2(4.0, 2.6) + 0.37).rg * 2.0 - 1.0;
	vec2 dz = texture(drops_tex, lpos.xy * vec2(4.0, 2.6) + 0.71).rg * 2.0 - 1.0;
	vec3 off = w.y * vec3(dy.x, 0.0, dy.y) + w.x * vec3(0.0, dx.y, dx.x) + w.z * vec3(dz.x, dz.y, 0.0);
	float wet = rain_amount * (0.55 + 0.45 * w.y);
	off *= wet * 0.9;
	float bead = smoothstep(0.02, 0.2, length(off));
	vec3 n = normalize(lnrm + off);
	if (!FRONT_FACING) {   // the inside of an open door
		n = -lnrm;
		trim = true;
	}
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(n, 0.0)).xyz);
	if (trim) {
		ALBEDO = vec3(0.004);
		METALLIC = 0.2;
		ROUGHNESS = 0.6;
	} else if (is_glass) {
		ALBEDO = vec3(0.006, 0.008, 0.01);
		METALLIC = 0.8;
		ROUGHNESS = 0.04;
		CLEARCOAT = 1.0;
		CLEARCOAT_ROUGHNESS = 0.03;
	} else {
		// water darkens the paint a little and keeps the coat glossy
		ALBEDO = c * (1.0 - 0.18 * wet);
		METALLIC = 0.45;
		ROUGHNESS = mix(0.3, 0.12, bead);
		CLEARCOAT = 1.0;
		CLEARCOAT_ROUGHNESS = 0.05;
	}
}
