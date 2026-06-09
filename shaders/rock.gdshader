// Rock instance shader — used by the MultiMeshInstance3D rock scatter on the
// planet surface. Triplanar fbm gives the stone its banded/cracked surface
// pattern (so each instance reads as natural rock rather than a flat-coloured
// blob). The base of the rock fades toward the local biome colour so it
// looks bedded INTO the terrain rather than floating on top; the top gets a
// snow cap when the rock's world position is in a cold biome AND above a
// threshold altitude.
//
// Per-instance world position is derived from MODEL_MATRIX (MultiMesh writes
// each instance's transform there). All biome math runs in PLANET-LOCAL
// space (world position minus planet centre, rotated into the planet's
// local frame) so it stays stable as the planet spins/orbits.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3  planet_center        = vec3(0.0);
uniform float planet_radius        : hint_range(100.0, 100000.0) = 24000.0;
uniform vec3  polar_axis           = vec3(0.0, 1.0, 0.0);
uniform mat3  planet_basis_inv     = mat3(1.0);

uniform vec3 color_rock_base    : source_color = vec3(0.32, 0.30, 0.28);
uniform vec3 color_rock_dark    : source_color = vec3(0.16, 0.15, 0.14);
uniform vec3 color_rock_light   : source_color = vec3(0.56, 0.52, 0.46);
uniform vec3 color_snow         : source_color = vec3(0.94, 0.95, 0.98);
uniform vec3 color_biome_grass  : source_color = vec3(0.26, 0.40, 0.16);
uniform vec3 color_biome_sand   : source_color = vec3(0.80, 0.70, 0.44);
uniform vec3 color_biome_tundra : source_color = vec3(0.50, 0.50, 0.44);
uniform vec3 color_biome_dirt   : source_color = vec3(0.40, 0.30, 0.18);

uniform float rock_texture_scale : hint_range(0.01, 1.0)   = 0.35;
uniform float rock_base_height   : hint_range(0.0, 1.0)    = 0.25;   // fraction of local-Y below which biome blend dominates
uniform float snow_altitude      : hint_range(0.0, 2000.0) = 600.0;
uniform float snow_fade          : hint_range(10.0, 400.0) = 180.0;
uniform float polar_cap_latitude : hint_range(0.0, 1.0)    = 0.62;
uniform float beach_altitude     : hint_range(-200.0, 300.0) = 8.0;
uniform float beach_fade         : hint_range(1.0, 80.0)   = 14.0;

uniform float roughness_base : hint_range(0.0, 1.0) = 0.90;
uniform float specular_base  : hint_range(0.0, 1.0) = 0.04;

varying vec3 v_world_pos;     // world-space fragment position
varying vec3 v_world_normal;  // world-space surface normal (Godot's NORMAL builtin arrives in VIEW space, useless for triplanar)
varying vec3 v_object_pos;    // local-to-instance position (centre-out, height direction = +Y)


float hash1(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash1(i + vec3(0,0,0));
	float n100 = hash1(i + vec3(1,0,0));
	float n010 = hash1(i + vec3(0,1,0));
	float n110 = hash1(i + vec3(1,1,0));
	float n001 = hash1(i + vec3(0,0,1));
	float n101 = hash1(i + vec3(1,0,1));
	float n011 = hash1(i + vec3(0,1,1));
	float n111 = hash1(i + vec3(1,1,1));
	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
		f.z);
}

float fbm3(vec3 p, int octaves) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) break;
		v += vnoise(p) * a;
		p = p * 2.07 + vec3(11.0, 31.0, 17.0);
		a *= 0.5;
	}
	return v;
}

// Triplanar fbm — sample three orthogonal projections and blend by normal so
// the texture doesn't stretch on any axis.
float triplanar_fbm(vec3 wp, vec3 wn, float scale, int octaves) {
	vec3 ax = abs(wn);
	float wsum = max(ax.x + ax.y + ax.z, 1e-4);
	vec3 b = ax / wsum;
	float nx = fbm3(wp.yzx * scale, octaves);
	float ny = fbm3(wp.zxy * scale + 11.0, octaves);
	float nz = fbm3(wp.xyz * scale + 23.0, octaves);
	return nx * b.x + ny * b.y + nz * b.z;
}


void vertex() {
	v_object_pos = VERTEX;
	v_world_pos  = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// MODEL_NORMAL_MATRIX is the inverse-transpose of the model's 3×3 part —
	// the correct transform for normals under non-uniform scale (rocks can be
	// stretched on +Y by the cliff-outcrop pass). Output is in world space.
	v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}


void fragment() {
	vec3 wn = normalize(v_world_normal);
	// Planet-LOCAL coords for biome calculations — rotation-invariant under spin.
	vec3 rel_local = planet_basis_inv * (v_world_pos - planet_center);
	// Planet-local normal too, so the triplanar texture below is sampled in the SAME
	// frame as rel_local. Sampling it in WORLD space (the old bug) made the stone
	// banding swim across every rock as the planet spun.
	vec3 wn_local = normalize(planet_basis_inv * wn);
	float r = length(rel_local);
	vec3 radial = (r > 1e-6) ? rel_local / r : vec3(0.0, 1.0, 0.0);
	float altitude = r - planet_radius;
	float lat = abs(dot(radial, normalize(polar_axis)));   // 0 = equator, 1 = pole

	// 1) Rock surface texture — banded dark/light driven by triplanar fbm, sampled in
	//    planet-LOCAL space so it stays locked to the rock as the planet spins.
	float rband = triplanar_fbm(rel_local, wn_local, rock_texture_scale, 4);
	rband = smoothstep(0.30, 0.70, rband);
	vec3 rock_col = mix(color_rock_dark, color_rock_light, rband);
	rock_col = mix(color_rock_base, rock_col, 0.65);

	// 2) Biome at this world position — chosen as the colour the rock should
	// blend INTO at its base. Cheap version of terrain.gdshader's logic:
	//   - cold latitudes → tundra
	//   - beach altitudes → sand
	//   - otherwise → grass/dirt by humidity-proxy noise
	float polar_t = smoothstep(polar_cap_latitude - 0.10, polar_cap_latitude + 0.10, lat);
	float beach_t = 1.0 - smoothstep(beach_altitude, beach_altitude + beach_fade, altitude);
	beach_t = clamp(beach_t, 0.0, 1.0) * (1.0 - polar_t);
	float humid = fbm3(rel_local * 0.0035, 4);
	vec3 lowland_biome = mix(color_biome_dirt, color_biome_grass, smoothstep(0.30, 0.65, humid));
	vec3 biome_col = mix(lowland_biome, color_biome_tundra, polar_t);
	biome_col = mix(biome_col, color_biome_sand, beach_t * 0.9);

	// 3) Base blend: along the rock's LOCAL +Y axis from -Y (bottom) to +Y (top).
	// Bottom → biome col (rock looks bedded into the ground), top → pure rock.
	// Add some noise to break the horizontal seam so the blend reads as
	// soil/moss creeping up, not a perfect line.
	float ny = clamp((v_object_pos.y + 1.0) * 0.5, 0.0, 1.0);   // assume mesh roughly in [-1, +1]
	float blend_noise = fbm3(rel_local * 0.6, 3) * 0.25;   // planet-local, locked to the rock
	float base_t = smoothstep(0.0, rock_base_height, ny + blend_noise);
	vec3 col = mix(biome_col, rock_col, base_t);

	// 4) Snow cap: cold latitude OR high altitude, applied to the upper
	// half of the rock and the gentler surfaces (less snow on near-vertical
	// faces — it slides off). Latitude provides "cold" since real
	// temperature would need decorrelated noise we don't have here.
	float cold = max(polar_t, smoothstep(snow_altitude, snow_altitude + snow_fade, altitude));
	// `up_in_world`: how vertical the rock's local +Y maps to the planet
	// radial. Used to weight snow to the rock's upper faces in world space.
	vec3 up_world = (MODEL_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	float face_up = clamp(dot(normalize(up_world), wn), 0.0, 1.0);
	float snow_t = cold * smoothstep(0.45, 0.95, ny) * smoothstep(0.20, 0.75, face_up);
	// Snow follows the rock texture's high spots — cracks stay dark.
	snow_t *= mix(0.6, 1.0, rband);
	col = mix(col, color_snow, clamp(snow_t, 0.0, 1.0));

	ALBEDO = col;
	ROUGHNESS = roughness_base;
	SPECULAR  = specular_base;
}
