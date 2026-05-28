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
	@warning_ignore("integer_division")
	var tri_count : int = indices.size() / 3
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


## Larger, taller cliff-outcrop mesh — different shape from the small boulder
## so the same MultiMesh can stand in for both at different scales. Shares the
## rock material. Single MultiMesh would need a single mesh — for now we use
## the same boulder mesh, but stretched vertically by the scatter pass so it
## reads as a buttress when scaled up. If you want truly distinct cliff
## geometry, add a second MultiMeshInstance3D in voxel_chunk.gd.
static func make_cliff_outcrop_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Taller, more angular than the boulder — reads as a buttress when scaled up.
	var v := [
		Vector3( 0.0,  1.8,  0.0),    # top spire
		Vector3( 0.9,  0.6,  0.3),
		Vector3( 0.4,  0.6,  0.9),
		Vector3(-0.7,  0.6,  0.5),
		Vector3(-0.8,  0.6, -0.5),
		Vector3( 0.5,  0.6, -0.8),
		Vector3( 0.6, -0.4,  0.0),
		Vector3(-0.4, -0.4,  0.6),
		Vector3(-0.5, -0.4, -0.5),
	]
	# Asymmetric scale for natural look.
	for i in v.size():
		v[i] = v[i] * Vector3(1.0, 1.1, 1.0)
	var faces := [
		[0,1,2], [0,2,3], [0,3,4], [0,4,5], [0,5,1],
		[6,2,1], [7,3,2], [8,4,3], [8,5,4], [6,1,5],
		[6,7,2], [7,8,3], [8,6,5],
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
