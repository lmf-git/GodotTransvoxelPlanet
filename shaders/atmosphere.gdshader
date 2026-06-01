// Single-shell atmospheric scattering — additive in-scatter blended OVER the
// scene (it does NOT read/overwrite the screen, so it never touches the clouds
// or anything else drawn behind it). View-ray vs the atmosphere shell is solved
// analytically; we integrate a simple density falloff, split into Rayleigh
// (blue) + a Mie sun lobe, warm it toward a low sun for sunsets, and let the
// bright sun disc punch through instead of being veiled.

shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled;

// Scene depth, to clip the integration at the real surface (terrain/water/moon)
// rather than the ideal planet sphere.
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;

uniform vec3  planet_center        = vec3(0.0);
uniform float planet_radius        = 4000.0;
uniform float atmosphere_radius    = 4500.0;
uniform vec3  sun_direction        = vec3(0.6, 0.5, 0.4);  // direction light TRAVELS (from the sun)
uniform vec3  rayleigh_color       : source_color = vec3(0.21, 0.45, 0.95);
uniform vec3  mie_color            : source_color = vec3(1.0, 0.85, 0.65);
uniform float scattering_strength  = 1.4;
uniform float mie_strength         = 0.45;
uniform float mie_g                = 0.78;
uniform float space_alpha          = 0.0;   // tweak to leave faint glow over stars

varying vec3 v_world_pos;


vec2 ray_sphere(vec3 origin, vec3 dir, vec3 center, float radius) {
	vec3 oc = origin - center;
	float b = dot(oc, dir);
	float c = dot(oc, oc) - radius * radius;
	float h = b * b - c;
	if (h < 0.0) return vec2(-1.0);
	h = sqrt(h);
	return vec2(-b - h, -b + h);
}


void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 dir = normalize(v_world_pos - cam);

	vec3 out_col = vec3(0.0);
	float out_a  = space_alpha;

	// World distance to the scene from the depth buffer (reverse-Z: 0 = infinity).
	float scene_depth_ndc = texture(depth_tex, SCREEN_UV).r;
	float scene_t = 1e20;
	if (scene_depth_ndc > 0.0) {
		vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, scene_depth_ndc, 1.0);
		ndc.y = -ndc.y;
		vec4 view = INV_PROJECTION_MATRIX * ndc;
		view.xyz /= view.w;
		vec4 wp_v = INV_VIEW_MATRIX * vec4(view.xyz, 1.0);
		scene_t = length(wp_v.xyz - cam);
	}

	vec2 atm = ray_sphere(cam, dir, planet_center, atmosphere_radius);
	if (atm.y > 0.0) {
		float t_enter = max(atm.x, 0.0);
		float t_exit  = min(atm.y, scene_t);
		bool have_depth = scene_t < 1e19;
		// The sea-level sphere clip exists ONLY to stop limb/space rays from
		// integrating haze straight through the solid planet. When this pixel has
		// a real depth hit, `scene_t` already bounds the integration at the true
		// surface (terrain/water/moon, peaks included), so the sphere must NOT be
		// used — doing so pushed t_enter out to the sphere exit whenever the camera
		// sat below the sea-level sphere (i.e. near the ground), carving a no-haze
		// band that hugged the surface while peaks rose through it. Skip it here.
		// Sea-level sphere clip — a stand-in for the solid surface, but ONLY for
		// pixels with no terrain depth AND ONLY from an ORBITAL camera (above the
		// atmosphere shell). From out there a limb ray whose terrain LOD hasn't
		// streamed would otherwise integrate haze straight through the planet.
		//
		// Inside the atmosphere (ground/flight) it must NOT run: the near-horizon
		// SKY rays just above the terrain DO intersect the sea-level sphere, and
		// clipping them at that near hit (srf.x) chopped the long low-altitude air
		// column down to a tiny near-camera segment — a no-blue band hugging the
		// horizon that popped in/out as the camera crossed the sea-level radius
		// (so going lower OR higher restored it). Real occlusion near the ground is
		// already handled by the terrain depth (scene_t) above.
		float cam_radius = length(cam - planet_center);
		if (!have_depth && cam_radius > atmosphere_radius) {
			vec2 srf = ray_sphere(cam, dir, planet_center, planet_radius);
			if (srf.x > 0.0 && srf.y > 0.0) {
				t_exit = min(t_exit, srf.x);
			}
		}
		if (t_exit > t_enter + 1e-3) {
			float seg_len = t_exit - t_enter;

			const int SAMPLES = 6;
			float optical_depth = 0.0;
			for (int i = 0; i < SAMPLES; i++) {
				float t = t_enter + seg_len * (float(i) + 0.5) / float(SAMPLES);
				vec3 p = cam + dir * t;
				float h = (length(p - planet_center) - planet_radius)
					/ max(atmosphere_radius - planet_radius, 1.0);
				optical_depth += exp(-clamp(h, 0.0, 1.0) * 5.0);
			}
			optical_depth *= seg_len / float(SAMPLES) / max(atmosphere_radius - planet_radius, 1.0);

			// Mie forward lobe + sun direction.
			vec3 to_sun = -normalize(sun_direction);
			float cos_a = dot(dir, to_sun);
			float g = mie_g;
			float mie_phase = (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * cos_a, 1.5);
			mie_phase *= 0.08;

			// Sun altitude at the camera (drives day/night + sunset warmth).
			vec3 view_to_planet = normalize(planet_center - cam);
			float up_dot_sun = clamp(dot(-view_to_planet, to_sun), -1.0, 1.0);
			float day = smoothstep(-0.25, 0.25, up_dot_sun);

			// Sunset reddening: low sun → warm sky.
			float sun_height = clamp(up_dot_sun, 0.0, 1.0);
			vec3  sun_tint   = mix(vec3(1.0, 0.48, 0.18), vec3(1.0),
			                       smoothstep(0.0, 0.42, sun_height));

			// COLOUR is the saturated in-scatter HUE — it must NOT carry
			// optical_depth. Coverage (out_a, below) already carries the path
			// length via Beer–Lambert; baking optical_depth into the colour too
			// made the visible blue fall off as optical_depth², so thin horizon
			// paths from altitude collapsed to grey/black ("no haze") and only
			// bloomed into blue once you descended. Hue here, amount in alpha.
			vec3 rayleigh = rayleigh_color * scattering_strength * day * sun_tint;
			vec3 mie      = mie_color      * mie_phase     * mie_strength       * day;
			// Warm band toward the low sun.
			float horizon_glow = smoothstep(0.55, 0.985, cos_a)
			                   * (1.0 - smoothstep(0.08, 0.40, sun_height));
			vec3 sunset = vec3(1.0, 0.42, 0.16) * horizon_glow
			            * scattering_strength * day;

			out_col = rayleigh + mie + sunset;
			// Cap the haze opacity below 1.0 so the long horizon path never becomes
			// FULLY opaque — otherwise the atmosphere paints solid over the distant
			// cloud deck and it looks hard-clipped at the horizon line. Capping lets
			// the far clouds/terrain fade through the haze instead.
			// Beer–Lambert in-scatter saturation, NOT a linear ramp. The old
			// `optical_depth * 0.55` sat flat near zero for thin, high-altitude
			// view paths, so from altitude the surface below showed no haze at all
			// and it only "kicked in" once you dropped close enough for the dense
			// near-surface air to dominate the ray — reading as a hard gap between
			// the atmosphere band and the ground. The exponential rises steeply for
			// small optical depth (thin paths still tint) and saturates toward the
			// cap for long horizon paths (the limb halo stays the same), so the haze
			// now fades smoothly all the way down to the surface at any altitude.
			out_a   = clamp(max(1.0 - exp(-optical_depth * 1.6), space_alpha), 0.0, 0.82);
			// Let the bright sun disc punch THROUGH the shell (no blue/orange veil)
			// when the sun is high. Two guards stop this from carving a hard no-haze
			// band along the horizon at sunset:
			//   * tight cone (0.9985 ≈ 3° vs the old 0.985 ≈ 10°) so only the disc
			//     itself clears, not a wide patch of sky/horizon;
			//   * faded out as the sun drops to the horizon (sun_height → 0), so the
			//     low sun is correctly reddened/veiled by the thick horizon air
			//     instead of punching a clear hole exactly where terrain meets sky.
			float sun_prox = smoothstep(0.9985, 0.99995, cos_a);
			sun_prox *= smoothstep(0.04, 0.30, sun_height);
			out_a *= (1.0 - 0.85 * sun_prox);
		}
	}

	ALBEDO = out_col;
	ALPHA  = out_a;
}
