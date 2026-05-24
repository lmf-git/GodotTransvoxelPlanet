// Moon terrain shader — object-space triplanar over a grey palette with two
// noise layers (basalt mare + lighter highlands) and a darken-on-slope rock
// contrast. No biomes, no snow line.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform float moon_radius        : hint_range(100.0, 100000.0) = 1100.0;
uniform vec3  color_highland     : source_color = vec3(0.78, 0.76, 0.72);
uniform vec3  color_mare         : source_color = vec3(0.36, 0.34, 0.31);
uniform vec3  color_rock         : source_color = vec3(0.20, 0.20, 0.20);
uniform float mare_threshold     : hint_range(0.0, 1.0) = 0.55;
uniform float mare_fade          : hint_range(0.01, 0.5) = 0.15;
uniform float rock_slope_thresh  : hint_range(0.0, 1.0) = 0.6;
uniform float rock_slope_fade    : hint_range(0.01, 0.5) = 0.2;
uniform float detail_scale       : hint_range(0.001, 0.5) = 0.06;
uniform float detail_amp         : hint_range(0.0, 0.5) = 0.22;
uniform float macro_scale        : hint_range(0.0001, 0.05) = 0.0035;

varying vec3 v_obj_pos;
varying vec3 v_obj_normal;


float hash3(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float n3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash3(i);
	float n100 = hash3(i + vec3(1,0,0));
	float n010 = hash3(i + vec3(0,1,0));
	float n110 = hash3(i + vec3(1,1,0));
	float n001 = hash3(i + vec3(0,0,1));
	float n101 = hash3(i + vec3(1,0,1));
	float n011 = hash3(i + vec3(0,1,1));
	float n111 = hash3(i + vec3(1,1,1));
	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
		f.z);
}

float fbm3(vec3 p, int oct) {
	float t = 0.0;
	float a = 0.5;
	for (int i = 0; i < oct; i++) {
		t += n3(p) * a;
		p *= 2.07;
		a *= 0.5;
	}
	return t;
}

vec3 triplanar(vec3 base, vec3 pos, vec3 nrm, float scale, float amp) {
	vec3 blend = abs(nrm);
	blend = max(blend - 0.2, vec3(0.0));
	blend /= max(dot(blend, vec3(1.0)), 1e-4);
	float a = fbm3(pos.yzx * scale + 1.7, 4);
	float b = fbm3(pos.xzy * scale + 3.1, 4);
	float c = fbm3(pos.xyz * scale + 5.3, 4);
	float n = a * blend.x + b * blend.y + c * blend.z;
	float m = (n - 0.5) * 2.0 * amp;
	return clamp(base + base * m, vec3(0.0), vec3(1.0));
}


void vertex() {
	v_obj_pos    = VERTEX;
	v_obj_normal = NORMAL;
}


void fragment() {
	vec3 wp = v_obj_pos;
	vec3 wn = normalize(v_obj_normal);
	float r = length(wp);
	vec3 radial = (r > 1e-6) ? wp / r : vec3(0.0, 1.0, 0.0);
	float slope = clamp(dot(wn, radial), 0.0, 1.0);

	// Macro mare/highland blend — low-frequency noise picks dark vs light.
	float macro = fbm3(wp * macro_scale, 5);
	float mare_t = smoothstep(mare_threshold, mare_threshold + mare_fade, macro);
	vec3 base = mix(color_highland, color_mare, mare_t);

	// Rocky darkening on steep slopes (crater walls, cliff faces).
	float rock_t = 1.0 - smoothstep(rock_slope_thresh - rock_slope_fade,
	                                 rock_slope_thresh + rock_slope_fade,
	                                 slope);
	base = mix(base, color_rock, rock_t);

	// Triplanar detail.
	base = triplanar(base, wp, wn, detail_scale, detail_amp);

	ALBEDO    = base;
	ROUGHNESS = 0.95;
	SPECULAR  = 0.02;
	METALLIC  = 0.0;
}
