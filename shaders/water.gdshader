// Planetary ocean — translucent sphere at sea level.
//
// Improvements vs. the previous version:
//   * Multi-octave fbm wave field — long swells + chop + ripples, not a single
//     scrolling noise that read as a uniform texture.
//   * Stable tangent basis from a fixed reference (no view-dependent seed
//     swap → no seam at the poles).
//   * Wave HEIGHT no longer modulates the colour. Old shader mixed deep ↔
//     shallow by wave height, which made the surface look spotted; deep water
//     is now uniformly deep, and Fresnel toward a sky-tinted reflection
//     lightens it at grazing angles instead of a flat grey mix.
//   * Whitecap foam triggered by wave STEEPNESS (gradient magnitude), the way
//     real wind-driven foam forms on wave crests — not by raw height.
//   * Sun specular via Godot's standard SPECULAR/ROUGHNESS lighting plus an
//     additional sharp glint emission gated by day-factor, so the highlight
//     only fires on the lit hemisphere.

shader_type spatial;
// cull_disabled so the surface is visible from below water too.
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec3  planet_center        = vec3(0.0);
uniform float planet_radius        : hint_range(100.0, 100000.0) = 4000.0;
uniform float sea_level_offset     : hint_range(-500.0, 500.0)   = -200.0;

uniform vec3  shallow_color        : source_color = vec3(0.16, 0.56, 0.62);   // turquoise — coastal water
uniform vec3  deep_color           : source_color = vec3(0.02, 0.08, 0.16);   // open ocean
uniform vec3  sky_color            : source_color = vec3(0.45, 0.66, 0.94);   // colour reflected at grazing fresnel angles
uniform vec3  foam_color           : source_color = vec3(0.94, 0.96, 0.98);
uniform vec3  sun_direction        = vec3(0.6, 0.5, 0.4);
uniform vec3  sun_color            : source_color = vec3(1.0, 0.96, 0.86);
uniform vec3  polar_axis           = vec3(0.0, 1.0, 0.0);   // stable tangent reference

uniform float wave_scale_swell     : hint_range(0.0001, 0.02) = 0.0018;
uniform float wave_scale_chop      : hint_range(0.001, 0.05)  = 0.011;
uniform float wave_scale_ripple    : hint_range(0.005, 0.5)   = 0.06;
uniform float wave_strength        : hint_range(0.0, 1.5)     = 0.42;
uniform float wave_speed           : hint_range(0.0, 0.5)     = 0.06;

uniform float fresnel_power        : hint_range(1.0, 8.0)     = 4.0;
uniform float water_roughness      : hint_range(0.0, 0.5)     = 0.06;
uniform float sun_glint_strength   : hint_range(0.0, 6.0)     = 1.8;
uniform float sun_glint_sharpness  : hint_range(8.0, 256.0)   = 64.0;
uniform float foam_strength        : hint_range(0.0, 4.0)     = 1.2;

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

// Three-octave wave field. Each octave drifts at a different speed and
// direction so the surface reads as moving water, not a scrolling texture.
// Swell is the dominant long-period rise/fall; chop adds wind-driven mid-
// frequency; ripple is the high-freq surface roughness that gives sun glints
// their characteristic glitter.
float wave_field(vec3 p, float t) {
	float swell  = vnoise(p * wave_scale_swell  + vec3(t * 0.30, 0.0, t * 0.18));
	float chop   = vnoise(p * wave_scale_chop   + vec3(-t * 0.65, t * 0.40, t * 0.55));
	float ripple = vnoise(p * wave_scale_ripple + vec3(t * 1.20, t * 0.90, -t * 1.05));
	return swell * 0.62 + chop * 0.28 + ripple * 0.10;
}


void vertex() {
	v_obj_pos = VERTEX;
}


void fragment() {
	vec3 op = v_obj_pos;
	vec3 up_obj = normalize(op);
	float t = TIME * wave_speed;

	// Build a STABLE tangent basis using polar_axis as the reference rather
	// than a view-dependent seed. Old code switched the seed at z>0.95,
	// creating a visible seam across the pole. The fallback handles the
	// degenerate case where up_obj is parallel to polar_axis.
	vec3 ref = polar_axis;
	if (abs(dot(up_obj, ref)) > 0.97) {
		ref = vec3(1.0, 0.0, 0.0);
	}
	vec3 t_x = normalize(cross(up_obj, ref));
	vec3 t_z = normalize(cross(up_obj, t_x));

	float w0 = wave_field(op, t);
	// Finite-difference along the tangent vectors (sphere surface), not along
	// world axes — gives correct gradients regardless of where on the sphere
	// the fragment is.
	float h = 2.5;
	float dx = wave_field(op + t_x * h, t) - w0;
	float dz = wave_field(op + t_z * h, t) - w0;

	// Perturb the outward normal by the wave gradient.
	vec3 nrm_obj = normalize(up_obj + (t_x * dx + t_z * dz) * wave_strength);

	// World-space versions for lighting.
	vec3 nrm_world = normalize((MODEL_MATRIX * vec4(nrm_obj, 0.0)).xyz);
	vec3 wp        = (MODEL_MATRIX * vec4(op, 1.0)).xyz;
	vec3 view      = normalize(CAMERA_POSITION_WORLD - wp);
	float n_dot_v  = clamp(dot(nrm_world, view), 0.0, 1.0);
	// Schlick-style Fresnel — surface gets MORE reflective at grazing angles.
	float fresnel  = pow(1.0 - n_dot_v, fresnel_power);

	// Wave STEEPNESS (gradient magnitude) — whitecaps form where the surface
	// is sharply tilted, which is what makes wind-driven foam.
	float steep = length(vec2(dx, dz)) * 60.0;
	float foam_t = clamp(smoothstep(0.42, 0.95, steep) * foam_strength, 0.0, 1.0);

	// Base water colour: deep blue everywhere — does NOT depend on the wave
	// height noise, which is what made the old surface look spotted. View-
	// dependent transparency makes it read as shallow where the camera looks
	// nearly straight down (light penetrates further), deep at grazing angles.
	vec3 base = mix(shallow_color, deep_color, smoothstep(0.55, 0.92, 1.0 - n_dot_v));

	// Fresnel reflection towards SKY colour (not grey). At grazing angles you
	// see the sky reflected, not a fog patch.
	vec3 reflected = sky_color;
	vec3 col = mix(base, reflected, fresnel);

	// Foam paints over both.
	col = mix(col, foam_color, foam_t);

	// Sharp sun specular glint — separate from Godot's standard specular so
	// it can be made sharper than the BRDF allows, and gated by day-factor
	// so it doesn't fire on the night side.
	vec3 to_sun = -normalize(sun_direction);
	vec3 half_v = normalize(view + to_sun);
	float glint = pow(max(dot(nrm_world, half_v), 0.0), sun_glint_sharpness);
	vec3 radial_world = normalize(wp - planet_center);
	float day_factor  = smoothstep(-0.05, 0.25, dot(radial_world, to_sun));
	vec3 sun_glint    = sun_color * glint * sun_glint_strength * day_factor;

	ALBEDO    = col;
	EMISSION  = sun_glint;
	ROUGHNESS = mix(water_roughness, water_roughness + 0.45, foam_t);
	SPECULAR  = 0.55;
	METALLIC  = 0.0;
	NORMAL    = (VIEW_MATRIX * vec4(nrm_world, 0.0)).xyz;
	ALPHA     = mix(0.95, 1.0, foam_t);
}
