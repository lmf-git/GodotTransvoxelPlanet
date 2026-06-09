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

uniform float wave_scale_swell     : hint_range(0.0001, 0.02) = 0.0022;
uniform float wave_scale_chop      : hint_range(0.001, 0.05)  = 0.014;
uniform float wave_scale_ripple    : hint_range(0.005, 0.5)   = 0.075;
uniform float wave_scale_close     : hint_range(0.05, 2.0)    = 0.45;   // fine ripple octave that LOD-fades in when the camera is near the surface
uniform float wave_strength        : hint_range(0.0, 2.0)     = 0.55;
uniform float wave_speed           : hint_range(0.0, 1.5)     = 0.13;   // calm drift: 0.45 read as water visibly racing across the surface; 0.06 looked frozen — 0.13 is a gentle sea
uniform float lod_near             : hint_range(1.0, 500.0)   = 30.0;   // metres: ramp-in is fully on at this distance
uniform float lod_far              : hint_range(100.0, 8000.0)= 1800.0; // metres: detail ramp-in is off beyond this

uniform float fresnel_power        : hint_range(1.0, 8.0)     = 4.0;
// Raised 0.06 → 0.11: a near-mirror surface turns any sub-pixel normal wobble
// into firefly specular sparkle. A little base roughness widens the BRDF lobe
// and settles it without making the water look matte.
uniform float water_roughness      : hint_range(0.0, 0.5)     = 0.11;
// Softer + broader glint (1.8/64 → 1.2/26): a very tight highlight on noisy
// normals is exactly what flickers as the camera/waves move.
uniform float sun_glint_strength   : hint_range(0.0, 6.0)     = 1.2;
uniform float sun_glint_sharpness  : hint_range(8.0, 256.0)   = 26.0;
uniform float foam_strength        : hint_range(0.0, 4.0)     = 0.7;

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

// Directional wave field. Each octave samples noise at an ANISOTROPICALLY
// stretched position (stretched along its propagation direction), which
// turns blobby value noise into long parallel crests that LOOK like rolling
// swells instead of spotted patches. Drift speeds are also much larger in
// noise space than before so the waves visibly travel each frame.
//
// `close_amp` scales an extra high-frequency octave that's only sampled
// when the camera is near the surface — that's the LOD: from orbit you get
// the cheap 3-octave swell+chop+ripple; standing on a cliff above the sea
// you also get the fine wind-ripple detail that catches the sun glints.
float wave_field(vec3 p, float t, float close_amp) {
	// Swell — long, slow, anisotropic. Stretch the sample position along
	// (1, 0, 0.3) so the noise features elongate into rolling lines roughly
	// transverse to the propagation direction.
	vec3 swell_p = (p + vec3(2.0 * t, 0.0, 0.6 * t)) * wave_scale_swell;
	swell_p.x *= 0.42;   // stretch along propagation → wider crests, parallel lines
	float swell = vnoise(swell_p);

	// Chop — mid-freq, faster, different direction.
	vec3 chop_p = (p + vec3(-3.5 * t, 2.1 * t, 1.4 * t)) * wave_scale_chop;
	chop_p.z *= 0.55;
	float chop = vnoise(chop_p);

	// Ripple — high-freq, fastest. No anisotropy (looks more like wind chatter).
	vec3 rip_p = (p + vec3(5.8 * t, -4.2 * t, 6.1 * t)) * wave_scale_ripple;
	float ripple = vnoise(rip_p);

	// Weighted toward the long swell; the high-freq ripple is dialled back
	// (0.14 → 0.08) so it textures the surface without dominating the normal
	// with fine chatter (the source of the sparkle).
	float sum = swell * 0.64 + chop * 0.28 + ripple * 0.08;

	// LOD detail — only contributes when close (close_amp > 0). Even higher
	// frequency, fastest motion. Amplitude halved (0.22 → 0.10) so nearby water
	// reads as fine wavelets, not sandpaper.
	if (close_amp > 0.001) {
		vec3 close_p = (p + vec3(8.0 * t, -7.0 * t, 9.5 * t)) * wave_scale_close;
		float close_detail = vnoise(close_p);
		sum = mix(sum, sum + close_detail * 0.10, close_amp);
	}
	return sum;
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

	// View-distance LOD: ramp the close-detail octave in between lod_near and
	// lod_far. Computed BEFORE the wave_field samples so all three samples
	// (centre + two finite-difference taps) use the same octave set and the
	// gradient is consistent.
	vec3 wp_centre = (MODEL_MATRIX * vec4(op, 1.0)).xyz;
	float view_dist = length(CAMERA_POSITION_WORLD - wp_centre);
	float close_amp = smoothstep(lod_far, lod_near, view_dist);

	float w0 = wave_field(op, t, close_amp);
	// Finite-difference along the tangent vectors (sphere surface), not along
	// world axes — gives correct gradients regardless of where on the sphere
	// the fragment is. Sample step `h` shrinks when close so the close-detail
	// octave's gradient is captured at the right scale (without this the
	// fine ripple gets blurred out of the normal).
	float h = mix(2.5, 0.6, close_amp);
	float dx = wave_field(op + t_x * h, t, close_amp) - w0;
	float dz = wave_field(op + t_z * h, t, close_amp) - w0;

	// Perturb the outward normal by the wave gradient.
	vec3 nrm_obj = normalize(up_obj + (t_x * dx + t_z * dz) * wave_strength);

	// World-space versions for lighting. wp_centre already done above.
	vec3 nrm_world = normalize((MODEL_MATRIX * vec4(nrm_obj, 0.0)).xyz);
	vec3 wp        = wp_centre;
	vec3 view      = normalize(CAMERA_POSITION_WORLD - wp);
	float n_dot_v  = clamp(dot(nrm_world, view), 0.0, 1.0);
	// Schlick-style Fresnel — surface gets MORE reflective at grazing angles.
	float fresnel  = pow(1.0 - n_dot_v, fresnel_power);

	// Wave STEEPNESS (gradient magnitude) — whitecaps form where the surface
	// is sharply tilted. Lower gain (60 → 32) + a higher, wider threshold so
	// foam only appears on genuinely steep crests instead of speckling the
	// whole surface wherever the noise gradient twitches.
	float steep = length(vec2(dx, dz)) * 32.0;
	float foam_t = clamp(smoothstep(0.60, 1.40, steep) * foam_strength, 0.0, 1.0);

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

	// Distance roughening: past a few hundred metres the wave normal detail is
	// sub-pixel, so a near-mirror surface there aliases into a sparkle field.
	// Fading roughness UP with distance turns that sub-pixel detail into a soft
	// sheen (the physically-correct LOD for specular) while the near surface
	// stays crisp. Foam still overrides to fully rough on crests.
	float dist_rough = smoothstep(lod_near, lod_far, view_dist) * 0.22;
	ALBEDO    = col;
	EMISSION  = sun_glint;
	ROUGHNESS = clamp(mix(water_roughness + dist_rough, water_roughness + 0.45, foam_t), 0.0, 1.0);
	SPECULAR  = 0.55;
	METALLIC  = 0.0;
	NORMAL    = (VIEW_MATRIX * vec4(nrm_world, 0.0)).xyz;
	ALPHA     = mix(0.95, 1.0, foam_t);
}
