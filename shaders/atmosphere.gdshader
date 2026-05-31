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
		vec2 srf = ray_sphere(cam, dir, planet_center, planet_radius);
		float t_enter = max(atm.x, 0.0);
		float t_exit  = min(atm.y, scene_t);
		bool have_depth = scene_t < 1e19;
		if (srf.y > 0.0 && !have_depth) {
			if (srf.x > 0.0) {
				t_exit = min(t_exit, srf.x);
			} else {
				t_enter = max(t_enter, srf.y);
			}
		} else if (srf.y > 0.0 && srf.x <= 0.0) {
			t_enter = max(t_enter, srf.y);
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

			vec3 rayleigh = rayleigh_color * optical_depth * scattering_strength * day * sun_tint;
			vec3 mie      = mie_color      * mie_phase     * mie_strength       * day;
			// Warm band toward the low sun.
			float horizon_glow = smoothstep(0.55, 0.985, cos_a)
			                   * (1.0 - smoothstep(0.08, 0.40, sun_height));
			vec3 sunset = vec3(1.0, 0.42, 0.16) * horizon_glow * optical_depth
			            * scattering_strength * day;

			out_col = rayleigh + mie + sunset;
			out_a   = clamp(max(optical_depth * 0.55, space_alpha), 0.0, 1.0);
			// Let the bright sun disc punch THROUGH the shell (no blue/orange veil).
			float sun_prox = smoothstep(0.985, 0.9999, cos_a);
			out_a *= (1.0 - 0.92 * sun_prox);
		}
	}

	ALBEDO = out_col;
	ALPHA  = out_a;
}
