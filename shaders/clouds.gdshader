// Volumetric cloud shell — a raymarched layer between `cloud_inner` and
// `cloud_outer` radii around the planet. Rendered on a sphere mesh at the
// outer radius with cull_disabled so the fragment runs whether the camera is
// outside the shell (orbit), inside it (flying through), or below it (ground
// looking up). For each covered pixel we reconstruct the world view ray,
// analytically clip it to the shell, and march the segment accumulating a
// 3D-noise cloud density with cheap sun self-shadowing.
//
// Anchored to the planet center (passed in world space each frame); clouds
// drift slowly via TIME. Lighting uses the same `sun_direction` convention as
// the water/atmosphere shaders (direction the light TRAVELS, so the vector
// toward the sun is `-sun_direction`).

shader_type spatial;
// depth_test_disabled: we no longer let the render sphere's hardware depth test
// occlude the deck — that's what hard-clipped clouds around mountains that poke
// above cloud_outer (the sphere surface intersected terrain). Instead we sample
// the scene depth and clip the RAYMARCH at the real surface, so the deck renders
// volumetrically in front of terrain with no sphere-intersection seam.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled;

// Already-rendered scene depth, to clip the march at the actual terrain/water
// surface (same technique as atmosphere.gdshader).
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;

uniform vec3  planet_center        = vec3(0.0);
uniform float planet_radius        = 4000.0;
// World→planet-local rotation. Needed because we sample the cloud noise at
// `rel = wp - planet_center` in world space; but the planet spins under us
// every frame, so `rel` for a fragment on the cloud sphere rotates around
// the planet axis at the spin rate — which makes the noise pattern drift
// across the cloud surface at SPIN speed, reading as "clouds moving fast
// around the planet". Rotating `rel` by the inverse of the planet's basis
// puts it in the planet's LOCAL frame, where the noise pattern is locked
// to the planet so clouds stay put as it spins (which is what real clouds
// look like — they move on timescales of hours, not minutes).
uniform mat3  planet_basis_inv     = mat3(1.0);
uniform float cloud_inner          = 4180.0;   // shell bottom radius
uniform float cloud_outer          = 4420.0;   // shell top radius (== render sphere radius)
uniform vec3  sun_direction        = vec3(0.6, 0.5, 0.4);   // direction light travels
uniform vec3  sun_color   : source_color = vec3(1.0, 0.96, 0.86);
uniform vec3  cloud_color : source_color = vec3(0.92, 0.93, 0.97);   // slightly cool white — pure (1,1,1) reads as paper-flat
uniform vec3  cloud_shadow_color : source_color = vec3(0.10, 0.12, 0.18);  // much darker — was (0.42, 0.47, 0.60), too bright to read as shadow

uniform float coverage     : hint_range(0.0, 1.0)    = 0.52;  // higher = fewer/smaller clouds; 0.62 was too sparse for the planet's size
uniform float density_mul  : hint_range(0.0, 8.0)    = 1.6;   // lower → more translucent, less "thick fog"
uniform float cloud_scale  : hint_range(0.0001, 0.02)= 0.00045; // big planet → big formations: was 0.0016 (≈625 m features) which tiled ~40× and read as a uniform sheet
uniform float detail_scale : hint_range(0.001, 0.1)  = 0.008;   // high-freq noise that breaks up the silhouette so clouds don't read as one flat mass
uniform float detail_strength : hint_range(0.0, 0.6) = 0.16;   // halved: 0.32 was strong enough to push base above coverage BELOW threshold, which made clouds blink in/out as the detail noise drifted
uniform float drift_speed  : hint_range(0.0, 0.05)   = 0.004;

// Upper bound on raymarch samples. Kept constant so the loop compiles to a
// fixed count — dynamic loop *bounds* can trip Metal's SPIR-V→MSL converter, so
// instead we keep this bound fixed and `break` early (a dynamic break is fine).
// Proximity LOD picks the actual sample count per-pixel from the view distance.
const int MAX_MARCH_STEPS = 20;

varying vec3 v_world;


float hash3(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash3(i + vec3(0,0,0));
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

float fbm(vec3 p) {
	float t = 0.0;
	float a = 0.5;
	// 5 octaves (was 3) so big cloud bodies get visible internal structure
	// — wisps, bumps, edge ragged-ness — instead of looking like sprayed paint.
	for (int i = 0; i < 5; i++) {
		t += vnoise(p) * a;
		p = p * 2.07 + vec3(13.0, 7.0, 19.0);   // domain offset per octave avoids axis-aligned banding
		a *= 0.52;
	}
	return t;
}

// Cloud density at a world-space point inside the shell.
float cloud_density(vec3 wp) {
	vec3 rel = wp - planet_center;
	float r = length(rel);
	// Rotate into the planet's LOCAL frame for noise sampling so the cloud
	// pattern doesn't morph at the planet's spin rate. Length is rotation-
	// invariant, so `r` and the vertical-falloff math stay the same.
	vec3 rel_local = planet_basis_inv * rel;
	float mid = (cloud_inner + cloud_outer) * 0.5;
	float half_span = max((cloud_outer - cloud_inner) * 0.5, 1.0);
	// Soft vertical falloff so the deck thins toward the top and bottom. The ramp
	// is shortened (0.6 → 0.25) so density reaches full over the middle ~75% of
	// the deck and only fades in the outer slivers — otherwise the clouds melted
	// away just above/below you whenever you were inside the deck.
	float vfall = clamp(1.0 - abs(r - mid) / half_span, 0.0, 1.0);
	vfall = smoothstep(0.0, 0.25, vfall);
	// Drift in local frame — clouds move slowly relative to the ground
	// (real-cloud timescale) instead of being yanked around by spin.
	vec3 sp = rel_local * cloud_scale + vec3(TIME * drift_speed, 0.0, TIME * drift_speed * 0.7);
	float base = fbm(sp);
	// Layer in a higher-frequency detail noise that EATS INTO the base shape
	// (subtracted, not added) — the "billow" technique: it carves ragged
	// holes/tendrils out of solid masses so silhouettes break up instead of
	// reading as smooth blobs. The detail is INTENTIONALLY NOT time-animated
	// (drifting it caused clouds to flicker in/out at the coverage edge);
	// only the low-freq base drifts, the detail texture is locked to space.
	float detail = fbm(rel_local * detail_scale);
	float n = base - detail_strength * (1.0 - detail);
	// Wider coverage band → more partial-density edges instead of binary
	// "cloud / no cloud", which is what reads as the flat-colour look.
	float d = smoothstep(coverage, coverage + 0.55, n) * vfall;
	return d * density_mul;
}

// Ray-sphere intersection. Returns vec2(t_near, t_far); t_far < t_near on miss.
vec2 ray_sphere(vec3 ro, vec3 rd, vec3 ce, float ra) {
	vec3 oc = ro - ce;
	float b = dot(oc, rd);
	float c = dot(oc, oc) - ra * ra;
	float h = b * b - c;
	if (h < 0.0) {
		return vec2(1.0, -1.0);
	}
	h = sqrt(h);
	return vec2(-b - h, -b + h);
}


void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	vec3 ro = CAMERA_POSITION_WORLD;
	vec3 rd = normalize(v_world - ro);

	vec2 outer = ray_sphere(ro, rd, planet_center, cloud_outer);
	if (outer.y < 0.0) {
		discard;
	}
	float t_enter = max(outer.x, 0.0);
	float t_exit  = outer.y;
	// NOTE: we deliberately do NOT clip the far exit at the inner (below-cloud)
	// sphere. A horizon ray from above the deck crosses the deck TWICE — a near
	// slab and a far slab — and that far slab IS the distant clouds along the
	// horizon. Clipping at the inner near-crossing dropped them (they only
	// appeared once you dropped below the deck). Marching the whole cloud_outer
	// chord keeps both slabs; the depth clip below already stops the march at the
	// real surface, so we never march through the planet.
	// Clip the march at the real scene surface (terrain/water) reconstructed from
	// the depth buffer. Godot uses reverse-Z (depth 0 = infinity / no occluder).
	// This is what makes clouds render correctly in front of / around peaks that
	// poke above the deck instead of being clipped by the render sphere.
	float scene_depth_ndc = texture(depth_tex, SCREEN_UV).r;
	if (scene_depth_ndc > 0.0) {
		vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, scene_depth_ndc, 1.0);
		ndc.y = -ndc.y;   // SCREEN_UV is top-left origin
		vec4 vpos = INV_PROJECTION_MATRIX * ndc;
		vpos.xyz /= vpos.w;
		vec4 wp_v = INV_VIEW_MATRIX * vec4(vpos.xyz, 1.0);
		t_exit = min(t_exit, length(wp_v.xyz - ro));
	}
	if (t_exit <= t_enter) {
		discard;
	}

	vec3 to_sun = -normalize(sun_direction);
	float seg = t_exit - t_enter;
	// Fixed WORLD-space march step — NOT a distance-based step COUNT. The old
	// proximity LOD changed the number of samples with camera distance, so `dt`
	// changed and the cloud sampling (hence the whole cloud shape) visibly morphed
	// as you moved toward/away from the planet. A constant step keeps the samples
	// stable; the count just follows the segment length, capped for cost. Very
	// long grazing chords stretch dt so they're still covered in MAX steps.
	// Finer fixed step (deck/14 ≈ 2× the samples) so flying through reads as smooth
	// parallax instead of blocky chunks sliding across the noise. Per-pixel jitter
	// dithers the sample positions so the ±1 change in step COUNT (as the segment
	// length changes while you move) breaks into fine noise rather than a coherent
	// whole-screen pop — the "clouds regenerate as I move" artifact.
	float dt = max((cloud_outer - cloud_inner) / 14.0, seg / float(MAX_MARCH_STEPS));
	int steps = int(clamp(ceil(seg / dt), 1.0, float(MAX_MARCH_STEPS)));
	float jitter = (hash3(vec3(FRAGCOORD.xy, 11.7)) - 0.5) * 0.55;   // gentler dither → less grain
	float light_step = (cloud_outer - cloud_inner) / 4.0;

	// Henyey-Greenstein-ish forward-scatter lobe: clouds brighten when the
	// view ray points roughly along the sun direction (e.g. looking up at a
	// cloud lit from behind by the sun). Single G value, no normalisation —
	// just a multiplier into the scattered colour.
	float cos_view_sun = dot(rd, to_sun);
	float g = 0.55;
	float forward_lobe = (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * cos_view_sun, 1.5);
	forward_lobe = clamp(forward_lobe, 0.5, 3.0);

	float transmittance = 1.0;
	vec3 scattered = vec3(0.0);
	for (int i = 0; i < MAX_MARCH_STEPS; i++) {
		if (i >= steps) { break; }
		float t = t_enter + (float(i) + 0.5 + jitter) * dt;
		vec3 pos = ro + rd * t;
		float dens = cloud_density(pos);
		if (dens > 0.001) {
			// Multi-sample self-shadow: walk 4 steps toward the sun and
			// accumulate density. Single-sample was the reason clouds came out
			// uniformly bright — the body of a cloud blocks 4× more sun than
			// its edge, but a single sample can't tell them apart.
			float ls = 0.0;
			ls += cloud_density(pos + to_sun * light_step * 1.0);
			ls += cloud_density(pos + to_sun * light_step * 2.5) * 0.7;
			ls += cloud_density(pos + to_sun * light_step * 5.0) * 0.4;
			// Strong attenuation: exp(-ls * 2.5) lets thick cloud bodies
			// drive `light` to near-zero so they read as solid grey-blue
			// shadow against the lit edges and rim.
			float light = exp(-ls * 2.5);
			float a = 1.0 - exp(-dens * dt);
			// Vertical depth shading: tops bright, bases dark, so flat sheets
			// pick up volume cues even without strong sun direction.
			float hf = clamp((length(pos - planet_center) - cloud_inner)
					/ max(cloud_outer - cloud_inner, 1.0), 0.0, 1.0);
			float vfactor = mix(0.55, 1.35, hf);   // brighter tops (seen from above)
			vec3 col = mix(cloud_shadow_color, cloud_color, light) * vfactor;
			scattered += transmittance * a * col;
			transmittance *= (1.0 - a);
			if (transmittance < 0.02) {
				break;
			}
		}
	}
	// Day/night dimming based on the shell mid-point's sun facing. Computed
	// here (before the forward-scatter apply) so the lobe doesn't brighten
	// clouds that aren't actually facing the sun.
	vec3 mid_pos = ro + rd * ((t_enter + t_exit) * 0.5);
	vec3 radial = normalize(mid_pos - planet_center);
	float day = smoothstep(-0.25, 0.25, dot(radial, to_sun));
	// Forward-scatter only counts on the LIT hemisphere — multiplying by
	// `day` means a back-lit cloud on the night side doesn't get the bright
	// sun-haloed edge it can't physically have.
	scattered *= mix(1.0, forward_lobe, 0.35 * day);

	float alpha = 1.0 - transmittance;
	if (alpha < 0.01) {
		discard;
	}
	// Dimmed: was * sun_color (≈1.0) * 1.0 in daylight which let the brightest
	// edge pixels exceed the HDR glow threshold (1.5) and bloom into white blobs.
	// 0.85 keeps the lit edges crisp but stays under threshold; night side is
	// pushed nearly to black (was floored at 0.08 of full brightness which read
	// as "clouds still lit at midnight"). The 0.015 floor is a tiny ambient so
	// they don't go pitch black against the deep-space backdrop — closer to
	// what real clouds look like under moon/starlight.
	// Brightened 0.85 → 1.15 so daylit cloud tops (what you see from above) read
	// bright instead of grey. The brightest edges may now just tip the bloom
	// threshold, which on clouds reads as a soft sunlit rim rather than a blob.
	vec3 lit = scattered * sun_color * max(day * 1.15, 0.02);

	ALBEDO = lit / max(alpha, 0.001);
	ALPHA = alpha;
}
