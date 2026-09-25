// The flashlight's visible beam in the rain: brightest a little way out from the lens, fading along
// its length and toward the edges.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform float intensity = 1.0;
varying float vz;
void vertex() {
	vz = -VERTEX.z / 16.0;
}
void fragment() {
	float f = abs(dot(NORMAL, VIEW));
	float z = clamp(vz, 0.0, 1.0);
	float a = intensity * pow(1.0 - z, 1.6) * smoothstep(0.03, 0.22, z) * pow(f, 1.4) * 0.11;
	ALBEDO = vec3(1.0, 0.95, 0.86) * a;
}
