// Final colour grade from the browser version: cool shadows, warm highlights, slightly muted colour,
// a little contrast, film grain and faint colour fringing toward the edges.
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float grain = 0.045;
uniform float ca = 0.0007;
vec3 to_linear(vec3 s) { return mix(pow((s + 0.055) / 1.055, vec3(2.4)), s / 12.92, step(s, vec3(0.04045))); }
void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 d = uv - 0.5;
	vec3 c = vec3(texture(screen_tex, uv + d * ca * 2.0).r, texture(screen_tex, uv).g, texture(screen_tex, uv - d * ca * 2.0).b);
	c = to_linear(c);
	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = mix(c, c * vec3(0.9, 1.02, 1.1), smoothstep(0.3, 0.0, l) * 0.55);
	c = mix(c, c * vec3(1.07, 1.0, 0.9), smoothstep(0.35, 0.95, l) * 0.45);
	c = mix(vec3(l), c, 0.9);
	vec3 s = mix(pow(max(c, 0.0), vec3(0.41666)) * 1.055 - 0.055, c * 12.92, step(c, vec3(0.0031308)));
	s = (s - 0.5) * 1.12 + 0.48;
	float g = fract(sin(dot(uv * vec2(1731.0, 977.0) + fract(TIME * 7.13) * 91.0, vec2(12.9898, 78.233))) * 43758.5453);
	s += (g - 0.5) * grain;
	COLOR = vec4(s, 1.0);
}
