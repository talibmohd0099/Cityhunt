// Police light-bar lamps: glowing, flashing in turn like the police halos (colour and phase per lamp).
shader_type spatial;
render_mode unshaded, shadows_disabled;
instance uniform vec4 beacon = vec4(1.0, 0.1, 0.1, 0.0);   // rgb, phase
global uniform float game_time;
#include "res://shaders/refl_clip.gdshaderinc"
void fragment() {
	REFL_CLIP
	float on = mod(floor(game_time * 2.2 + beacon.a * 2.0), 2.0) < 0.5 ? 1.0 : 0.05;
	ALBEDO = beacon.rgb * (0.25 + 2.5 * on);
}
