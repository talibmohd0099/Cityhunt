// Round minimap: the city texture (covering -130..130 m) turned so the camera's view points up,
// 48 m from the centre to the rim, over a dark glass disc.
shader_type canvas_item;

uniform vec2 player;
uniform float theta;
uniform float alpha = 0.9;

void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float r = length(q);
	float disc = 1.0 - smoothstep(0.975, 0.995, r);
	vec2 v = q * 48.0;
	float c = cos(theta), s = sin(theta);
	vec2 w = player + vec2(c * v.x + s * v.y, -s * v.x + c * v.y);
	vec2 uv = (w + 130.0) / 260.0;
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	vec4 m = texture(TEXTURE, uv);
	vec4 bg = vec4(8.0, 9.0, 11.0, 0.55 * 255.0) / 255.0;
	float a = alpha * inside;
	COLOR = vec4(mix(bg.rgb, m.rgb, a), (1.0 - (1.0 - bg.a) * (1.0 - a)) * disc);
}
