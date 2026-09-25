// Soft dark patch under each parked car, where the body blocks the sky and the street lights
// (the contact shadow the lamps don't cast). Multiplies whatever is drawn below it.
shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform float strength = 0.72;
varying vec2 k;
void vertex() {
	k = INSTANCE_CUSTOM.xy;                 // how far in from each edge the full shadow starts (0..1)
}
void fragment() {
	// UV spans the patch; the car covers the middle, the shadow fades out past its edges
	vec2 q = abs(UV * 2.0 - 1.0);
	vec2 e = smoothstep(vec2(1.0), 1.0 - k, q);
	float a = e.x * e.y;
	ALBEDO = vec3(1.0 - strength * a * a);
}
