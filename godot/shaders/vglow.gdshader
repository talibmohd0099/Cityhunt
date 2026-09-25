// Self-lit vertex colour (lamp heads, windows, signs, tail lights).
shader_type spatial;
render_mode unshaded;
uniform float boost = 1.0;
uniform bool no_fog = false;
#include "res://shaders/refl_clip.gdshaderinc"
void fragment() {
	REFL_CLIP
	ALBEDO = COLOR.rgb * boost;
	if (no_fog) FOG = vec4(0.0);
}
