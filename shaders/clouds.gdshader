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
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform vec3  planet_center        = vec3(0.0);
uniform float planet_radius        = 4000.0;
uniform float cloud_inner          = 4180.0;   // shell bottom radius
uniform float cloud_outer          = 4420.0;   // shell top radius (== render sphere radius)
uniform vec3  sun_direction        = vec3(0.6, 0.5, 0.4);   // direction light travels
uniform vec3  sun_color   : source_color = vec3(1.0, 0.96, 0.86);
uniform vec3  cloud_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3  cloud_shadow_color : source_color = vec3(0.42, 0.47, 0.60);

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
const int MAX_MARCH_STEPS = 16;

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
	float mid = (cloud_inner + cloud_outer) * 0.5;
	float half_span = max((cloud_outer - cloud_inner) * 0.5, 1.0);
	// Soft vertical falloff so the deck thins toward the top and bottom.
	float vfall = clamp(1.0 - abs(r - mid) / half_span, 0.0, 1.0);
	vfall = smoothstep(0.0, 0.6, vfall);
	vec3 sp = rel * cloud_scale + vec3(TIME * drift_speed, 0.0, TIME * drift_speed * 0.7);
	float base = fbm(sp);
	// Layer in a higher-frequency detail noise that EATS INTO the base shape
	// (subtracted, not added) — the "billow" technique: it carves ragged
	// holes/tendrils out of solid masses so silhouettes break up instead of
	// reading as smooth blobs. The detail is INTENTIONALLY NOT time-animated
	// (drifting it caused clouds to flicker in/out at the coverage edge);
	// only the low-freq base drifts, the detail texture is locked to space.
	float detail = fbm(rel * detail_scale);
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
	vec2 inner = ray_sphere(ro, rd, planet_center, cloud_inner);
	float t_enter = max(outer.x, 0.0);
	float t_exit  = outer.y;
	// If the ray dips into the inner (below-cloud) sphere, stop the march
	// there — we only render the near crossing of the deck.
	if (inner.x > t_enter && inner.x < t_exit) {
		t_exit = inner.x;
	}
	if (t_exit <= t_enter) {
		discard;
	}

	vec3 to_sun = -normalize(sun_direction);
	// Proximity LOD: many samples when the deck is close (flying through it),
	// few when it's a thin distant band from orbit (where it covers the whole
	// screen and each step is a full-screen cost). `t_enter` is the view-space
	// distance to where the ray first hits the deck.
	int steps = int(clamp(8000.0 / max(t_enter, 1.0), 5.0, float(MAX_MARCH_STEPS)));
	float seg = t_exit - t_enter;
	float dt = seg / float(steps);
	float light_step = (cloud_outer - cloud_inner) / 4.0;

	float transmittance = 1.0;
	vec3 scattered = vec3(0.0);
	for (int i = 0; i < MAX_MARCH_STEPS; i++) {
		if (i >= steps) { break; }
		float t = t_enter + (float(i) + 0.5) * dt;
		vec3 pos = ro + rd * t;
		float dens = cloud_density(pos);
		if (dens > 0.001) {
			// Cheap self-shadow: accumulate density toward the sun.
			float ls = 0.0;
			for (int j = 1; j <= 1; j++) {
				ls += cloud_density(pos + to_sun * light_step * float(j));
			}
			float light = exp(-ls * 0.5);
			float a = 1.0 - exp(-dens * dt);
			// Vertical depth shading: darker, cooler base → brighter, warmer top,
			// so the deck reads as volumetric instead of a flat one-colour sheet.
			float hf = clamp((length(pos - planet_center) - cloud_inner)
					/ max(cloud_outer - cloud_inner, 1.0), 0.0, 1.0);
			vec3 col = mix(cloud_shadow_color, cloud_color, light) * mix(0.6, 1.2, hf);
			scattered += transmittance * a * col;
			transmittance *= (1.0 - a);
			if (transmittance < 0.02) {
				break;
			}
		}
	}

	float alpha = 1.0 - transmittance;
	if (alpha < 0.01) {
		discard;
	}
	// Day/night dimming based on the shell mid-point's sun facing.
	vec3 mid_pos = ro + rd * ((t_enter + t_exit) * 0.5);
	vec3 radial = normalize(mid_pos - planet_center);
	float day = smoothstep(-0.25, 0.25, dot(radial, to_sun));
	vec3 lit = scattered * sun_color * mix(0.12, 1.0, day);

	ALBEDO = lit / max(alpha, 0.001);
	ALPHA = alpha;
}
