// Planetary terrain shader — triplanar projection (no UVs needed) with
// slope/altitude/latitude-driven biome blending and procedural detail noise.
//
// Operates in OBJECT space so biomes (continents, polar caps, snow lines)
// stay locked to the planet as it rotates and orbits. World-space lighting
// still works correctly because Godot's default normal handling transforms
// NORMAL by MODEL_NORMAL_MATRIX → VIEW_MATRIX automatically.
//
// Inputs (uniforms):
//   planet_radius        — base sphere radius
//   polar_axis           — planet's spin axis in OBJECT space (constant)
//   polar_cap_latitude   — |dot(radial, axis)| above which snow dominates
//   snow_altitude        — altitude at which snow takes over (mid-latitudes)
//   equator_warmth       — how much the equator pushes the snow line up
//   rock_slope_threshold — surface dot up below this becomes rock
//   color_*              — biome tints

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3  planet_center        = vec3(0.0);
uniform float planet_radius        : hint_range(100.0, 100000.0) = 4000.0;
uniform vec3  polar_axis           = vec3(0.0, 1.0, 0.0);   // planet's rotational axis (unit vector)
uniform float polar_cap_latitude   : hint_range(0.0, 1.0)        = 0.62;  // |dot(radial, axis)| above which snow dominates
uniform float polar_cap_fade       : hint_range(0.0, 0.5)        = 0.18;
uniform float snow_altitude        : hint_range(-200.0, 1000.0)  = 240.0;
uniform float snow_fade            : hint_range(1.0, 200.0)      = 70.0;
uniform float equator_warmth       : hint_range(0.0, 1.0)        = 0.65;  // how much to bias equator away from snow
uniform float beach_altitude       : hint_range(-100.0, 100.0)   = 8.0;
uniform float beach_fade           : hint_range(0.1, 100.0)      = 14.0;
uniform float rock_slope_threshold : hint_range(0.0, 1.0)        = 0.40;
uniform float rock_slope_fade      : hint_range(0.001, 0.5)      = 0.22;

uniform vec3 color_grass  : source_color = vec3(0.28, 0.46, 0.18);   // temperate green
uniform vec3 color_dirt   : source_color = vec3(0.45, 0.33, 0.20);   // arable earth
uniform vec3 color_rock   : source_color = vec3(0.36, 0.34, 0.32);   // cliff stone
uniform vec3 color_sand   : source_color = vec3(0.82, 0.72, 0.46);   // beach
uniform vec3 color_snow   : source_color = vec3(0.94, 0.95, 0.98);   // polar / peak ice
uniform vec3 color_jungle : source_color = vec3(0.15, 0.32, 0.10);   // equatorial dense forest
uniform vec3 color_desert : source_color = vec3(0.86, 0.62, 0.30);   // hot arid belt
uniform vec3 color_tundra : source_color = vec3(0.55, 0.55, 0.48);   // sub-polar moss / lichen
uniform vec3 color_savanna: source_color = vec3(0.62, 0.55, 0.30);   // dry grass

uniform float desert_band_lo  : hint_range(0.0, 1.0) = 0.20;
uniform float desert_band_hi  : hint_range(0.0, 1.0) = 0.40;
uniform float tundra_band_lo  : hint_range(0.0, 1.0) = 0.48;
uniform float tundra_band_hi  : hint_range(0.0, 1.0) = 0.58;

uniform float detail_scale_a : hint_range(0.001, 1.0) = 0.05;
uniform float detail_scale_b : hint_range(0.001, 1.0) = 0.25;
uniform float detail_amp     : hint_range(0.0, 0.5)   = 0.24;

uniform float macro_scale    : hint_range(0.0001, 0.1) = 0.0045;
uniform float macro_amp      : hint_range(0.0, 1.0)    = 0.55;

uniform float roughness_base : hint_range(0.0, 1.0) = 0.92;
uniform float specular_base  : hint_range(0.0, 1.0) = 0.04;

// Both varyings are in OBJECT space (the planet's local frame). That keeps
// biome zones, latitude, and triplanar textures locked to the planet as it
// rotates / orbits — they're properties of the place on the planet, not of
// where the planet happens to be in the world this frame.
varying vec3 v_obj_pos;
varying vec3 v_obj_normal;


// ─── Cheap pseudo-hash + value noise ────────────────────────────────────────

float hash3(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float noise3(vec3 p) {
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
	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);
	float nxy0 = mix(nx00, nx10, f.y);
	float nxy1 = mix(nx01, nx11, f.y);
	return mix(nxy0, nxy1, f.z);
}

float fbm3(vec3 p, int octaves) {
	float total = 0.0;
	float amp = 0.5;
	for (int i = 0; i < octaves; i++) {
		total += noise3(p) * amp;
		p *= 2.07;
		amp *= 0.5;
	}
	return total;
}


// ─── Triplanar sampler over a parametric color function ─────────────────────

vec3 triplanar_tinted(vec3 base, vec3 pos, vec3 nrm, float scale) {
	vec3 blend = abs(nrm);
	blend = max(blend - 0.2, vec3(0.0));
	blend /= max(dot(blend, vec3(1.0)), 1e-4);
	float nx = fbm3(pos.yzx * scale + 1.7, 4);
	float ny = fbm3(pos.xzy * scale + 3.1, 4);
	float nz = fbm3(pos.xyz * scale + 5.3, 4);
	float n = nx * blend.x + ny * blend.y + nz * blend.z;
	// Modulate base color by a darken/lighten range driven by noise.
	float mod_ = (n - 0.5) * 2.0 * detail_amp;
	return clamp(base + base * mod_, vec3(0.0), vec3(1.0));
}


void vertex() {
	v_obj_pos    = VERTEX;
	v_obj_normal = NORMAL;
}


void fragment() {
	vec3 wp = v_obj_pos;            // object-space position (planet center = origin)
	vec3 wn = normalize(v_obj_normal);
	float r = length(wp);
	vec3 radial = (r > 1e-6) ? wp / r : vec3(0.0, 1.0, 0.0);
	float altitude = r - planet_radius;

	// Latitude: |dot(radial, axis)| → 0 = equator, 1 = pole.
	vec3 axis = normalize(polar_axis);
	float lat = abs(dot(radial, axis));
	float polar_t = smoothstep(polar_cap_latitude - polar_cap_fade,
	                            polar_cap_latitude + polar_cap_fade,
	                            lat);
	float equator_t = 1.0 - smoothstep(0.05, 0.30, lat);   // 1 at equator, 0 elsewhere

	// Desert and tundra bands — hot arid zone slightly off the equator,
	// tundra ring between temperate and polar.
	float desert_t = smoothstep(desert_band_lo - 0.05, desert_band_lo, lat)
	               * (1.0 - smoothstep(desert_band_hi, desert_band_hi + 0.05, lat));
	float tundra_t = smoothstep(tundra_band_lo - 0.04, tundra_band_lo, lat)
	               * (1.0 - smoothstep(tundra_band_hi, tundra_band_hi + 0.04, lat));

	// Slope: 1.0 = flat (normal aligned with radial), 0.0 = cliff face.
	// abs() so the calculation works regardless of which way the mesher's
	// vertex normals end up pointing — biomes care about flat-vs-steep, not
	// inside-vs-outside.
	float slope = clamp(abs(dot(wn, radial)), 0.0, 1.0);

	// Macro biome variation — large-scale noise modulates wet↔dry across each
	// latitude band. Used to break the latitude bands into mottled regions.
	float macro = (fbm3(wp * macro_scale, 5) - 0.5) * 2.0 * macro_amp;
	float biome_temp = clamp(0.5 + macro, 0.0, 1.0);

	// Build the lowland color by mixing through the latitude bands.
	vec3 lowland = mix(color_grass, color_dirt, biome_temp);
	// Tundra ring — mossy gray-green.
	lowland = mix(lowland, color_tundra, tundra_t * 0.85);
	// Desert / savanna band. Savanna is the macro-noise wet edge of the desert.
	vec3 desert_or_savanna = mix(color_savanna, color_desert, biome_temp);
	lowland = mix(lowland, desert_or_savanna, desert_t * 0.92);
	// Equatorial jungle dominates the equator regardless of macro_temp.
	lowland = mix(lowland, color_jungle, equator_t * 0.78);

	// Beach / sand near sea level. Suppressed at the poles (ice instead).
	float beach_t = 1.0 - smoothstep(beach_altitude, beach_altitude + beach_fade, altitude);
	beach_t = clamp(beach_t, 0.0, 1.0) * (1.0 - polar_t);
	lowland = mix(lowland, color_sand, beach_t * 0.85);

	// Altitude snow line, lowered toward poles, raised at the equator.
	float lat_snow_floor = mix(snow_altitude, beach_altitude - 30.0, polar_t);
	lat_snow_floor = mix(lat_snow_floor, snow_altitude + 350.0 * equator_warmth, equator_t);
	float snow_t = smoothstep(lat_snow_floor, lat_snow_floor + snow_fade, altitude);
	// Snow only on flat enough surfaces — too steep, it slips off.
	snow_t *= smoothstep(0.45, 0.85, slope);
	// Polar caps: force snow on flat terrain regardless of altitude.
	snow_t = max(snow_t, polar_t * smoothstep(0.40, 0.80, slope));
	lowland = mix(lowland, color_snow, clamp(snow_t, 0.0, 1.0));

	// Rock on steep slopes regardless of altitude or latitude.
	float rock_t = 1.0 - smoothstep(
		rock_slope_threshold - rock_slope_fade,
		rock_slope_threshold + rock_slope_fade,
		slope);
	vec3 base_albedo = mix(lowland, color_rock, rock_t);

	// Triplanar detail to break up the surface at close range.
	base_albedo = triplanar_tinted(base_albedo, wp, wn, detail_scale_a);
	base_albedo = mix(base_albedo, triplanar_tinted(base_albedo, wp, wn, detail_scale_b), 0.35);

	ALBEDO = base_albedo;
	ROUGHNESS = mix(roughness_base * 0.7, roughness_base, rock_t);
	SPECULAR  = specular_base;
}
