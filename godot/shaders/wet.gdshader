// Streets, sidewalks and tiles: rain-darkened, glossy where puddles collect, with animated ripples
// and (when enabled) the mirrored city from the reflection camera.
shader_type spatial;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_rough = true;
uniform float base_rough = 1.0;
uniform bool use_vcolor = false;
uniform sampler2D ripple_tex : filter_linear_mipmap, repeat_enable;
uniform float wet = 1.0;
global uniform float rain_amount;
global uniform sampler2D refl_tex : filter_linear;
global uniform mat4 refl_vp;
global uniform float refl_on;
varying vec3 wpos;
varying vec3 wnrm;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	if ((CAMERA_VISIBLE_LAYERS & uint(1 << 19)) != uint(0)) { discard; }
	vec3 a = texture(albedo_tex, UV).rgb;
	if (use_vcolor) a *= COLOR.rgb;
	float r = has_rough ? texture(rough_tex, UV).r * base_rough : base_rough;
	float up = smoothstep(0.8, 0.95, wnrm.y);
	float w = wet * (0.18 + 0.82 * smoothstep(0.7, 0.2, r)) * up;
	ALBEDO = a;
	ROUGHNESS = r;
	METALLIC = 0.0;
	vec2 rn = (texture(ripple_tex, wpos.xz * 0.16 + vec2(TIME * 0.02, TIME * 0.013)).xy
		+ texture(ripple_tex, wpos.xz * 0.29 - vec2(TIME * 0.017, -TIME * 0.028)).xy - 1.0) * rain_amount * up;
	vec3 nw = normalize(vec3(rn.x * 0.35, 1.0, rn.y * 0.35));
	if (up > 0.0) NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(nw, 0.0)).xyz, up));
	if (refl_on > 0.5) {
		vec4 c = refl_vp * vec4(wpos, 1.0);
		vec2 ruv = c.xy / c.w * 0.5 + 0.5;
		ruv.y = 1.0 - ruv.y;
		ruv += rn * (0.006 + 0.02 * (1.0 - w));
		vec3 rc = texture(refl_tex, ruv).rgb;
		float fres = 0.25 + 0.75 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
		EMISSION = rc * w * fres * 1.1;
	}
}
