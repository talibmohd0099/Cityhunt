// Building facades: painted facade atlas tinted per building, lit windows, close-up brick relief,
// glossy window glass, and walls darkened by rain running down them.
shader_type spatial;
render_mode cull_back;
uniform sampler2D facade : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D facade_emi : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D brick : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D brick_n : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D streaks : filter_linear_mipmap, repeat_enable;
uniform float emi_strength = 1.0;
uniform float brick_on = 1.0;
global uniform float rain_amount;
#include "res://shaders/refl_clip.gdshaderinc"
varying float wy;
void vertex() {
	wy = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}
void fragment() {
	REFL_CLIP
	vec4 tx = texture(facade, UV);
	vec3 base = tx.rgb * COLOR.rgb;
	vec2 bu = UV * vec2(64.0, 56.0) / 1.7;
	vec3 br = texture(brick, bu).rgb;
	float d = max(length(dFdx(bu)), length(dFdy(bu)));
	float lum = dot(tx.rgb, vec3(0.3333));
	float wall = smoothstep(0.1, 0.22, lum) * (1.0 - smoothstep(0.08, 0.3, d)) * brick_on;
	float amt = smoothstep(1.15, 1.32, COLOR.r / max(COLOR.g, 0.01));
	float grime = clamp(lum / 0.36, 0.4, 1.2);
	vec4 bn = texture(brick_n, bu);
	base = mix(base, mix(base * (0.7 + 0.6 * dot(br, vec3(0.3333)) / 0.25), br * 1.25 * grime, amt), wall);
	base *= mix(1.0, bn.b, wall * (0.4 + 0.6 * amt));
	// window panes are the darkest, bluish parts of the atlas
	float glass = smoothstep(0.03, 0.012, lum) * step(tx.r, tx.b + 0.004);
	// rain: water runs down in streaks and the bottom of the wall is splashed
	float wetw = texture(streaks, bu / 6.0).r * rain_amount;
	float foot = (1.0 - smoothstep(0.15, 0.8, wy)) * rain_amount;
	float wet = clamp(wetw * 1.2 + foot * 0.6, 0.0, 1.0) * (1.0 - glass);
	ALBEDO = base * (1.0 - 0.3 * wet);
	ROUGHNESS = mix(mix(0.84, 0.4, wet), 0.06, glass);
	METALLIC = 0.05;
	SPECULAR = mix(0.5, 0.9, glass);
	EMISSION = texture(facade_emi, UV).rgb * emi_strength;
	// brick relief, in the wall's own texture directions (fades out where the bricks get too small)
	float relief = wall * (0.35 + 0.65 * amt) * (1.0 - smoothstep(0.04, 0.15, d));
	if (relief > 0.001) {
		vec3 dp1 = dFdx(VERTEX), dp2 = dFdy(VERTEX);
		vec2 du1 = dFdx(bu), du2 = dFdy(bu);
		vec3 p2 = cross(dp2, NORMAL), p1 = cross(NORMAL, dp1);
		vec3 T = p2 * du1.x + p1 * du2.x;
		vec3 B = p2 * du1.y + p1 * du2.y;
		float im = inversesqrt(max(max(dot(T, T), dot(B, B)), 1e-12));
		vec2 n = (bn.rg * 2.0 - 1.0) * vec2(1.0, -1.0) * relief;
		NORMAL = normalize(T * im * n.x + B * im * n.y + NORMAL);
	}
}
