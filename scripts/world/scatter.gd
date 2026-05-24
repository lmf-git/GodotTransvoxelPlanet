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

const ROCK_MIN_SLOPE  : float = 0.45    # 0 = cliff, 1 = flat — only on shallow-ish
const ROCK_MAX_SLOPE  : float = 0.93
const ROCK_PROBABILITY: float = 0.18    # per qualifying triangle
const ROCK_MIN_SCALE  : float = 0.6
const ROCK_MAX_SCALE  : float = 1.7
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
	# Reserve a generous capacity to avoid amortised copies.
	out.resize(tri_count * 12)   # upper bound; we'll truncate at the end
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
		if slope < ROCK_MIN_SLOPE or slope > ROCK_MAX_SLOPE:
			continue

		if rng.randf() > ROCK_PROBABILITY:
			continue

		# Build the transform: Y aligned with terrain normal (so the rock
		# "sits" on the slope), random yaw, random scale, slight sink into
		# the surface so it doesn't float over the iso-vertex.
		var up := n
		var yaw := rng.randf_range(0.0, TAU)
		var seed_axis := Vector3(0.0, 0.0, 1.0)
		if absf(up.dot(seed_axis)) > 0.95:
			seed_axis = Vector3(1.0, 0.0, 0.0)
		var tangent := seed_axis.cross(up).normalized()
		var bitan   := up.cross(tangent)
		# Rotate tangent / bitangent by yaw around up.
		var c := cos(yaw)
		var s := sin(yaw)
		var x_axis := tangent * c + bitan * s
		var z_axis := -tangent * s + bitan * c
		var scale := rng.randf_range(ROCK_MIN_SCALE, ROCK_MAX_SCALE)
		var origin := centroid - radial * (scale * 0.25)

		# Pack as 12 floats (column-major Basis + origin, matching MultiMesh's
		# transform_array layout).
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
		write += 12

	out.resize(write)
	return out


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


## Shared StandardMaterial3D for rocks.
static func make_rock_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.38, 0.36, 0.32)
	m.roughness = 0.88
	m.metallic = 0.0
	m.vertex_color_use_as_albedo = false
	return m
