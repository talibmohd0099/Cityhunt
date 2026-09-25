shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, shadows_disabled;
uniform sampler2D tex : source_color, filter_linear_mipmap;
uniform float level = 1.0;
void fragment() {
	vec4 t = texture(tex, UV);
	ALBEDO = t.rgb * t.a * level;
}
