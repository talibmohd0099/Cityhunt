// Raindrops hitting the ground near the camera: tiny glints that appear for a moment and move on.
// Positions repeat every 28 m in world space, so they stay put while the camera walks through them.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform sampler2D tex : filter_linear;
uniform sampler2D ground_mask : filter_nearest;   // r: raised sidewalk or floor, g: indoors
uniform vec4 mask_rect = vec4(-120.0, -120.0, 240.0, 240.0);
uniform float amount = 0.65;
uniform vec3 color = vec3(0.667, 0.714, 0.776);
varying float fade;
float h(float n) { return fract(sin(n) * 43758.5453); }
void vertex() {
	vec4 s = COLOR;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	float p = 0.08 + 0.22 * s.g;
	float k = floor(TIME / p + s.b);
	fade = 1.0 - fract(TIME / p + s.b);
	vec2 o = vec2(h(k * 12.9898 + s.r * 78.233), h(k * 39.346 + s.r * 11.135)) * 28.0;
	vec2 lo = cam.xz - 14.0;
	vec2 xz = lo + mod(o - lo, 28.0);
	vec2 m = textureLod(ground_mask, (xz - mask_rect.xy) / mask_rect.zw, 0.0).rg;
	vec3 w = vec3(xz.x, m.r > 0.5 ? 0.17 : 0.03, xz.y);
	if (s.a > amount || m.g > 0.5) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		vec3 v = (VIEW_MATRIX * vec4(w, 1.0)).xyz + vec3(UV * 0.028, 0.0);
		POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
	}
}
void fragment() {
	ALBEDO = color * texture(tex, UV * 0.5 + 0.5).a * 0.5 * fade;
}
