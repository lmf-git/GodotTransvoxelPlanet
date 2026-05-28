// Single-shell atmospheric scattering — cheap approximation suitable for a
// planetary terrain demo. Renders on an inside-facing sphere larger than the
// planet, so the player sees blue sky from below and a thin halo from above.
//
// View-ray vs planet sphere is solved analytically; we compute the segment of
// the ray that lies inside the atmosphere shell, integrate a simplified
// density falloff along it, then split scattering into Rayleigh (blue) and a
// soft Mie sun-direction lobe.

shader_type spatial;
// cull_disabled (was cull_front): from inside the shell — flying near the
// ground after crossing the upper atmosphere boundary — cull_front was
// silently dropping the inside-facing geometry on certain view angles
// because the back-face-vs-camera test got flipped at large distances. With
// cull_disabled both sides always rasterise; the shader's ray-sphere math
// already handles inside vs outside correctly.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled;

// DEPTH_TEXTURE lets us sample the already-rendered scene depth, so we can
// clip the atmosphere integration at the actual surface (terrain / water /
// moon) instead of the ideal `planet_radius` sphere. Without this clip,
// `depth_test_disabled` means the atmosphere paints over whatever is in
// front of it — terrain shows through as atmosphere colour.
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;

uniform vec3  planet_center        = vec3(0.0);
uniform float planet_radius        = 4000.0;
uniform float atmosphere_radius    = 4500.0;
uniform vec3  sun_direction        = vec3(0.6, 0.5, 0.4);  // FROM the sun
uniform vec3  rayleigh_color       = vec3(0.21, 0.45, 0.95);
uniform vec3  mie_color            = vec3(1.0, 0.85, 0.65);
uniform float scattering_strength  = 1.4;
uniform float mie_strength         = 0.45;
uniform float mie_g                = 0.78;
uniform float space_alpha          = 0.0;   // tweak to leave faint glow over stars

varying vec3 v_world_pos;


// Returns (t_enter, t_exit) for ray (origin, dir) vs sphere (center, radius),
// or (-1, -1) on miss.
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

	// Reconstruct world-space distance from the cam along `dir` to whatever
	// the depth buffer says is here. Godot uses reverse-Z, so a depth of 0
	// means "infinity". When the scene is closer than the atmosphere shell,
	// this is what bounds the integration.
	float scene_depth_ndc = texture(depth_tex, SCREEN_UV).r;
	float scene_t = 1e20;   // "no occluder, integrate full segment"
	if (scene_depth_ndc > 0.0) {
		vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, scene_depth_ndc, 1.0);
		// SCREEN_UV.y is top-left origin in Godot; flip for clip space.
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
		// Only clip against the IDEAL sphere when the depth buffer didn't
		// tell us where the real surface is. Trusting srf.x over scene_t was
		// what caused the previous bug: valleys (terrain BELOW planet_radius)
		// got their integration cut short at srf.x, while peaks (terrain
		// ABOVE planet_radius) integrated all the way to scene_t. The result
		// was peaks accumulating more haze than valleys — atmosphere showing
		// "through" the mountain tops. Once we have a real depth_tex sample,
		// scene_t already represents the correct cutoff.
		bool have_depth = scene_t < 1e19;
		if (srf.y > 0.0 && !have_depth) {
			if (srf.x > 0.0) {
				t_exit = min(t_exit, srf.x);
			} else {
				t_enter = max(t_enter, srf.y);
			}
		} else if (srf.y > 0.0 && srf.x <= 0.0) {
			// Camera inside the ideal sphere (e.g. dipped below sea level).
			// Push t_enter past the back of the sphere so we don't accumulate
			// "underground" optical depth.
			t_enter = max(t_enter, srf.y);
		}
		if (t_exit > t_enter + 1e-3) {
			float seg_len = t_exit - t_enter;

			// Sample 6 points along the segment, accumulate Rayleigh density.
			const int SAMPLES = 6;
			float optical_depth = 0.0;
			for (int i = 0; i < SAMPLES; i++) {
				float t = t_enter + seg_len * (float(i) + 0.5) / float(SAMPLES);
				vec3 p = cam + dir * t;
				float h = (length(p - planet_center) - planet_radius)
					/ max(atmosphere_radius - planet_radius, 1.0);
				float density = exp(-clamp(h, 0.0, 1.0) * 5.0);
				optical_depth += density;
			}
			optical_depth *= seg_len / float(SAMPLES) / max(atmosphere_radius - planet_radius, 1.0);

			// Sun phase: Henyey-Greenstein approximation for the Mie lobe.
			// `sun_direction` points FROM the sun toward the planet (per the
			// uniform comment), so the direction TOWARD the sun from any point
			// is `-sun_direction`. Forward-scatter lobe peaks when the view
			// ray looks at the sun: cos_a should be ~1 when dir ≈ -sun_dir.
			vec3 to_sun = -normalize(sun_direction);
			float cos_a = dot(dir, to_sun);
			float g = mie_g;
			float mie_phase = (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * cos_a, 1.5);
			mie_phase *= 0.08;

			// Sun-altitude factor — the sky brightens with the sun above the
			// horizon at the camera's position. The "up" at the camera is
			// `-view_to_planet` (the radial outward from planet center to cam);
			// the sun is above if that radial aligns with `to_sun`.
			vec3 view_to_planet = normalize(planet_center - cam);
			float up_dot_sun = clamp(dot(-view_to_planet, to_sun), -1.0, 1.0);
			float day = smoothstep(-0.25, 0.25, up_dot_sun);

			vec3 rayleigh = rayleigh_color * optical_depth * scattering_strength * day;
			vec3 mie      = mie_color      * mie_phase     * mie_strength       * day;

			out_col = rayleigh + mie;
			// Softer alpha so atmosphere doesn't fully blanket mid-altitude
			// terrain (the original 1.5 multiplier made mountains visible only
			// at the very peaks, with everything below them washed out). 0.55
			// keeps a proper scattering halo and horizon haze while letting
			// the surface read through.
			out_a   = clamp(max(optical_depth * 0.55, space_alpha), 0.0, 1.0);
		}
	}

	ALBEDO = out_col;
	ALPHA  = out_a;
}
