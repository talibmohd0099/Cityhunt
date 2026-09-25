// Wet road and sidewalk. Each 10 m piece carries its own texture coordinates (its local position),
// so the texture travels with the piece as the street scrolls past the car.
// The detail map packs normal x/y, roughness and height; rain water fills the low parts.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float tile = 2.5;           // metres per texture repeat
uniform float gain = 1.0;
uniform bool markings = false;      // road: lane lines, edge lines and the double yellow centre line
uniform float x_offset = 0.0;       // sidewalk pieces: where their middle sits across the street
global uniform float rain_amount;
varying vec3 lp;
void vertex() {
	lp = VERTEX;
}
void fragment() {
	vec2 uv = vec2(lp.x + x_offset, lp.z) / tile;
	vec3 a = texture(albedo_tex, uv).rgb * gain;
	vec4 t = texture(detail_tex, uv);
	float r = t.b;
	float paint = 0.0;
	vec3 paint_col = vec3(0.78, 0.77, 0.72);
	if (markings) {
		float x = abs(lp.x);
		float z = lp.z + 5.0;                                   // 0..10 along the piece
		float dash = step(mod(z, 10.0), 3.2);
		float lane = (1.0 - smoothstep(0.07, 0.09, abs(x - 3.5))) * dash;
		float edge = 1.0 - smoothstep(0.08, 0.1, abs(x - 6.7));
		float centre = 1.0 - smoothstep(0.055, 0.075, abs(x - 0.15));
		paint = max(max(lane, edge), centre);
		paint_col = mix(paint_col, vec3(0.85, 0.58, 0.1), centre);
		// worn paint: the asphalt shows through in places
		paint *= smoothstep(0.15, 0.45, t.a + 0.2);
	}
	// water stands in the low spots and runs along the kerbs
	float level = 0.2 + 0.2 * rain_amount;
	float gutter = markings ? smoothstep(6.3, 6.95, abs(lp.x)) * 0.8 : 0.0;
	float standing = max(smoothstep(level + 0.05, level - 0.05, t.a), gutter) * (1.0 - paint);
	vec2 nxy = (t.rg * 2.0 - 1.0) * (1.0 - standing);
	vec3 n = normalize(vec3(nxy.x, sqrt(max(1.0 - dot(nxy, nxy), 0.0)), -nxy.y));
	a = mix(a, paint_col, paint * 0.85);
	a *= 1.0 - 0.35 * rain_amount - 0.3 * standing;
	r = mix(r * 0.5, 0.35, paint);
	r = mix(r, 0.02, standing);
	ALBEDO = a;
	ROUGHNESS = r;
	SPECULAR = 0.6;
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(n, 0.0)).xyz);
}
