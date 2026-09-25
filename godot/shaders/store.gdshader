shader_type spatial;
uniform sampler2D store_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D store_emi : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
#include "res://shaders/refl_clip.gdshaderinc"
void fragment() {
	REFL_CLIP
	ALBEDO = texture(store_tex, UV).rgb;
	EMISSION = texture(store_emi, UV).rgb * 1.1;
	ROUGHNESS = 0.55;
	METALLIC = 0.1;
}
