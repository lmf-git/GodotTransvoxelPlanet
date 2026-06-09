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
// Lapse rate — temperature drops with altitude, so high peaks read cold (and
// snow-capped) even at the equator. Without this, `temperature` was purely
// latitude-driven, so equatorial mountain tops stayed "warm" and came out green
// alpine instead of snow.
uniform float lapse_rate           : hint_range(0.0, 1.0)        = 0.6;
uniform float lapse_full_altitude  : hint_range(200.0, 3000.0)   = 1500.0; // altitude above sea where the drop saturates
uniform float beach_altitude       : hint_range(-300.0, 100.0)   = 8.0;
uniform float beach_fade           : hint_range(0.1, 100.0)      = 14.0;
// Steep surfaces are bare ROCK. Pushed up from 0.30 (slope 1 = flat, 0 = cliff): the
// old value only rocked near-vertical faces, so beach cliffs and canyon/mountain walls
// (~45–65°) showed their lowland biome — sand/orange — instead of stone. 0.55/0.28
// makes anything steeper than a gentle hill read as cliff rock.
uniform float rock_slope_threshold : hint_range(0.0, 1.0)        = 0.55;
uniform float rock_slope_fade      : hint_range(0.001, 0.5)      = 0.28;

uniform vec3 color_grass  : source_color = vec3(0.28, 0.46, 0.18);   // temperate green
uniform vec3 color_dirt   : source_color = vec3(0.45, 0.33, 0.20);   // arable earth
uniform vec3 color_rock        : source_color = vec3(0.36, 0.34, 0.32);   // cliff stone (base)
uniform vec3 color_rock_dark   : source_color = vec3(0.18, 0.17, 0.16);   // shadowed cracks / wet rock
uniform vec3 color_rock_light  : source_color = vec3(0.58, 0.54, 0.48);   // sun-bleached / dry rock face
uniform float rock_texture_scale  : hint_range(0.001, 0.5) = 0.04;  // wavelength of the rock-banding noise
uniform float rock_texture_blend  : hint_range(0.0, 1.0)   = 0.55;  // how strongly the rock texture replaces the flat rock colour
uniform float rock_snow_altitude  : hint_range(0.0, 2000.0) = 600.0; // snow on rock kicks in above this in cold/temperate biomes
uniform float rock_snow_fade      : hint_range(10.0, 400.0) = 180.0;
uniform vec3 color_sand   : source_color = vec3(0.82, 0.72, 0.46);   // beach
uniform vec3 color_snow   : source_color = vec3(0.94, 0.95, 0.98);   // polar / peak ice
uniform vec3 color_jungle : source_color = vec3(0.15, 0.32, 0.10);   // equatorial dense forest
uniform vec3 color_desert : source_color = vec3(0.86, 0.62, 0.30);   // hot arid belt
uniform vec3 color_tundra : source_color = vec3(0.55, 0.55, 0.48);   // sub-polar moss / lichen
uniform vec3 color_savanna: source_color = vec3(0.62, 0.55, 0.30);   // dry grass
uniform vec3 color_swamp    : source_color = vec3(0.18, 0.28, 0.16); // wet lowland — peat / mangrove
uniform vec3 color_boreal   : source_color = vec3(0.20, 0.32, 0.20); // cold-wet conifer forest
uniform vec3 color_alpine   : source_color = vec3(0.48, 0.50, 0.46); // high-altitude bare rock / lichen — between rock and tundra
uniform vec3 color_redrock  : source_color = vec3(0.62, 0.32, 0.22); // hot-arid highland — mesa / canyon walls
uniform vec3 color_steppe   : source_color = vec3(0.58, 0.60, 0.32); // mid-latitude dry grassland

uniform float desert_band_lo  : hint_range(0.0, 1.0) = 0.20;
uniform float desert_band_hi  : hint_range(0.0, 1.0) = 0.40;
uniform float tundra_band_lo  : hint_range(0.0, 1.0) = 0.48;
uniform float tundra_band_hi  : hint_range(0.0, 1.0) = 0.58;

uniform float detail_scale_a : hint_range(0.001, 1.0) = 0.05;
uniform float detail_scale_b : hint_range(0.001, 1.0) = 0.25;
uniform float detail_amp     : hint_range(0.0, 0.5)   = 0.24;

// Two decorrelated macro fields:
//   `macro` is HUMIDITY (wet ↔ dry)
//   `temp_macro` is TEMPERATURE OFFSET added to the latitude-derived base temp
// Splitting them gives a real 2D climate grid (cold-wet ≠ cold-dry, etc.)
// instead of the single hot/dry-cold/wet axis we had before.
uniform float macro_scale    : hint_range(0.0001, 0.1) = 0.0035;   // smaller patches → tighter, more visible biome cells
uniform float macro_amp      : hint_range(0.0, 1.0)    = 0.95;
uniform float temp_macro_scale : hint_range(0.0001, 0.1) = 0.0022; // larger patches → continental-scale temperature anomalies
uniform float temp_macro_amp   : hint_range(0.0, 0.5)  = 0.28;

uniform float roughness_base : hint_range(0.0, 1.0) = 0.92;
uniform float specular_base  : hint_range(0.0, 1.0) = 0.04;

// ─── Aerial perspective (atmospheric distance haze) ─────────────────────────
// Distant ground fades toward the sky/atmosphere colour and brightens toward the
// sun — the depth cue SpaceEngine and I-Novae (Infinity: Battlescape) lean on to
// sell planetary scale. Faded out as the camera climbs into space (it's the path
// through the air that hazes, not raw distance), so the globe doesn't wash out
// from orbit. `sun_direction` / `planet_center` are world-space, set per frame.
uniform vec3  sun_direction    = vec3(0.0, 1.0, 0.0);
uniform vec3  haze_color       : source_color = vec3(0.52, 0.66, 0.84);
uniform vec3  haze_sun_color   : source_color = vec3(1.0, 0.92, 0.78);
uniform float haze_density     : hint_range(0.0, 0.0005) = 0.00008;
uniform float haze_strength    : hint_range(0.0, 1.0)    = 0.7;
uniform float haze_alt_falloff : hint_range(0.0, 0.01)   = 0.00033;

// Procedural micro-normal (bump) strength + the view-distance band over which it
// fades out, so surface relief reads up close without shimmering on far hills.
uniform float bump_strength    : hint_range(0.0, 4.0)  = 0.6;
uniform float bump_fade_near   : hint_range(0.0, 2000.0) = 120.0;
uniform float bump_fade_far    : hint_range(0.0, 4000.0) = 900.0;

// Procedurally-generated PBR ground-detail texture (a seamless grain map made from
// noise in world.gd — no texture files). Triplanar-sampled at close range and used
// to drive albedo grain, roughness variation AND the micro-normal, so the biome
// ground reads as a real material surface up close rather than flat colour.
uniform sampler2D detail_grain_tex : hint_default_white;
uniform float detail_grain_scale : hint_range(0.001, 0.5) = 0.06;
uniform float detail_grain_amt   : hint_range(0.0, 0.5)   = 0.18;  // albedo grain depth
uniform float detail_rough_amt   : hint_range(0.0, 0.5)   = 0.20;  // roughness variation depth

// Both varyings are in OBJECT space (the planet's local frame). That keeps
// biome zones, latitude, and triplanar textures locked to the planet as it
// rotates / orbits — they're properties of the place on the planet, not of
// where the planet happens to be in the world this frame.
varying vec3 v_obj_pos;
varying vec3 v_obj_normal;
// Vertex colour carries (1 − urban) in R — see rust mesh_to_dict. A chunk with no
// colour array defaults to white (R = 1 ⇒ urban 0), so the urban tint is opt-in.
varying vec4 v_color;

// Packed/trodden urban ground colour the terrain blends toward under a settlement.
uniform vec3 color_urban : source_color = vec3(0.34, 0.31, 0.27);


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
	v_color      = COLOR;
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

	// Two decorrelated climate fields: humidity and temperature anomaly.
	// `humidity`   in [0, 1]: 0 = dry, 1 = wet
	// `temp_anom`  in [-1, 1]: pushes the latitude-derived base temperature up or down
	float humidity  = clamp(0.5 + (fbm3(wp * macro_scale, 5) - 0.5) * 2.0 * macro_amp, 0.0, 1.0);
	float temp_anom = (fbm3(wp * temp_macro_scale + 17.0, 4) - 0.5) * 2.0 * temp_macro_amp;
	// Base temperature from LATITUDE (sun angle): 1.0 at equator, 0.0 at pole.
	// `lat` is |dot(radial, axis)| where 0 = equator, 1 = pole — invert it.
	// Add temp_anom so continents can be locally hotter/colder than their latitude
	// would suggest (continental interiors, ocean currents — the visual stand-in).
	// Lapse rate: subtract a 0→lapse_rate ramp as altitude climbs above sea
	// (beach_altitude ≈ sea level). High ground becomes genuinely cold → alpine
	// meadows, then bare alpine, then snow toward the peaks — real vertical biome
	// zonation instead of one flat colour up the mountain.
	float lapse = clamp((altitude - beach_altitude) / max(lapse_full_altitude, 1.0), 0.0, 1.0) * lapse_rate;
	float temperature = clamp(1.0 - lat + temp_anom - lapse, 0.0, 1.0);
	// Elevation index: 0 near sea, 1 at high alpine. Used as the LOW/HIGH axis.
	float elev_t = smoothstep(0.0, 600.0, altitude);

	// 2×2 climate grid drives the lowland (low-elevation) base color:
	//   cold + dry  → tundra
	//   cold + wet  → boreal forest
	//   hot  + dry  → desert / savanna mix
	//   hot  + wet  → jungle
	// Mid-temperate values interpolate between adjacent buckets — no hard band edges.
	vec3 cold_dry = color_tundra;
	vec3 cold_wet = color_boreal;
	vec3 hot_dry  = mix(color_savanna, color_desert, smoothstep(0.30, 0.85, 1.0 - humidity));
	vec3 hot_wet  = color_jungle;
	// Temperate band (around temperature 0.5) blends to grass+dirt classics.
	vec3 temp_dry = mix(color_steppe, color_dirt, smoothstep(0.40, 0.85, 1.0 - humidity));
	vec3 temp_wet = mix(color_grass, color_swamp, smoothstep(0.55, 0.95, humidity));
	// Mix along the temperature axis with a TRIANGULAR weighting around the
	// temperate centre (0.5), so cold/temperate/hot all get distinct regions
	// rather than a flat hot↔cold lerp.
	float cold_w = max(0.0, 1.0 - temperature * 2.0);     // peaks at temp=0
	float hot_w  = max(0.0, temperature * 2.0 - 1.0);     // peaks at temp=1
	float temp_w = 1.0 - cold_w - hot_w;                  // peaks at temp=0.5
	vec3 cold = mix(cold_dry, cold_wet, humidity);
	vec3 temperate = mix(temp_dry, temp_wet, humidity);
	vec3 hot  = mix(hot_dry, hot_wet, humidity);
	vec3 lowland = cold * cold_w + temperate * temp_w + hot * hot_w;

	// Highland (high-elevation) base: alpine bare rock dominates, tinted red
	// in hot-dry climates (Mars-like mesas) and snowy in cold ones. The redrock
	// tint is confined to MID elevations (mesa country): above ~900 m every
	// climate converges on bare alpine rock — high peaks were reading as sandy
	// desert because hot-dry summits kept their redrock/desert tint all the way up.
	float mesa_band = 1.0 - smoothstep(550.0, 950.0, altitude);
	vec3 highland = mix(color_alpine, color_redrock,
			smoothstep(0.55, 0.85, temperature) * smoothstep(0.35, 0.05, humidity) * mesa_band);
	highland = mix(highland, color_snow, smoothstep(0.30, 0.05, temperature));

	// Blend lowland ↔ highland by elevation.
	lowland = mix(lowland, highland, elev_t);

	// Equatorial dense jungle on flat humid lowland — keep as an explicit
	// "always there at the equator if not too dry" pass so the equator still
	// has its visual signature even when temp_anom dips locally.
	lowland = mix(lowland, color_jungle, equator_t * humidity * 0.6 * (1.0 - elev_t));

	// Beach / sand near sea level. Suppressed at the poles (ice instead).
	float beach_t = 1.0 - smoothstep(beach_altitude, beach_altitude + beach_fade, altitude);
	beach_t = clamp(beach_t, 0.0, 1.0) * (1.0 - polar_t) * smoothstep(0.50, 0.80, slope);  // flat shore only — steep coast is bare rock, not sand
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

	// Rock on steep slopes regardless of altitude or latitude — plus an
	// ALTITUDE floor: above ~700 m bare rock takes over even on the flatter
	// crests and benches (real summits are stone fields, not turf), which kills
	// both the "sandy peaks" and the "grass on sharp high hills" reads. The
	// snow-on-rock pass below then caps the cold ones white.
	float rock_t = 1.0 - smoothstep(
		rock_slope_threshold - rock_slope_fade,
		rock_slope_threshold + rock_slope_fade,
		slope);
	rock_t = max(rock_t, smoothstep(700.0, 1000.0, altitude) * 0.85);
	// Procedural rock TEXTURE — banded dark/light noise driven by a triplanar
	// fbm sample, then a finer-frequency overlay for surface crack detail.
	// This is what turns the flat `color_rock` into something that reads as
	// stone (alternating shadow bands, lighter spots where the rock catches
	// the sun) rather than a uniform grey. Sampled in object space so it
	// stays locked to the planet as it spins.
	vec3 ax = abs(wn);
	float wsum_rock = max(ax.x + ax.y + ax.z, 1e-4);
	vec3 rblend = ax / wsum_rock;
	float rband_x = fbm3(wp.yzx * rock_texture_scale, 4);
	float rband_y = fbm3(wp.zxy * rock_texture_scale + 11.0, 4);
	float rband_z = fbm3(wp.xyz * rock_texture_scale + 23.0, 4);
	float rband = rband_x * rblend.x + rband_y * rblend.y + rband_z * rblend.z;
	rband = smoothstep(0.30, 0.70, rband);                  // sharpen to read as banding, not smear
	vec3 rock_textured = mix(color_rock_dark, color_rock_light, rband);
	rock_textured = mix(color_rock, rock_textured, rock_texture_blend);
	// Snow CAPS on rock — only when the local biome is cold enough AND we're
	// above a threshold altitude. `temperature` already accounts for latitude
	// + temp anomaly, so a cold valley at low latitude won't suddenly turn
	// rocks white; only the genuinely cold-and-elevated rock gets capped.
	float rock_cold = smoothstep(0.55, 0.20, temperature);   // 1 in cold biomes, 0 in hot
	float rock_high = smoothstep(rock_snow_altitude, rock_snow_altitude + rock_snow_fade, altitude);
	// Snow caches in cracks/holes (low rband = darker = depressions) but
	// thicker on the tops — so weight by altitude * cold * (a bit of rband)
	// so the snow follows the texture rather than painting a flat coat.
	float snow_on_rock = rock_cold * rock_high * mix(0.55, 1.0, rband);
	rock_textured = mix(rock_textured, color_snow, clamp(snow_on_rock, 0.0, 1.0));
	vec3 base_albedo = mix(lowland, rock_textured, rock_t);

	// Polar caps stay ice-covered even over rock — snow only sheds off the
	// near-vertical faces. Re-applied AFTER the rock pass (which otherwise
	// paints every steep polar slope bare grey), so the cap reads as
	// snow-capped peaks instead of rock. This is what makes the spin-axis
	// poles actually look like ice caps.
	float cap_snow = polar_t * smoothstep(0.12, 0.45, slope);
	base_albedo = mix(base_albedo, color_snow, clamp(cap_snow, 0.0, 1.0));

	// Triplanar detail to break up the surface at close range.
	base_albedo = triplanar_tinted(base_albedo, wp, wn, detail_scale_a);
	base_albedo = mix(base_albedo, triplanar_tinted(base_albedo, wp, wn, detail_scale_b), 0.35);

	ALBEDO = base_albedo;

	// Urban ground: under a settlement the terrain itself reads as packed/trodden earth
	// (the city affects the BIOME — there is no concrete disc on top). v_color.r holds
	// 1 − urban, so urban climbs toward 1 on the town pad and the over-paint washes out
	// grass/sand into worn dirt. The street-grid + buildings still sit on top.
	float urban = clamp(1.0 - v_color.r, 0.0, 1.0);
	ALBEDO = mix(ALBEDO, color_urban, urban * 0.85);

	// ─── Procedural PBR ground-detail texture (triplanar) ─────────────────────
	// A seamless grain map generated from noise in world.gd (no texture files),
	// projected triplanar in object space so it locks to the planet. One sample
	// drives three PBR channels — albedo grain, roughness variation and the
	// micro-normal — so the biome ground reads as a real material up close. Faded
	// out with distance so it doesn't shimmer on far hills.
	float det_fade = 1.0 - smoothstep(bump_fade_near, bump_fade_far, length(VERTEX));
	vec3 tw = abs(wn);
	tw /= max(tw.x + tw.y + tw.z, 1e-4);
	float grain_raw =
		  texture(detail_grain_tex, wp.yz * detail_grain_scale).r * tw.x
		+ texture(detail_grain_tex, wp.zx * detail_grain_scale).r * tw.y
		+ texture(detail_grain_tex, wp.xy * detail_grain_scale).r * tw.z;
	float grain = (grain_raw - 0.5) * det_fade;   // centred, distance-faded
	ALBEDO *= 1.0 + grain * detail_grain_amt * 2.0;

	// ─── PBR response per surface ───────────────────────────────────────────
	// Roughness/specular vary by what we're standing on: bare rock is matte and
	// rough, sand a touch smoother, snow/ice noticeably glossier (a low-roughness
	// sheen), and damp shoreline ground glistens. metallic stays 0 (all dielectric).
	float wet = smoothstep(beach_altitude + beach_fade, beach_altitude, altitude); // near the waterline
	float icy = clamp(snow_t + cap_snow + snow_on_rock, 0.0, 1.0);
	float rough = mix(roughness_base * 0.7, roughness_base, rock_t);  // rock rough, lowland less
	rough = mix(rough, 0.45, icy);   // ice/snow glossier
	rough = mix(rough, 0.55, wet);   // wet shore glistens
	rough += grain * detail_rough_amt * 2.0;   // fine roughness grain from the detail texture
	rough = mix(rough, 0.95, urban * 0.6);     // urban ground is matte, packed earth
	ROUGHNESS = clamp(rough, 0.0, 1.0);
	SPECULAR  = clamp(specular_base + icy * 0.35 + wet * 0.25, 0.0, 1.0);

	// ─── Micro-normal from the SAME detail texture ────────────────────────────
	// Treat the triplanar grain as a height field and perturb the interpolated
	// NORMAL by its gradient (Quilez bump-mapping-without-tangents, screen-space
	// derivatives — no TANGENT/BINORMAL needed). So the generated texture also
	// supplies surface relief, not just colour.
	float bstr = bump_strength * det_fade;
	if (bstr > 0.001) {
		vec3 N = NORMAL;
		vec3 dpx = dFdx(VERTEX);
		vec3 dpy = dFdy(VERTEX);
		vec3 r1 = cross(dpy, N);
		vec3 r2 = cross(N, dpx);
		float det = dot(dpx, r1);
		if (abs(det) > 1e-8) {
			vec3 grad = (dFdx(grain_raw) * r1 + dFdy(grain_raw) * r2) / det;
			NORMAL = normalize(N - bstr * grad);
		}
	}

	// ─── Aerial perspective ───────────────────────────────────────────────────
	vec3 cam_world = INV_VIEW_MATRIX[3].xyz;
	float cam_alt = length(cam_world - planet_center) - planet_radius;
	float alt_fade = exp(-max(cam_alt, 0.0) * haze_alt_falloff);
	float vdist = length(VERTEX);
	float haze = (1.0 - exp(-vdist * haze_density)) * haze_strength * alt_fade;
	vec3 frag_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 view_dir = normalize(frag_world - cam_world);
	float sun_align = clamp(dot(view_dir, -sun_direction), 0.0, 1.0);
	vec3 hcol = mix(haze_color, haze_sun_color, sun_align * sun_align);
	ALBEDO = mix(ALBEDO, hcol, clamp(haze, 0.0, 1.0));
}
