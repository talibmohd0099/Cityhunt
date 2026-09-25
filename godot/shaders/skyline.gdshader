// Distant skyline: dark towers with lit windows fading into the haze.
shader_type spatial;
render_mode unshaded, fog_disabled, shadows_disabled;
uniform sampler2D emi : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 hor = vec3(0.098, 0.098, 0.112);
uniform float flash = 0.0;
varying float vf;
varying float vy;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float d = length(wp.xz - INV_VIEW_MATRIX[3].xz);
	vf = 1.0 - exp(-d * 0.0026); vy = wp.y;
}
void fragment() {
	vec3 e = texture(emi, UV).rgb;
	vec3 c = vec3(0.03, 0.032, 0.038) + e * 0.75;
	float f = clamp(vf * 0.92 + (1.0 - smoothstep(0.0, 60.0, vy)) * 0.25, 0.0, 1.0);
	ALBEDO = mix(c, hor, f) - flash * 0.02;
}
