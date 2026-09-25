// Vertex-coloured props and cars.
shader_type spatial;
uniform float rough = 0.42;
uniform float metal = 0.35;
uniform float coat = 0.0;
uniform vec3 tint = vec3(1.0);
#include "res://shaders/refl_clip.gdshaderinc"
void fragment() {
	REFL_CLIP
	ALBEDO = COLOR.rgb * tint;
	ROUGHNESS = rough;
	METALLIC = metal;
	CLEARCOAT = coat;
	CLEARCOAT_ROUGHNESS = 0.06;
}
