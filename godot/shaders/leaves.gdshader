shader_type spatial;
render_mode cull_disabled;
uniform sampler2D tex : source_color, filter_linear_mipmap;
#include "res://shaders/refl_clip.gdshaderinc"
void fragment() {
	REFL_CLIP
	vec4 t = texture(tex, UV);
	ALBEDO = t.rgb;
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.45;
	ROUGHNESS = 0.75;
}
