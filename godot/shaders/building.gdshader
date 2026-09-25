// Building facades: painted facade atlas tinted per building, lit windows, and close-up brick detail.
shader_type spatial;
render_mode cull_back;
uniform sampler2D facade : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D facade_emi : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D brick : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float emi_strength = 1.0;
uniform float brick_on = 1.0;
#include "res://shaders/refl_clip.gdshaderinc"
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
	base = mix(base, mix(base * (0.7 + 0.6 * dot(br, vec3(0.3333)) / 0.25), br * 1.25 * grime, amt), wall);
	ALBEDO = base;
	ROUGHNESS = 0.84;
	METALLIC = 0.05;
	EMISSION = texture(facade_emi, UV).rgb * emi_strength;
	float h0 = dot(texture(brick, bu, 1.5).rgb, vec3(0.3333));   // bias, like texture2D(..., 1.5) in the browser
	vec2 dh = vec2(dFdx(h0), dFdy(h0)) * (0.3 + 0.7 * amt) * wall * (1.0 - smoothstep(0.04, 0.15, d)) * 0.8;
	vec3 sx = dFdx(VERTEX), sy = dFdy(VERTEX);
	vec3 r1 = cross(sy, NORMAL), r2 = cross(NORMAL, sx);
	float det = dot(sx, r1);
	vec3 g = sign(det) * (dh.x * r1 + dh.y * r2);
	NORMAL = normalize(abs(det) * NORMAL - g);
}
