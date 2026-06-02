// Deep-space sky: a dark gradient backdrop with a procedural starfield and a
// soft, clumpy galaxy band. Runs as a `shader_type sky` material so it costs one
// cheap pass over the background (no geometry) and feeds the environment's
// sky-based ambient light. The sun itself is a separate emissive mesh, not here.
shader_type sky;

uniform vec3  base_top      : source_color = vec3(0.004, 0.005, 0.012);
uniform vec3  base_horizon  : source_color = vec3(0.010, 0.012, 0.022);

// Starfield. `star_amount` is the fraction of grid cells that host a star.
uniform float star_amount      : hint_range(0.0, 0.3) = 0.10;
uniform float star_brightness = 2.2;

// Galaxy band — a milky great-circle streak tilted across the sky.
uniform vec3  galaxy_axis     = vec3(0.32, 0.88, 0.34);  // pole of the band plane
uniform vec3  galaxy_color    : source_color = vec3(0.55, 0.62, 0.90);
uniform vec3  galaxy_warm     : source_color = vec3(0.90, 0.74, 0.55);  // core tint
uniform float galaxy_intensity : hint_range(0.0, 2.0) = 0.7;


// Robust hash (Dave Hoskins) — no sin(), stable across GPUs.
vec3 hash33(vec3 p3) {
	p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yxx) * p3.zyx);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash33(i + vec3(0,0,0)).x;
	float n100 = hash33(i + vec3(1,0,0)).x;
	float n010 = hash33(i + vec3(0,1,0)).x;
	float n110 = hash33(i + vec3(1,1,0)).x;
	float n001 = hash33(i + vec3(0,0,1)).x;
	float n101 = hash33(i + vec3(1,0,1)).x;
	float n011 = hash33(i + vec3(0,1,1)).x;
	float n111 = hash33(i + vec3(1,1,1)).x;
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
		p = p * 2.13 + vec3(17.0, 5.0, 23.0);
		a *= 0.5;
	}
	return t;
}

// One layer of point stars. Each grid cell hosts a star with probability
// `amount`; the star sits at a centred random spot (so its disc never clips the
// cell edge) with random brightness and a slight blue/warm tint. `star_size` is
// the core radius in cell units — sized so the disc is roughly one pixel.
vec3 star_layer(vec3 dir, float scale, float amount, float star_size) {
	vec3 p  = dir * scale;
	vec3 ip = floor(p);
	vec3 fp = fract(p);
	vec3 h  = hash33(ip);
	if (h.x >= amount) {
		return vec3(0.0);
	}
	vec3 ctr = vec3(0.25) + 0.5 * hash33(ip + 7.3);
	float d  = length(fp - ctr);
	float core = smoothstep(star_size, 0.0, d);
	float bright = 0.4 + 0.6 * fract(h.y * 7.0);
	vec3 tint = mix(vec3(0.72, 0.82, 1.0), vec3(1.0, 0.86, 0.7), h.z);
	return tint * core * bright;
}


// A single DISTANT galaxy: a small inclined elliptical glow with a bright core
// and a soft halo, centred on a fixed sky direction `axis`. Unlike the Milky-Way
// band (a great circle wrapping the whole sky), these read as discrete objects —
// little smudges you can point at — so the sky has several galaxies, not just the
// one band. `size` is the angular radius; `tilt` rotates the ellipse; `mottle_seed`
// decorrelates the internal noise per galaxy.
vec3 distant_galaxy(vec3 dir, vec3 axis, float size, float tilt, vec3 tint, float mottle_seed) {
	vec3 ax = normalize(axis);
	float ca = dot(dir, ax);
	if (ca <= 0.0) {
		return vec3(0.0);   // ignore the antipodal mirror direction
	}
	// Local 2D frame tangent to `axis`, so we can squash one axis into an inclined
	// disc rather than a face-on circle.
	vec3 u = normalize(cross(ax, vec3(0.0, 1.0, 0.0)) + vec3(1e-3, 0.0, 0.0));
	vec3 v = normalize(cross(ax, u));
	vec2 q = vec2(dot(dir, u), dot(dir, v));   // ≈ angular offset from the centre
	float cs = cos(tilt);
	float sn = sin(tilt);
	vec2 e = vec2(q.x * cs - q.y * sn, q.x * sn + q.y * cs);
	e.y *= 2.3;   // squash → inclined disc
	float rr = length(e) / max(size, 1e-4);
	float core = exp(-rr * rr * 5.5);          // bright nucleus
	float halo = exp(-rr * 1.7) * 0.45;        // faint outer disc
	// Mottle with fbm so it isn't a clean gaussian (dust/arm hints).
	float mott = mix(0.65, 1.25, fbm(dir * 55.0 + mottle_seed));
	return tint * (core + halo) * mott;
}

void sky() {
	vec3 dir = EYEDIR;

	// Dark vertical gradient backdrop.
	float up = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
	vec3 col = mix(base_horizon, base_top, up);

	// ── Galaxy band ────────────────────────────────────────────────────────
	// Inherently a great circle on the sky (like the real Milky Way); texture it
	// with clumps + dark dust lanes so it reads as a milky streak, not a ring.
	vec3 gax = normalize(galaxy_axis);
	float band = abs(dot(dir, gax));            // 0 on the plane, 1 at the poles
	float core_band = smoothstep(0.16, 0.0, band);
	float halo_band = smoothstep(0.42, 0.0, band) * 0.35;
	float clumps = fbm(dir * 3.0 + 2.0);
	float fine   = fbm(dir * 8.0 + 7.0);
	float dust   = fbm(dir * 5.0 + 20.0);
	float milk = (core_band + halo_band);
	milk *= mix(0.25, 1.25, clumps);            // brightness varies along the band
	milk *= mix(0.55, 1.0, fine);
	milk *= smoothstep(0.22, 0.70, dust);       // carve dark dust lanes / clumps
	vec3 gcol = mix(galaxy_color, galaxy_warm, clumps * 0.6);
	col += gcol * milk * galaxy_intensity;

	// ── Distant galaxies ─────────────────────────────────────────────────────
	// A handful of discrete galaxy smudges scattered around the sky (different
	// directions, sizes, inclinations and tints) so the view isn't just the one
	// band. Fixed directions → deterministic, recognisable landmarks.
	vec3 gx = vec3(0.0);
	gx += distant_galaxy(dir, vec3( 0.62, 0.30, 0.72), 0.055, 0.7, vec3(0.72, 0.64, 1.00), 0.13);  // blue spiral
	gx += distant_galaxy(dir, vec3(-0.45, 0.78,-0.24), 0.034, 2.1, vec3(1.00, 0.86, 0.70), 0.57);  // warm elliptical
	gx += distant_galaxy(dir, vec3(-0.66,-0.28, 0.55), 0.066, 1.2, vec3(0.95, 0.70, 0.88), 0.81);  // pink/violet
	gx += distant_galaxy(dir, vec3( 0.20,-0.72,-0.60), 0.028, 0.4, vec3(0.78, 0.90, 1.00), 0.34);  // small blue
	gx += distant_galaxy(dir, vec3( 0.86, 0.12,-0.49), 0.042, 2.7, vec3(1.00, 0.96, 0.88), 0.92);  // white lenticular
	col += gx * galaxy_intensity * 1.6;

	// ── Stars ───────────────────────────────────────────────────────────────
	// Two background layers (coarse bright + fine dim) plus extra dense stars
	// concentrated inside the galaxy band.
	vec3 s = star_layer(dir, 150.0, star_amount, 0.16);
	s += star_layer(dir * 1.7 + 5.0, 300.0, star_amount * 0.8, 0.10) * 0.7;
	s += star_layer(dir * 1.3 + 30.0, 210.0, star_amount * 2.2, 0.13) * (core_band + 0.15);
	col += s * star_brightness;

	COLOR = col;
}
