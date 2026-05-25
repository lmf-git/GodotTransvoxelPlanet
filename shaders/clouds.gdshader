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

uniform float coverage     : hint_range(0.0, 1.0)    = 0.48;  // higher = fewer/smaller clouds
uniform float density_mul  : hint_range(0.0, 8.0)    = 3.2;
uniform float cloud_scale  : hint_range(0.0001, 0.02)= 0.0016;
uniform float drift_speed  : hint_range(0.0, 0.05)   = 0.004;

// Constant (not a uniform) so the march compiles to a fixed-count loop —
// dynamic loop bounds can trip Metal's SPIR-V→MSL converter. Bump it for
// smoother clouds at the cost of fragment work.
const int march_steps = 18;

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
	for (int i = 0; i < 4; i++) {
		t += vnoise(p) * a;
		p *= 2.03;
		a *= 0.5;
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
	float n = fbm(sp);
	float d = smoothstep(coverage, coverage + 0.35, n) * vfall;
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
	float seg = t_exit - t_enter;
	float dt = seg / float(march_steps);
	float light_step = (cloud_outer - cloud_inner) / 4.0;

	float transmittance = 1.0;
	vec3 scattered = vec3(0.0);
	for (int i = 0; i < march_steps; i++) {
		float t = t_enter + (float(i) + 0.5) * dt;
		vec3 pos = ro + rd * t;
		float dens = cloud_density(pos);
		if (dens > 0.001) {
			// Cheap self-shadow: accumulate density toward the sun.
			float ls = 0.0;
			for (int j = 1; j <= 2; j++) {
				ls += cloud_density(pos + to_sun * light_step * float(j));
			}
			float light = exp(-ls * 0.5);
			float a = 1.0 - exp(-dens * dt);
			vec3 col = mix(cloud_shadow_color, cloud_color, light);
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
