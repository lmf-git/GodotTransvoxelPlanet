class_name TerrainScatter
extends RefCounted

## Deterministic prop scatter from a chunk's MC mesh.
##
## Iterates the triangle list, evaluates each triangle's centroid + slope +
## altitude, and chooses where to place rocks (and optionally other props).
## Determinism comes from hashing (chunk_coord + tri_index) — the same chunk
## always produces the same scatter regardless of when it's meshed.
##
## Output is a `PackedFloat32Array` of 12 floats per instance (3 basis vectors
## + origin), which the caller can drop straight into
## `MultiMesh.transform_array` (PRIMITIVE_3D / TRANSFORM_3D).

# Two scatter passes are emitted from the same triangle walk:
#   1. Small boulders on shallow ground (slope 0.45..0.93).
#   2. Large cliff outcrops on STEEP slopes (slope 0.0..0.45) — these are the
#      "stamped" rocks the player sees on cliff faces. They're rarer per
#      triangle but visually dominant.
# Both share a single output stream; the caller's MultiMesh draws one mesh
# (the rock mesh has elongated proportions so the same shape reads as a
# boulder at small scale and as a cliff buttress at large scale).
const ROCK_MIN_SLOPE  : float = 0.45    # 0 = cliff, 1 = flat — small-rock band
const ROCK_MAX_SLOPE  : float = 0.93
const ROCK_PROBABILITY: float = 0.18
const ROCK_MIN_SCALE  : float = 0.6
const ROCK_MAX_SCALE  : float = 1.7

const CLIFF_MIN_SLOPE  : float = 0.00   # steep-cliff band
const CLIFF_MAX_SLOPE  : float = 0.42
const CLIFF_PROBABILITY: float = 0.06   # rarer per-triangle but each instance is much larger
const CLIFF_MIN_SCALE  : float = 2.6
const CLIFF_MAX_SCALE  : float = 6.5
const MIN_ALTITUDE_OFFSET : float = 4.0   # don't scatter on the very edge of the sea


## Returns a PackedFloat32Array of 12 floats per rock instance.
## `coords_seed` should be a stable per-chunk seed (e.g. hash of chunk coords).
static func build_rock_transforms(
		positions: PackedVector3Array,
		normals: PackedVector3Array,
		indices: PackedInt32Array,
		planet_center: Vector3,
		planet_radius: float,
		sea_level_offset: float,
		coords_seed: int) -> PackedFloat32Array:

	var out := PackedFloat32Array()
	if indices.size() < 3 or positions.size() == 0:
		return out

	var rng := RandomNumberGenerator.new()
	var min_radius := planet_radius + sea_level_offset + MIN_ALTITUDE_OFFSET
	# The index list is a triangle soup, so its length is always a multiple of 3;
	# float-divide then truncate gives the exact triangle count without GDScript's
	# int/int "decimal part discarded" warning.
	var tri_count : int = int(indices.size() / 3.0)
	# Reserve generously; both passes share the buffer.
	out.resize(tri_count * 12 * 2)
	var write := 0

	for ti in tri_count:
		# Per-triangle deterministic RNG.
		rng.seed = coords_seed ^ (ti * 0x9E3779B1)

		var i0 := indices[ti * 3]
		var i1 := indices[ti * 3 + 1]
		var i2 := indices[ti * 3 + 2]
		var v0 := positions[i0]
		var v1 := positions[i1]
		var v2 := positions[i2]
		var centroid := (v0 + v1 + v2) / 3.0

		# Above sea level?
		var r := centroid.distance_to(planet_center)
		if r < min_radius:
			continue

		# Slope: 1 = flat (normal aligned with radial), 0 = cliff.
		var n := ((normals[i0] + normals[i1] + normals[i2]) / 3.0).normalized()
		var radial := (centroid - planet_center).normalized()
		var slope := absf(n.dot(radial))

		# ── Pass 1: small boulders on shallow ground ──────────────────────
		if slope >= ROCK_MIN_SLOPE and slope <= ROCK_MAX_SLOPE \
				and rng.randf() <= ROCK_PROBABILITY:
			var scale := rng.randf_range(ROCK_MIN_SCALE, ROCK_MAX_SCALE)
			# Local-up = surface normal (rock sits on the ground).
			write = _pack_instance(out, write, centroid, n, radial, rng.randf_range(0.0, TAU), scale, scale * 0.25)

		# ── Pass 2: BIG cliff outcrops on steep slopes ────────────────────
		# The user's "stamped" rocks: rare per triangle but each instance is
		# much larger and dominates the local silhouette. Up-vector here is
		# the RADIAL (planet up), not the surface normal — a cliff-face rock
		# stands vertically even though it's emitted from a near-vertical
		# triangle. The rock material's biome blend grades from terrain to
		# stone going up the local-Y, which only looks right if the rock's
		# vertical IS the world vertical.
		if slope >= CLIFF_MIN_SLOPE and slope <= CLIFF_MAX_SLOPE \
				and rng.randf() <= CLIFF_PROBABILITY:
			var cliff_scale := rng.randf_range(CLIFF_MIN_SCALE, CLIFF_MAX_SCALE)
			# Sink the base into the cliff face by ~30 % of the scale so the
			# outcrop reads as wedged into the rock, not standing on top.
			write = _pack_instance(out, write, centroid, radial, radial, rng.randf_range(0.0, TAU), cliff_scale, cliff_scale * 0.3)

	out.resize(write)
	return out


# Pack a single instance transform (12 floats: column-major Basis + origin).
# `up`: local-Y direction; `radial`: world up (used for sinking the origin
# into the surface along the planet radial regardless of the up choice).
static func _pack_instance(
		out: PackedFloat32Array, write: int,
		centroid: Vector3, up: Vector3, radial: Vector3,
		yaw: float, scale: float, sink: float) -> int:
	var seed_axis := Vector3(0.0, 0.0, 1.0)
	if absf(up.dot(seed_axis)) > 0.95:
		seed_axis = Vector3(1.0, 0.0, 0.0)
	var tangent := seed_axis.cross(up).normalized()
	var bitan   := up.cross(tangent)
	var c := cos(yaw)
	var s := sin(yaw)
	var x_axis := tangent * c + bitan * s
	var z_axis := -tangent * s + bitan * c
	var origin := centroid - radial * sink
	var b := write
	out[b +  0] = x_axis.x * scale
	out[b +  1] = up.x     * scale
	out[b +  2] = z_axis.x * scale
	out[b +  3] = origin.x
	out[b +  4] = x_axis.y * scale
	out[b +  5] = up.y     * scale
	out[b +  6] = z_axis.y * scale
	out[b +  7] = origin.y
	out[b +  8] = x_axis.z * scale
	out[b +  9] = up.z     * scale
	out[b + 10] = z_axis.z * scale
	out[b + 11] = origin.z
	return write + 12


# ── Biome-driven foliage scatter ────────────────────────────────────────────
# A second scatter pass with SEVERAL plant types chosen by the local biome, so
# the cover matches the terrain: conifers in cold forests, broadleaf trees in
# temperate woods, palms in hot-wet jungle, cacti in hot-dry desert, grass tufts
# on grassland, dead scrub in tundra/badlands. Each type is its own MultiMesh
# (one mesh per stream); a chunk only allocates the streams its biomes actually
# use. Biome is derived the same way the terrain shader does it — latitude + an
# altitude lapse + a humidity/temperature macro field — so plants land on the
# colour they belong to. (The macro noise here is GDScript FastNoiseLite, not the
# GLSL field, so the wet/dry patches won't match pixel-for-pixel, but the
# latitude/altitude structure — the dominant driver — does.)
const FOLIAGE_MIN_SLOPE   : float = 0.74    # 1 = flat; only fairly level ground
const FOLIAGE_PROBABILITY : float = 0.55    # dense — this is the ground cover
const FOLIAGE_MIN_ALT     : float = 5.0     # above the sandy shoreline
const FOLIAGE_MAX_ALT     : float = 560.0   # below the alpine/snow zone

# Plant types — one MultiMesh stream each. Order is the index into the arrays
# returned by build_foliage_streams() / make_foliage_meshes().
const FT_CONIFER   : int = 0   # cold-wet boreal pine
const FT_BROADLEAF : int = 1   # temperate-wet deciduous
const FT_PALM      : int = 2   # hot-wet tropical
const FT_CACTUS    : int = 3   # hot-dry desert
const FT_GRASS     : int = 4   # grassland / savanna tuft
const FT_DEADBUSH  : int = 5   # tundra / badlands dry scrub
const FOLIAGE_TYPE_COUNT : int = 6

# Lapse model — must mirror the terrain shader so plant biomes track the colours.
const FOLIAGE_LAPSE_RATE  : float = 0.6
const FOLIAGE_LAPSE_FULL  : float = 1500.0

static var _humidity_noise : FastNoiseLite
static var _temp_noise     : FastNoiseLite

static func _ensure_climate_noise() -> void:
	if _humidity_noise != null:
		return
	_humidity_noise = FastNoiseLite.new()
	_humidity_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_humidity_noise.frequency = 0.0009   # continental-scale wet/dry patches
	_humidity_noise.seed = 9701
	_temp_noise = FastNoiseLite.new()
	_temp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_temp_noise.frequency = 0.0006       # broader temperature anomalies
	_temp_noise.seed = 4451


## Returns an Array of FOLIAGE_TYPE_COUNT PackedFloat32Arrays, one per plant
## type, each holding 12 floats per instance (MultiMesh TRANSFORM_3D layout).
static func build_foliage_streams(
		positions: PackedVector3Array,
		normals: PackedVector3Array,
		indices: PackedInt32Array,
		planet_center: Vector3,
		planet_radius: float,
		sea_level_offset: float,
		coords_seed: int) -> Array:

	_ensure_climate_noise()
	# IMPORTANT: each type's buffer must be a LOCAL variable mutated in place.
	# Reading a PackedFloat32Array back out of an Array yields a COPY (value
	# semantics), so resizing / writing through `streams[t]` is silently lost —
	# which left the buffers at size 0 and made _pack_instance write out of bounds.
	# Six named locals, dispatched by a match, keep the in-place mutation (the same
	# pattern build_rock_transforms relies on for its single `out` buffer).
	if indices.size() < 3 or positions.size() == 0:
		var empties : Array = []
		for _e in FOLIAGE_TYPE_COUNT:
			empties.append(PackedFloat32Array())
		return empties

	# Index list is a triangle soup → length is a multiple of 3; exact float divide.
	var tri_count : int = int(indices.size() / 3.0)
	var cap := tri_count * 12
	var b_con := PackedFloat32Array(); b_con.resize(cap); var w_con := 0
	var b_bro := PackedFloat32Array(); b_bro.resize(cap); var w_bro := 0
	var b_pal := PackedFloat32Array(); b_pal.resize(cap); var w_pal := 0
	var b_cac := PackedFloat32Array(); b_cac.resize(cap); var w_cac := 0
	var b_gra := PackedFloat32Array(); b_gra.resize(cap); var w_gra := 0
	var b_dea := PackedFloat32Array(); b_dea.resize(cap); var w_dea := 0

	var rng := RandomNumberGenerator.new()
	var min_radius := planet_radius + sea_level_offset + FOLIAGE_MIN_ALT
	var max_radius := planet_radius + sea_level_offset + FOLIAGE_MAX_ALT
	var beach_alt := sea_level_offset + 6.0
	var pole := Vector3.UP   # planet's spin axis in object space (matches terrain shader)

	for ti in tri_count:
		rng.seed = coords_seed ^ (ti * 0x9E3779B1)
		var i0 := indices[ti * 3]
		var i1 := indices[ti * 3 + 1]
		var i2 := indices[ti * 3 + 2]
		var centroid := (positions[i0] + positions[i1] + positions[i2]) / 3.0

		var r := centroid.distance_to(planet_center)
		if r < min_radius or r > max_radius:
			continue
		var n := ((normals[i0] + normals[i1] + normals[i2]) / 3.0).normalized()
		var radial := (centroid - planet_center).normalized()
		var slope := absf(n.dot(radial))
		if slope < FOLIAGE_MIN_SLOPE:
			continue
		if rng.randf() > FOLIAGE_PROBABILITY:
			continue

		# Climate, mirroring the terrain shader: temperature falls with latitude
		# AND altitude (lapse); humidity from a macro noise.
		var lat := absf(radial.dot(pole))
		var lapse : float = clampf((r - planet_radius - beach_alt) / FOLIAGE_LAPSE_FULL, 0.0, 1.0) * FOLIAGE_LAPSE_RATE
		var temp_anom := _temp_noise.get_noise_3dv(centroid) * 0.28
		var temperature := clampf(1.0 - lat + temp_anom - lapse, 0.0, 1.0)
		var humidity := clampf(0.5 + _humidity_noise.get_noise_3dv(centroid) * 0.95, 0.0, 1.0)

		var ft := _foliage_type_for(temperature, humidity, rng)
		var scale := _foliage_scale_for(ft, rng)
		var yaw := rng.randf_range(0.0, TAU)
		var sink := scale * 0.08
		match ft:
			FT_CONIFER:   w_con = _pack_instance(b_con, w_con, centroid, radial, radial, yaw, scale, sink)
			FT_BROADLEAF: w_bro = _pack_instance(b_bro, w_bro, centroid, radial, radial, yaw, scale, sink)
			FT_PALM:      w_pal = _pack_instance(b_pal, w_pal, centroid, radial, radial, yaw, scale, sink)
			FT_CACTUS:    w_cac = _pack_instance(b_cac, w_cac, centroid, radial, radial, yaw, scale, sink)
			FT_GRASS:     w_gra = _pack_instance(b_gra, w_gra, centroid, radial, radial, yaw, scale, sink)
			FT_DEADBUSH:  w_dea = _pack_instance(b_dea, w_dea, centroid, radial, radial, yaw, scale, sink)

	b_con.resize(w_con)
	b_bro.resize(w_bro)
	b_pal.resize(w_pal)
	b_cac.resize(w_cac)
	b_gra.resize(w_gra)
	b_dea.resize(w_dea)
	# Returned in FT_* index order.
	return [b_con, b_bro, b_pal, b_cac, b_gra, b_dea]


# Pick a plant type from the local climate (a 2D temperature × humidity grid).
static func _foliage_type_for(temperature: float, humidity: float, rng: RandomNumberGenerator) -> int:
	if temperature < 0.33:
		# Cold: boreal conifers where wet, sparse dry scrub / grass where not.
		if humidity > 0.42:
			return FT_CONIFER
		return FT_DEADBUSH if rng.randf() < 0.5 else FT_GRASS
	elif temperature > 0.66:
		# Hot: tropical palms where wet, cacti (+ some scrub) in the desert.
		if humidity > 0.5:
			return FT_PALM
		return FT_CACTUS if rng.randf() < 0.7 else FT_DEADBUSH
	# Temperate: deciduous woodland where wet, grassland where dry.
	if humidity > 0.55:
		return FT_BROADLEAF
	return FT_GRASS


static func _foliage_scale_for(ft: int, rng: RandomNumberGenerator) -> float:
	match ft:
		FT_GRASS:
			return rng.randf_range(0.5, 1.1)
		FT_DEADBUSH:
			return rng.randf_range(0.5, 1.0)
		FT_CACTUS:
			return rng.randf_range(0.7, 1.6)
		_:
			# Trees — bias small with the occasional tall one (squared random).
			var u := rng.randf()
			return lerp(0.9, 2.6, u * u)


## Build all plant meshes in FT_* index order. Shared across every chunk.
static func make_foliage_meshes() -> Array:
	var meshes : Array = []
	meshes.resize(FOLIAGE_TYPE_COUNT)
	meshes[FT_CONIFER]   = _make_conifer_mesh()
	meshes[FT_BROADLEAF] = _make_broadleaf_mesh()
	meshes[FT_PALM]      = _make_palm_mesh()
	meshes[FT_CACTUS]    = _make_cactus_mesh()
	meshes[FT_GRASS]     = _make_grass_mesh()
	meshes[FT_DEADBUSH]  = _make_deadbush_mesh()
	return meshes


# Conifer: thin trunk + two stacked green cones (pine).
static func _make_conifer_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_trunk(st, 0.08, 0.5, Color(0.30, 0.21, 0.12))
	_add_cone(st, 0.40, 1.30, 0.60, 7, Color(0.10, 0.30, 0.12), Color(0.18, 0.42, 0.16))
	_add_cone(st, 0.95, 1.95, 0.40, 7, Color(0.14, 0.36, 0.14), Color(0.20, 0.46, 0.18))
	st.index()
	return st.commit()


# Broadleaf: short trunk + a rounded green canopy blob.
static func _make_broadleaf_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_trunk(st, 0.10, 0.7, Color(0.36, 0.25, 0.15))
	_add_blob(st, Vector3(0.0, 1.25, 0.0), 0.62, 0.55,
			Color(0.20, 0.44, 0.16), Color(0.28, 0.52, 0.22))
	st.index()
	return st.commit()


# Palm: tall thin trunk + a fan of fronds splaying from the top.
static func _make_palm_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_trunk(st, 0.07, 1.7, Color(0.40, 0.30, 0.16))
	var top := Vector3(0.0, 1.7, 0.0)
	var frond_col := Color(0.18, 0.46, 0.18)
	var tip_col := Color(0.30, 0.56, 0.22)
	for s in 6:
		var ang := TAU * float(s) / 6.0
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var tip := top + dir * 0.85 + Vector3(0.0, -0.35, 0.0)
		var side := dir.cross(Vector3.UP).normalized() * 0.12
		var nn := (tip - (top + side)).cross((top - side) - (top + side)).normalized()
		st.set_color(tip_col);   st.set_normal(nn); st.add_vertex(tip)
		st.set_color(frond_col); st.set_normal(nn); st.add_vertex(top + side)
		st.set_color(frond_col); st.set_normal(nn); st.add_vertex(top - side)
	st.index()
	return st.commit()


# Cactus: a green column with two short arms.
static func _make_cactus_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var col := Color(0.20, 0.42, 0.22)
	_add_box(st, Vector3(0.0, 0.55, 0.0), Vector3(0.14, 0.55, 0.14), col)
	_add_box(st, Vector3(0.22, 0.7, 0.0), Vector3(0.08, 0.22, 0.08), col)   # right arm
	_add_box(st, Vector3(-0.20, 0.6, 0.05), Vector3(0.07, 0.18, 0.07), col) # left arm
	st.index()
	return st.commit()


# Grass: three crossed blade quads (no trunk), short.
static func _make_grass_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lo := Color(0.34, 0.42, 0.16)
	var hi := Color(0.50, 0.58, 0.26)
	for s in 3:
		var ang := PI * float(s) / 3.0
		var dir := Vector3(cos(ang), 0.0, sin(ang)) * 0.16
		var h := 0.42
		var a := -dir
		var b := dir
		var c := dir * 0.2 + Vector3(0.0, h, 0.0)
		var d := -dir * 0.2 + Vector3(0.0, h, 0.0)
		var nn := Vector3(0.0, 0.0, 1.0)
		st.set_color(lo); st.set_normal(nn); st.add_vertex(a)
		st.set_color(lo); st.set_normal(nn); st.add_vertex(b)
		st.set_color(hi); st.set_normal(nn); st.add_vertex(c)
		st.set_color(lo); st.set_normal(nn); st.add_vertex(a)
		st.set_color(hi); st.set_normal(nn); st.add_vertex(c)
		st.set_color(hi); st.set_normal(nn); st.add_vertex(d)
	st.index()
	return st.commit()


# Dead bush: a low brown spiky blob.
static func _make_deadbush_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_blob(st, Vector3(0.0, 0.28, 0.0), 0.34, 0.28,
			Color(0.40, 0.31, 0.18), Color(0.52, 0.42, 0.26))
	st.index()
	return st.commit()


# ── small mesh helpers ──────────────────────────────────────────────────────

# A thin square trunk from y=0 to y=height.
static func _add_trunk(st: SurfaceTool, half: float, height: float, col: Color) -> void:
	_add_box(st, Vector3(0.0, height * 0.5, 0.0), Vector3(half, height * 0.5, half), col)


# An axis-aligned box centred at `c` with half-extents `h`.
static func _add_box(st: SurfaceTool, c: Vector3, h: Vector3, col: Color) -> void:
	var p := [
		c + Vector3(-h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, -h.z),
		c + Vector3(h.x, -h.y, h.z),   c + Vector3(-h.x, -h.y, h.z),
		c + Vector3(-h.x, h.y, -h.z),  c + Vector3(h.x, h.y, -h.z),
		c + Vector3(h.x, h.y, h.z),    c + Vector3(-h.x, h.y, h.z),
	]
	var faces := [
		[0,1,5],[0,5,4], [1,2,6],[1,6,5], [2,3,7],[2,7,6],
		[3,0,4],[3,4,7], [4,5,6],[4,6,7], [3,2,1],[3,1,0],
	]
	for f in faces:
		var a : Vector3 = p[f[0]]
		var b : Vector3 = p[f[1]]
		var d : Vector3 = p[f[2]]
		var nn := (b - a).cross(d - a).normalized()
		st.set_color(col); st.set_normal(nn); st.add_vertex(a)
		st.set_color(col); st.set_normal(nn); st.add_vertex(b)
		st.set_color(col); st.set_normal(nn); st.add_vertex(d)


# A rounded blob (octahedron) centred at `c`, radius `rxz` horizontally and `ry`
# vertically, colour graded top→bottom.
static func _add_blob(st: SurfaceTool, c: Vector3, rxz: float, ry: float,
		col_lo: Color, col_hi: Color) -> void:
	var top := c + Vector3(0.0, ry, 0.0)
	var bot := c + Vector3(0.0, -ry, 0.0)
	var ring := [
		c + Vector3(rxz, 0.0, 0.0), c + Vector3(0.0, 0.0, rxz),
		c + Vector3(-rxz, 0.0, 0.0), c + Vector3(0.0, 0.0, -rxz),
	]
	for k in 4:
		var a : Vector3 = ring[k]
		var b : Vector3 = ring[(k + 1) % 4]
		var nt := (b - top).cross(a - top).normalized()
		st.set_color(col_hi); st.set_normal(nt); st.add_vertex(top)
		st.set_color(col_lo); st.set_normal(nt); st.add_vertex(b)
		st.set_color(col_lo); st.set_normal(nt); st.add_vertex(a)
		var nb := (a - bot).cross(b - bot).normalized()
		st.set_color(col_lo); st.set_normal(nb); st.add_vertex(bot)
		st.set_color(col_lo); st.set_normal(nb); st.add_vertex(a)
		st.set_color(col_lo); st.set_normal(nb); st.add_vertex(b)


# Append a cone (fan of side triangles, apex up) to the SurfaceTool.
static func _add_cone(st: SurfaceTool, base_y: float, apex_y: float,
		radius: float, segments: int, col_base: Color, col_apex: Color) -> void:
	var apex := Vector3(0.0, apex_y, 0.0)
	for s in segments:
		var a0 := TAU * float(s) / float(segments)
		var a1 := TAU * float(s + 1) / float(segments)
		var p0 := Vector3(cos(a0) * radius, base_y, sin(a0) * radius)
		var p1 := Vector3(cos(a1) * radius, base_y, sin(a1) * radius)
		var nn := (p1 - apex).cross(p0 - apex).normalized()
		st.set_color(col_apex); st.set_normal(nn); st.add_vertex(apex)
		st.set_color(col_base); st.set_normal(nn); st.add_vertex(p1)
		st.set_color(col_base); st.set_normal(nn); st.add_vertex(p0)


## Shared material for foliage — vertex-colored, double-sided (the cones/blades
## are open shells), slightly rough matte leaves.
static func make_foliage_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.9
	m.metallic = 0.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Build the shared rock mesh — a low-poly polyhedron, vertex-colored. The
## same mesh is shared across all chunks via `MultiMesh.mesh`.
static func make_rock_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# 8 vertices arranged as a squashed octahedron-ish blob.
	var v := [
		Vector3( 0.0,  1.0,  0.0),    # top
		Vector3( 1.0,  0.1,  0.0),
		Vector3( 0.0,  0.1,  1.0),
		Vector3(-1.0,  0.1,  0.2),
		Vector3(-0.2,  0.1, -1.0),
		Vector3( 0.7,  0.1, -0.7),
		Vector3( 0.0, -0.6,  0.0),    # bottom
	]
	# Slight asymmetry for "rock-ness".
	for i in v.size():
		v[i] = v[i] * Vector3(1.0, 0.85, 1.05)
	# Triangles for top fan + side ring + bottom fan.
	var faces := [
		[0,1,2], [0,2,3], [0,3,4], [0,4,5], [0,5,1],
		[6,2,1], [6,3,2], [6,4,3], [6,5,4], [6,1,5],
	]
	for f in faces:
		var a : Vector3 = v[f[0]]
		var b : Vector3 = v[f[1]]
		var c : Vector3 = v[f[2]]
		var n := (b - a).cross(c - a).normalized()
		st.set_normal(n); st.add_vertex(a)
		st.set_normal(n); st.add_vertex(b)
		st.set_normal(n); st.add_vertex(c)
	st.index()
	return st.commit()


## Shared ShaderMaterial for rocks — triplanar rock texture, biome blend at
## the base, snow cap at altitude/cold. The caller must update its per-frame
## uniforms (`planet_center`, `planet_basis_inv`) so biome math stays in the
## planet's local frame as it orbits/spins; `polar_axis`, `planet_radius` are
## set once after construction.
static func make_rock_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/rock.gdshader")
	return m
