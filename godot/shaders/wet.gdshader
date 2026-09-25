// Streets, sidewalks and tiles: rain-darkened, with water standing in puddles, cracks and joints,
// animated ripples and (when enabled) the mirrored city from the reflection camera.
// Close-up detail (stones, slabs, cracks) comes from world-space detail maps; the baked textures
// add the large-scale variation and the big puddles.
shader_type spatial;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_rough = true;
uniform float base_rough = 1.0;
uniform bool use_vcolor = false;
uniform sampler2D ripple_tex : filter_linear_mipmap, repeat_enable;
uniform float wet = 1.0;
// detail maps: colour, and normal x/y + roughness + height packed in one texture
uniform bool has_detail = false;
uniform sampler2D detail_a : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_n : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float detail_scale = 0.4;        // repeats per metre
uniform float detail_gain = 1.0;         // brightness of the detail colour
uniform float macro_mean = 0.1;          // average of albedo_tex, so it only adds variation
uniform float macro_amount = 1.0;
uniform float bump = 1.0;
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
	float r = has_rough ? texture(rough_tex, UV).r * base_rough : base_rough;
	float up = smoothstep(0.8, 0.95, wnrm.y);
	// big puddles from the baked roughness map
	float pool = smoothstep(0.62, 0.3, r) * up;
	vec3 dn = vec3(0.0, 1.0, 0.0);
	float standing = pool;
	if (has_detail) {
		vec2 duv = (up > 0.5 ? wpos.xz : vec2(wpos.x + wpos.z, -wpos.y)) * detail_scale;
		vec4 t = texture(detail_n, duv);
		vec3 macro = clamp(a / macro_mean, vec3(0.45), vec3(1.8));
		a = texture(detail_a, duv).rgb * detail_gain * mix(vec3(1.0), macro, macro_amount);
		// water fills the low parts of the surface (joints, cracks, between stones) as the rain goes on
		float level = 0.18 + 0.22 * rain_amount * wet;
		float fill = smoothstep(level + 0.05, level - 0.05, t.a) * up * step(0.05, wet);
		standing = max(pool, fill);
		r = mix(t.b, r, 0.25);
		vec2 nxy = (t.rg * 2.0 - 1.0) * bump * (1.0 - standing);
		dn = normalize(vec3(nxy.x, sqrt(max(1.0 - dot(nxy, nxy), 0.0)), -nxy.y));
	}
	if (use_vcolor) a *= COLOR.rgb;
	// rain: everything outdoors is damp (darker, shinier); standing water is darker still and mirror-like
	float damp = wet * up * clamp(rain_amount * 1.6, 0.0, 1.0);
	a *= 1.0 - 0.35 * damp - 0.25 * standing * wet;
	float gloss = smoothstep(0.75, 0.3, r) * damp;
	r = mix(r, r * 0.55, damp);
	r = mix(r, 0.03, standing * wet);
	// the mirrored city: clear in standing water, faint and broken up on merely wet ground
	float w = wet * up * clamp(0.12 + 0.4 * gloss + 0.85 * standing, 0.0, 1.0);
	ALBEDO = a;
	ROUGHNESS = r;
	METALLIC = 0.0;
	vec2 rn = (texture(ripple_tex, wpos.xz * 0.16 + vec2(TIME * 0.02, TIME * 0.013)).xy
		+ texture(ripple_tex, wpos.xz * 0.29 - vec2(TIME * 0.017, -TIME * 0.028)).xy - 1.0) * rain_amount * up;
	rn *= 0.35 + 0.65 * standing;
	vec3 nw = normalize(vec3(rn.x * 0.35 + dn.x, dn.y, rn.y * 0.35 + dn.z));
	if (up > 0.0) NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(nw, 0.0)).xyz, up));
	if (refl_on > 0.5) {
		vec4 c = refl_vp * vec4(wpos, 1.0);
		vec2 ruv = c.xy / c.w * 0.5 + 0.5;
		ruv.y = 1.0 - ruv.y;
		ruv += rn * (0.006 + 0.02 * (1.0 - w)) + dn.xz * 0.035 * (1.0 - standing);
		vec3 rc = texture(refl_tex, ruv).rgb;
		float fres = 0.25 + 0.75 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
		EMISSION = rc * w * fres * 1.1;
	}
}
