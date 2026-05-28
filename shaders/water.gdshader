// Planetary ocean — translucent sphere at sea level.
// Wave-noise pattern in OBJECT space (so it stays anchored to the water sphere
// instead of sweeping past as the planet orbits the sun), animated via TIME.
// Lighting is computed in world space; the object-space normal is just
// transformed at the end.

shader_type spatial;
// cull_disabled so the surface is visible from below water too.
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec3  planet_center        = vec3(0.0);
uniform float planet_radius        : hint_range(100.0, 100000.0) = 4000.0;
uniform float sea_level_offset     : hint_range(-200.0, 200.0)   = -12.0;

uniform vec3  shallow_color        : source_color = vec3(0.20, 0.55, 0.60);
uniform vec3  deep_color           : source_color = vec3(0.02, 0.08, 0.18);
uniform vec3  foam_color           : source_color = vec3(0.92, 0.95, 0.98);
uniform vec3  sun_direction        = vec3(0.6, 0.5, 0.4);
uniform vec3  sun_color            : source_color = vec3(1.0, 0.96, 0.86);

uniform float wave_scale_a         : hint_range(0.0005, 0.1)  = 0.012;
uniform float wave_scale_b         : hint_range(0.0005, 0.1)  = 0.034;
uniform float wave_strength        : hint_range(0.0, 1.0)     = 0.03;
uniform float wave_speed           : hint_range(0.0, 0.5)     = 0.06;
uniform float fresnel_power        : hint_range(1.0, 8.0)     = 3.5;
uniform float water_roughness      : hint_range(0.0, 1.0)     = 0.12;
uniform float specular_strength    : hint_range(0.0, 4.0)     = 1.2;
uniform float specular_sharpness   : hint_range(4.0, 128.0)   = 28.0;
uniform float foam_threshold       : hint_range(0.0, 30.0)    = 1.6;
uniform float foam_softness        : hint_range(0.1, 10.0)    = 1.8;

varying vec3 v_obj_pos;


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

float wave_field(vec3 p, float t) {
	float a = vnoise(p * wave_scale_a + vec3(t, t * 0.7, -t * 0.3));
	float b = vnoise(p * wave_scale_b - vec3(t * 1.1, -t * 0.5, t * 0.9));
	return mix(a, b, 0.5);
}


void vertex() {
	// Object-space position — invariant under the planet's orbit + spin.
	v_obj_pos = VERTEX;
	// NOTE: a clip-space depth bias used to live here to win shoreline z-fights,
	// but Godot 4 uses reverse-Z and at planetary distance that tiny NDC nudge
	// maps to a huge world-space depth shift the WRONG way — it shoved the whole
	// ocean sphere behind the terrain so it never drew. Removed; the surface now
	// renders at its true depth.
}


void fragment() {
	vec3 op = v_obj_pos;
	vec3 up_obj = normalize(op);
	float t = TIME * wave_speed;

	float w0 = wave_field(op, t);
	// Small finite-difference offsets — also in object space, scaled to the
	// sphere's local units.
	float h = 2.5;
	float dx = wave_field(op + vec3(h, 0.0, 0.0), t) - w0;
	float dz = wave_field(op + vec3(0.0, 0.0, h), t) - w0;

	// Build a tangent basis on the sphere in object space, then perturb the
	// outward normal by the gradient (smaller `wave_strength` → calmer water).
	vec3 seed = vec3(0.0, 0.0, 1.0);
	if (abs(up_obj.z) > 0.95) {
		seed = vec3(1.0, 0.0, 0.0);
	}
	vec3 t_x = normalize(cross(up_obj, seed));
	vec3 t_z = normalize(cross(up_obj, t_x));
	vec3 nrm_obj = normalize(up_obj + (t_x * dx + t_z * dz) * wave_strength);

	// World-space versions for lighting / Fresnel.
	vec3 nrm_world = normalize((MODEL_MATRIX * vec4(nrm_obj, 0.0)).xyz);
	vec3 wp        = (MODEL_MATRIX * vec4(op, 1.0)).xyz;
	vec3 view      = normalize(CAMERA_POSITION_WORLD - wp);
	float n_dot_v  = clamp(dot(nrm_world, view), 0.0, 1.0);
	float fresnel  = pow(1.0 - n_dot_v, fresnel_power);

	// Foam where wave noise spikes high.
	float foam_t = smoothstep(0.55 + foam_threshold * 0.05,
	                           0.85 + foam_threshold * 0.05, w0);
	foam_t = clamp(foam_t / foam_softness, 0.0, 1.0);

	// Base color: deep ↔ shallow by wave noise, then foam.
	vec3 base = mix(deep_color, shallow_color, w0);
	base = mix(base, foam_color, foam_t);

	// Sun specular — softened (lower sharpness, lower strength) so wave-noise
	// jitter doesn't sparkle / flicker per frame.
	// `sun_direction` is the direction FROM the sun (light propagation), so
	// the vector pointing AT the sun from any surface point is `-sun_dir`.
	vec3 to_sun = -normalize(sun_direction);
	vec3 half_v = normalize(view + to_sun);
	float spec  = pow(max(dot(nrm_world, half_v), 0.0), specular_sharpness) * specular_strength;
	vec3 radial_world = normalize(wp - planet_center);
	float day_factor  = smoothstep(-0.05, 0.3, dot(radial_world, to_sun));
	spec *= day_factor;

	ALBEDO    = mix(base, vec3(0.6), fresnel * 0.4);
	EMISSION  = sun_color * spec * 0.5;
	ROUGHNESS = mix(water_roughness, water_roughness + 0.4, foam_t);
	SPECULAR  = 0.5;
	METALLIC  = 0.0;
	// NORMAL is expected in view space — transform world → view.
	NORMAL    = (VIEW_MATRIX * vec4(nrm_world, 0.0)).xyz;
	ALPHA     = mix(0.95, 1.0, foam_t);
}
