class_name TerrainScatter
extends RefCounted

## Shared prop meshes + materials for the chunk scatter (rocks + biome foliage).
##
## The per-instance scatter TRANSFORMS are computed on the Rust worker pool
## (rust/src/scatter.rs), off the main thread — this script no longer walks
## triangles. It now owns only the GPU side: the shared low-poly meshes each
## MultiMesh draws and their materials.
##
## The FT_* indices below are the contract between the Rust foliage classifier
## (one transform buffer per type) and make_foliage_meshes() (one mesh per type)
## — they MUST stay in the same order.

# Plant types — one MultiMesh stream each. Order = index into the per-type buffers
# the Rust scatter pass emits and the meshes make_foliage_meshes() builds.
const FT_CONIFER   : int = 0   # cold-wet boreal pine
const FT_BROADLEAF : int = 1   # temperate-wet deciduous
const FT_PALM      : int = 2   # hot-wet tropical
const FT_CACTUS    : int = 3   # hot-dry desert
const FT_GRASS     : int = 4   # grassland / savanna tuft
const FT_DEADBUSH  : int = 5   # tundra / badlands dry scrub
const FT_FERN      : int = 6   # wet-forest understory (temperate & tropical)
const FT_FLOWER    : int = 7   # meadow flowers — colour accents on lush grassland
const FT_SHRUB     : int = 8   # semi-arid green bush
const FOLIAGE_TYPE_COUNT : int = 9

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
	meshes[FT_FERN]      = _make_fern_mesh()
	meshes[FT_FLOWER]    = _make_flower_mesh()
	meshes[FT_SHRUB]     = _make_shrub_mesh()
	return meshes


# Fern: a low rosette of arching fronds (angled blade quads) radiating from the base.
static func _make_fern_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lo := Color(0.16, 0.34, 0.14)
	var hi := Color(0.26, 0.48, 0.20)
	var fronds := 6
	for s in fronds:
		var ang := TAU * float(s) / float(fronds)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		# Each frond arcs out and up: base at origin, tip out + up.
		var tip := dir * 0.55 + Vector3(0.0, 0.5, 0.0)
		var side := dir.cross(Vector3.UP).normalized() * 0.07
		var nn := (tip - side).cross(tip + side).normalized()
		st.set_color(hi); st.set_normal(nn); st.add_vertex(tip)
		st.set_color(lo); st.set_normal(nn); st.add_vertex(side)
		st.set_color(lo); st.set_normal(nn); st.add_vertex(-side)
	st.index()
	return st.commit()


# Flower: a short green stem topped with a small bright bloom (octahedral blob).
static func _make_flower_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_box(st, Vector3(0.0, 0.22, 0.0), Vector3(0.02, 0.22, 0.02), Color(0.22, 0.40, 0.16))
	# A handful of preset bloom colours; the mesh is shared so pick one deterministic
	# tint here (per-instance colour would need MultiMesh colours — a later pass).
	_add_blob(st, Vector3(0.0, 0.5, 0.0), 0.12, 0.10,
			Color(0.85, 0.78, 0.20), Color(0.95, 0.42, 0.40))
	st.index()
	return st.commit()


# Shrub: a rounded olive-green bush, a touch bigger than the dead bush.
static func _make_shrub_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_blob(st, Vector3(0.0, 0.34, 0.0), 0.42, 0.34,
			Color(0.22, 0.34, 0.16), Color(0.32, 0.44, 0.22))
	st.index()
	return st.commit()


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


## Build the shared rock mesh — a PROCEDURAL angular boulder/outcrop. An icosahedron
## whose 12 vertices are pushed in/out by a deterministic per-vertex factor and
## elongated vertically, FLAT-shaded so it reads as faceted stone with sharp edges
## rather than a smooth blob. One shared mesh; the scatter's per-instance scale + yaw
## make each placement distinct — small = boulder, the big cliff pass (steep slopes)
## scales the same shape up into a mountain/cliff outcrop.
static func make_rock_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var t := (1.0 + sqrt(5.0)) * 0.5   # golden ratio → icosahedron vertices
	var base := [
		Vector3(-1.0,  t,  0.0), Vector3( 1.0,  t,  0.0), Vector3(-1.0, -t,  0.0), Vector3( 1.0, -t,  0.0),
		Vector3( 0.0, -1.0,  t), Vector3( 0.0,  1.0,  t), Vector3( 0.0, -1.0, -t), Vector3( 0.0,  1.0, -t),
		Vector3( t,  0.0, -1.0), Vector3( t,  0.0,  1.0), Vector3(-t,  0.0, -1.0), Vector3(-t,  0.0,  1.0),
	]
	var faces := [
		[0,11,5], [0,5,1], [0,1,7], [0,7,10], [0,10,11],
		[1,5,9], [5,11,4], [11,10,2], [10,7,6], [7,1,8],
		[3,9,4], [3,4,2], [3,2,6], [3,6,8], [3,8,9],
		[4,9,5], [2,4,11], [6,2,10], [8,6,7], [9,8,1],
	]
	# Deterministic per-vertex displacement → an angular, asymmetric rock. Elongated on
	# Y and flattened underneath so it stands like an outcrop and beds into the ground.
	var v : Array[Vector3] = []
	for i in base.size():
		var d : Vector3 = (base[i] as Vector3).normalized()
		var hsh := sin(float(i) * 12.9898 + 4.1) * 43758.5453
		var rj : float = 0.70 + (hsh - floor(hsh)) * 0.62          # 0.70..1.32 radial jitter
		d = Vector3(d.x, d.y * 1.4, d.z) * rj
		if d.y < 0.0:
			d.y *= 0.5                                             # flat-ish base
		v.append(d)
	for f in faces:
		var a : Vector3 = v[f[0]]
		var b : Vector3 = v[f[1]]
		var c : Vector3 = v[f[2]]
		var n := (b - a).cross(c - a).normalized()
		# Force outward winding/normal (rock material is cull_back; the shape is
		# star-convex around the origin, so outward = pointing away from the centroid).
		var centroid := (a + b + c) / 3.0
		if n.dot(centroid) < 0.0:
			var tmp := b; b = c; c = tmp
			n = -n
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
