class_name ChunkMesher
extends RefCounted

## Pure-function marching-cubes mesher for one cubic chunk.
##
## Designed to run on a WorkerThreadPool task — `build()` takes plain data in
## and returns plain PackedArrays out. The main thread assembles the ArrayMesh.
##
## Pipeline:
##   1. Sample the density field on an (R+3)³ grid: R cells per axis plus 1
##      halo voxel on each face. The halo gives us valid central-difference
##      gradients for the chunk's boundary corners.
##   2. For each face flagged in `coarser_mask`, RESAMPLE the boundary samples
##      on that face so they lie on the coarser neighbour's grid (linear /
##      bilinear interpolation between the every-other "coarse-aligned"
##      samples). This is the Transvoxel-equivalent crack fix: the iso-surface
##      MC produces on that boundary now matches exactly what the coarser
##      neighbour produces on its own boundary, with no hidden geometry.
##      ("Transvoxel transition cells" in Lengyel's paper achieve the same
##      goal with hand-crafted tables; resampling the density gets the same
##      result without 12 KB of constants.)
##   3. Precompute per-corner gradients (3 PackedFloat32Arrays of (R+1)³).
##   4. Run marching cubes per cell with three per-axis edge caches so each
##      interpolated edge vertex is emitted exactly once and shared by
##      neighbouring cells (gives free smooth shading).
##
## Skirts are no longer emitted — boundary resampling makes them redundant
## and they were visually intrusive at LOD transitions. The skirt path is
## kept in the file for reference and is gated on `skirts=true` in the input.

const SKIRT_DEPTH_FACTOR : float = 2.5  # how many voxels deep to drop the skirt

# How many cells inward from a coarser-neighbour face we softly low-pass the
# tangent-plane samples. Layer 0 is the boundary itself (forced to coarse
# alignment); each subsequent layer gets a weaker tangent average so the
# transition from "coarse-looking surface" to "fine-looking surface" is
# spread across LOD_BLEND_DEPTH cells instead of one. This is a refined
# version of plain boundary resampling — still NOT Lengyel's transition
# cells, which need the ~13 KB transition lookup tables, but it kills the
# visible kink along LOD boundaries far better than a single-layer match.
const LOD_BLEND_DEPTH : int = 3

# Edge-to-cache mapping. For cell (ci, cj, ck) and edge e, the edge's owning
# start corner in chunk coords is (ci + E_DCI[e], cj + E_DCJ[e], ck + E_DCK[e])
# and its axis (0=X, 1=Y, 2=Z) determines which per-axis cache to read.
const E_AXIS : Array[int] = [0, 2, 0, 2, 0, 2, 0, 2, 1, 1, 1, 1]
const E_DCI  : Array[int] = [0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0]
const E_DCJ  : Array[int] = [0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0]
const E_DCK  : Array[int] = [0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1]


## Entry point for WorkerThreadPool. `input` keys:
##   origin (Vector3) — chunk corner in local-frame world units
##   size   (float)   — chunk side length, world units
##   resolution (int) — voxels per axis (typ. 16 or 32)
##   planet_center (Vector3)
##   density (DensityField)
##   coarser_mask (int) — bitmask of faces with a coarser neighbour:
##                        bit 0 = -X, 1 = +X, 2 = -Y, 3 = +Y, 4 = -Z, 5 = +Z.
##                        Boundary samples on flagged faces are resampled to
##                        the coarse grid (linear in one tangent direction,
##                        bilinear at corner-of-cell positions) so the
##                        iso-surface lines up with the coarse neighbour's.
##   skirts  (bool, default false) — legacy skirt pass; off by default now
##                                   that boundary resampling handles cracks
static func build(input: Dictionary) -> Dictionary:
	var origin        : Vector3      = input["origin"]
	var size          : float        = input["size"]
	var resolution    : int          = input["resolution"]
	var planet_center : Vector3 = input["planet_center"]
	var density       : Variant = input["density"]   # DensityField or CraterDensity
	var coarser_mask  : int          = input.get("coarser_mask", 0)
	var emit_skirts   : bool         = input.get("skirts", false)

	var voxel    := size / float(resolution)
	var gs       := resolution + 3        # samples per axis incl. halo
	var gs2      := gs * gs
	var base     := origin - Vector3(voxel, voxel, voxel)  # world pos of array idx (0,0,0)

	# ── 1. Sample density grid ──────────────────────────────────────────────
	var d := PackedFloat32Array()
	d.resize(gs * gs * gs)
	for zi in gs:
		var zw := base.z + zi * voxel
		var zo := zi * gs2
		for yi in gs:
			var yw := base.y + yi * voxel
			var yo := yi * gs + zo
			for xi in gs:
				var xw := base.x + xi * voxel
				d[xi + yo] = density.sample(Vector3(xw, yw, zw))

	# (Note: boundary resampling that used to live here has been replaced by
	# the Transvoxel transition-cell pass at the end of this function. The
	# transition cells provide proper Lengyel-style stitching between the
	# fine chunk's surface and the coarser neighbour's surface — both
	# crack-free *and* free of the C1 normal-kink that resampling left.)

	# Early-out: no sign change ⇒ no surface ⇒ empty mesh.
	if not _has_surface(d):
		return _empty_result()

	# ── 2. Per-corner gradients on the (R+1)³ corner grid ───────────────────
	var cs   := resolution + 1
	var cs2  := cs * cs
	var grad_x := PackedFloat32Array(); grad_x.resize(cs * cs * cs)
	var grad_y := PackedFloat32Array(); grad_y.resize(cs * cs * cs)
	var grad_z := PackedFloat32Array(); grad_z.resize(cs * cs * cs)
	for ck in cs:
		var ka := ck + 1
		for cj in cs:
			var ja := cj + 1
			var row := cj * cs + ck * cs2
			for ci in cs:
				var ia := ci + 1
				var off := ci + row
				grad_x[off] = d[(ia + 1) + ja * gs + ka * gs2] - d[(ia - 1) + ja * gs + ka * gs2]
				grad_y[off] = d[ia + (ja + 1) * gs + ka * gs2] - d[ia + (ja - 1) * gs + ka * gs2]
				grad_z[off] = d[ia + ja * gs + (ka + 1) * gs2] - d[ia + ja * gs + (ka - 1) * gs2]

	# ── 3. Marching cubes with per-axis edge caches ─────────────────────────
	var positions := PackedVector3Array()
	var normals   := PackedVector3Array()
	var indices   := PackedInt32Array()

	# Per-axis caches: X-edges (R, cs, cs); Y-edges (cs, R, cs); Z-edges (cs, cs, R).
	var cx_cache := PackedInt32Array(); cx_cache.resize(resolution * cs * cs); cx_cache.fill(-1)
	var cy_cache := PackedInt32Array(); cy_cache.resize(cs * resolution * cs); cy_cache.fill(-1)
	var cz_cache := PackedInt32Array(); cz_cache.resize(cs * cs * resolution); cz_cache.fill(-1)

	var dv := PackedFloat32Array(); dv.resize(8)
	var edge_verts := PackedInt32Array(); edge_verts.resize(12)

	for ck in resolution:
		for cj in resolution:
			for ci in resolution:
				# Read 8 corner densities, build the 8-bit case index.
				var case_idx := 0
				for corner in 8:
					var ai := ci + TransvoxelTables.CO_X[corner] + 1
					var aj := cj + TransvoxelTables.CO_Y[corner] + 1
					var ak := ck + TransvoxelTables.CO_Z[corner] + 1
					var val := d[ai + aj * gs + ak * gs2]
					dv[corner] = val
					if val > 0.0:
						case_idx |= 1 << corner

				var edges_mask : int = TransvoxelTables.EDGE_TABLE[case_idx]
				if edges_mask == 0:
					continue

				for e in 12:
					if (edges_mask & (1 << e)) == 0:
						continue
					var axis : int = E_AXIS[e]
					var sci  : int = ci + E_DCI[e]
					var scj  : int = cj + E_DCJ[e]
					var sck  : int = ck + E_DCK[e]

					var v := -1
					var cidx := 0
					match axis:
						0:
							cidx = sci + resolution * scj + resolution * cs * sck
							v = cx_cache[cidx]
						1:
							cidx = sci + cs * scj + cs * resolution * sck
							v = cy_cache[cidx]
						_:
							cidx = sci + cs * scj + cs2 * sck
							v = cz_cache[cidx]

					if v < 0:
						v = _emit_edge_vertex(
							e, dv, ci, cj, ck, voxel, base,
							grad_x, grad_y, grad_z, cs, cs2,
							positions, normals)
						match axis:
							0: cx_cache[cidx] = v
							1: cy_cache[cidx] = v
							_: cz_cache[cidx] = v

					edge_verts[e] = v

				var tri_base := case_idx * 16
				var ti := 0
				# Winding flip: the TRI_TABLE here is Paul Bourke's verbatim, which
				# was authored for the "bit set ⇔ val < iso" convention. We use
				# the opposite convention ("bit set ⇔ val > 0 ⇔ inside"), so
				# every triangle would come out CW-from-outside. Swap two
				# indices per triangle to restore CCW-from-outside winding.
				while ti < 16 and TransvoxelTables.TRI_TABLE[tri_base + ti] >= 0:
					indices.append(edge_verts[TransvoxelTables.TRI_TABLE[tri_base + ti]])
					indices.append(edge_verts[TransvoxelTables.TRI_TABLE[tri_base + ti + 2]])
					indices.append(edge_verts[TransvoxelTables.TRI_TABLE[tri_base + ti + 1]])
					ti += 3

	# ── 3b. Transvoxel transition cells (Lengyel 2010) ─────────────────────
	# For each face flagged in `coarser_mask`:
	#   1. Carve out a half-voxel slab on the fine side of the boundary by
	#      shifting every regular-cell vertex that sits exactly on that face
	#      inward by half a voxel. This is the "secondary position" baked in
	#      — Lengyel uses it at render time, we bake it because the chunk's
	#      coarser_mask is fixed at mesh-build time.
	#   2. Fill the slab with the transition mesh, whose low-res face stays
	#      on the original boundary plane (matching the coarse neighbour's
	#      surface exactly — same sample values + same linear interpolation)
	#      and whose high-res face is at the same shifted depth as the
	#      regular cells' boundary vertices.
	# Result: no gap, no overlap, no normal kink across the LOD boundary.
	if coarser_mask != 0:
		_shift_regular_boundary_vertices(
			positions, origin, size, voxel, coarser_mask)
		_build_transition_cells(
			d, gs, gs2, resolution, voxel, origin, planet_center, coarser_mask,
			grad_x, grad_y, grad_z, cs, cs2,
			density,
			positions, normals, indices)

	# ── 3c. Universal boundary skirts — the "no gaps, ever" guarantee ────────
	# Transvoxel transition cells only stitch FACE boundaries at a 1-LOD step;
	# they leave hairline cracks at chunk EDGES and CORNERS (where 3+ chunks of
	# differing LOD meet) and anywhere the surfaces don't quite line up. We seal
	# ALL of them geometrically: wherever the iso-surface exits any of the 6
	# chunk faces, drop a wall radially inward. Adjacent chunks' surfaces can
	# disagree at the seam, but the wall always backs the boundary with
	# terrain-shaded geometry, so the background/space can never show through.
	# (Appended BEFORE the normal-finalise pass so its raw-gradient normals get
	# the same negate+outward treatment and shade continuously with the surface
	# — no flat "outline" like the earlier shallow version.)
	_append_boundary_skirts(
		positions, normals, indices,
		d, gs, gs2, resolution, base, voxel, planet_center,
		grad_x, grad_y, grad_z, cs, cs2)

	# Finalise normals. Stored as raw gradient ∇d during emission. The outward
	# surface normal is -∇d (density is positive inside the planet, so ∇d
	# points toward the centre). We then guarantee the orientation by checking
	# against the radial direction (which is always reliably outward for a
	# roughly-spherical planet) and flipping if the gradient came out wrong —
	# the gradient sign can be fragile near halo voxels and boundary-resampled
	# faces, and a single mis-oriented normal poisons the whole biome shader.
	for vi in normals.size():
		var radial_out := (positions[vi] - planet_center)
		if radial_out.length_squared() < 1e-12:
			radial_out = Vector3.UP
		radial_out = radial_out.normalized()
		var n := -normals[vi]
		if n.length_squared() < 1e-12:
			normals[vi] = radial_out
			continue
		n = n.normalized()
		# If the gradient-derived normal disagrees with the outward radial,
		# flip it. Tangential normals (cliffs) are still allowed — only invert
		# when actually pointing into the planet.
		if n.dot(radial_out) < 0.0:
			n = -n
		normals[vi] = n

	# ── 4. Skirts ───────────────────────────────────────────────────────────
	if emit_skirts:
		_append_skirts(
			positions, normals, indices,
			d, gs, gs2, resolution, base, voxel, planet_center)

	return {
		"positions": positions,
		"normals":   normals,
		"indices":   indices,
		"empty":     indices.size() == 0,
	}


# Boundary resampling for "I'm the finer chunk meeting a coarser neighbour".
#
# Coarse-aligned positions on a boundary face are at chunk coords (j, k) where
# both j and k are EVEN (these correspond to the coarse neighbour's actual
# samples, since the coarse voxel is 2× our voxel). The other 3 cases — only
# j odd, only k odd, both odd — are between coarse samples and must be set to
# a linear / linear / bilinear interpolation of the coarse-aligned samples,
# so the iso-surface MC computes there is the SAME surface the coarse cell
# would produce.
#
# We need `resolution` to be EVEN for this to be exact (so j, k can range up
# to R and have a coarse-aligned partner at R or R-1). The project defaults
# to resolution=16 which satisfies this.
#
# We read original samples and write back into the same array. Because reads
# only ever touch positions with even (j, k), and writes only touch positions
# with odd (j or k), there's no read-after-write ordering hazard.
static func _resample_boundary(d: PackedFloat32Array, gs: int, gs2: int,
		resolution: int, coarser_mask: int) -> void:
	# Iterate the 6 faces. For each face, the iteration plane is the boundary
	# face; the fixed coordinate is at the chunk edge in array coords.
	for face_bit in 6:
		if (coarser_mask & (1 << face_bit)) == 0:
			continue
		@warning_ignore("integer_division")
		var axis : int = face_bit / 2     # 0=X, 1=Y, 2=Z (intentional truncating div)
		var side : int = face_bit & 1     # 0=-face (low), 1=+face (high)
		var u_axis := (axis + 1) % 3
		var v_axis := (axis + 2) % 3
		var fixed_arr : int = 1 + (resolution if side == 1 else 0)
		# Walk every chunk-coord (j, k) on the face in [0..R].
		for j in resolution + 1:
			for k in resolution + 1:
				var j_odd := (j & 1) == 1
				var k_odd := (k & 1) == 1
				if not j_odd and not k_odd:
					continue   # coarse-aligned, leave as-is
				# Build the array indices for current target and for its
				# coarse-aligned neighbours.
				var arr_target := _arr_idx_on_face(axis, fixed_arr, u_axis, v_axis, j, k, gs, gs2)
				var new_val : float = 0.0
				if j_odd and not k_odd:
					var a := _arr_idx_on_face(axis, fixed_arr, u_axis, v_axis, j - 1, k, gs, gs2)
					var b := _arr_idx_on_face(axis, fixed_arr, u_axis, v_axis, j + 1, k, gs, gs2)
					new_val = 0.5 * (d[a] + d[b])
				elif k_odd and not j_odd:
					var a := _arr_idx_on_face(axis, fixed_arr, u_axis, v_axis, j, k - 1, gs, gs2)
					var b := _arr_idx_on_face(axis, fixed_arr, u_axis, v_axis, j, k + 1, gs, gs2)
					new_val = 0.5 * (d[a] + d[b])
				else:   # both odd → bilinear of 4 coarse corners
					var a := _arr_idx_on_face(axis, fixed_arr, u_axis, v_axis, j - 1, k - 1, gs, gs2)
					var b := _arr_idx_on_face(axis, fixed_arr, u_axis, v_axis, j + 1, k - 1, gs, gs2)
					var c := _arr_idx_on_face(axis, fixed_arr, u_axis, v_axis, j - 1, k + 1, gs, gs2)
					var e := _arr_idx_on_face(axis, fixed_arr, u_axis, v_axis, j + 1, k + 1, gs, gs2)
					new_val = 0.25 * (d[a] + d[b] + d[c] + d[e])
				d[arr_target] = new_val


# Compose an array index for a sample on the given face. `fixed_arr` is the
# array coord on `axis`; (j, k) are chunk coords in [0..R] on the two tangent
# axes (mapped to array coords via +1 for the halo).
static func _arr_idx_on_face(axis: int, fixed_arr: int,
		u_axis: int, v_axis: int,
		j: int, k: int, gs: int, gs2: int) -> int:
	var arr := [0, 0, 0]
	arr[axis] = fixed_arr
	arr[u_axis] = j + 1
	arr[v_axis] = k + 1
	return arr[0] + arr[1] * gs + arr[2] * gs2


static func _has_surface(d: PackedFloat32Array) -> bool:
	if d.size() == 0:
		return false
	var first_sign := signf(d[0])
	for v in d:
		if signf(v) != first_sign:
			return true
	return false


static func _empty_result() -> Dictionary:
	return {
		"positions": PackedVector3Array(),
		"normals":   PackedVector3Array(),
		"indices":   PackedInt32Array(),
		"empty":     true,
	}


# Emit a new vertex on edge `e` of the cell at (ci, cj, ck). Caller caches the
# returned index. `normals` receives the raw +gradient (lerped between corners);
# build() normalises and flips at the end of the MC pass.
static func _emit_edge_vertex(
	e: int, dv: PackedFloat32Array,
	ci: int, cj: int, ck: int,
	voxel: float, base: Vector3,
	grad_x: PackedFloat32Array, grad_y: PackedFloat32Array, grad_z: PackedFloat32Array,
	cs: int, cs2: int,
	positions: PackedVector3Array, normals: PackedVector3Array) -> int:
	var ca : int = TransvoxelTables.EDGE_A[e]
	var cb : int = TransvoxelTables.EDGE_B[e]
	var da : float = dv[ca]
	var db : float = dv[cb]
	var denom := da - db
	var t : float = 0.5 if absf(denom) < 1e-8 else da / denom
	t = clampf(t, 0.0, 1.0)

	# Corner world positions (chunk array indices = chunk coords + 1 for halo).
	var pa := base + Vector3(
		(ci + TransvoxelTables.CO_X[ca] + 1) * voxel,
		(cj + TransvoxelTables.CO_Y[ca] + 1) * voxel,
		(ck + TransvoxelTables.CO_Z[ca] + 1) * voxel)
	var pb := base + Vector3(
		(ci + TransvoxelTables.CO_X[cb] + 1) * voxel,
		(cj + TransvoxelTables.CO_Y[cb] + 1) * voxel,
		(ck + TransvoxelTables.CO_Z[cb] + 1) * voxel)
	var p := pa.lerp(pb, t)

	# Interpolate the precomputed corner gradients along the edge.
	var ga := (ci + TransvoxelTables.CO_X[ca]) + cs * (cj + TransvoxelTables.CO_Y[ca]) + cs2 * (ck + TransvoxelTables.CO_Z[ca])
	var gb := (ci + TransvoxelTables.CO_X[cb]) + cs * (cj + TransvoxelTables.CO_Y[cb]) + cs2 * (ck + TransvoxelTables.CO_Z[cb])
	var n := Vector3(
		lerpf(grad_x[ga], grad_x[gb], t),
		lerpf(grad_y[ga], grad_y[gb], t),
		lerpf(grad_z[ga], grad_z[gb], t))

	positions.append(p)
	normals.append(n)
	return positions.size() - 1


# Universal boundary skirt. For every cell on each of the 6 chunk faces where
# the iso-surface crosses, drop a double-sided wall radially inward by a few
# voxels. This is the unconditional gap seal: it runs on ALL faces (so it
# covers edge/corner cracks Transvoxel can't, not just coarser-LOD faces), its
# depth scales with the voxel (so it always exceeds a 2:1 neighbour's surface
# step), and each wall vertex carries the iso-surface's own interpolated
# gradient normal (so it shades like the terrain it backs rather than as a flat
# band). At a matched same-LOD boundary the wall sits hidden behind the
# coincident surfaces; at a mismatched boundary it fills the daylight.
#
# `cps`/`cns` collect the crossing positions and their (raw-gradient) normals;
# walls are emitted per crossing PAIR (the surface enters and leaves the face
# cell), so a single line of wall traces the surface's exit from the chunk.
static func _append_boundary_skirts(
		positions: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array,
		d: PackedFloat32Array, gs: int, gs2: int, resolution: int,
		base: Vector3, voxel: float, planet_center: Vector3,
		grad_x: PackedFloat32Array, grad_y: PackedFloat32Array, grad_z: PackedFloat32Array,
		cs: int, cs2: int) -> void:
	# Deep enough to cover a 2:1 neighbour's worst-case surface step (the coarse
	# voxel is 2× ours). Tunable: raise if any sky still peeks at a seam.
	var drop := voxel * 2.5
	var faces := [
		[0, 0], [0, resolution], [1, 0], [1, resolution], [2, 0], [2, resolution],
	]
	var face_edges := [[0, 1], [1, 3], [3, 2], [2, 0]]
	for face in faces:
		var fixed_axis : int = face[0]
		var fixed_val  : int = face[1]
		var u_axis := (fixed_axis + 1) % 3
		var v_axis := (fixed_axis + 2) % 3
		for u in resolution:
			for v in resolution:
				var c00 := Vector3i.ZERO
				var c10 := Vector3i.ZERO
				var c01 := Vector3i.ZERO
				var c11 := Vector3i.ZERO
				c00[fixed_axis] = fixed_val; c00[u_axis] = u;     c00[v_axis] = v
				c10[fixed_axis] = fixed_val; c10[u_axis] = u + 1; c10[v_axis] = v
				c01[fixed_axis] = fixed_val; c01[u_axis] = u;     c01[v_axis] = v + 1
				c11[fixed_axis] = fixed_val; c11[u_axis] = u + 1; c11[v_axis] = v + 1
				var corners := [c00, c10, c01, c11]
				var dq := PackedFloat32Array(); dq.resize(4)
				for ci in 4:
					var c : Vector3i = corners[ci]
					dq[ci] = d[(c.x + 1) + (c.y + 1) * gs + (c.z + 1) * gs2]
				var fcase := 0
				for ci in 4:
					if dq[ci] > 0.0:
						fcase |= 1 << ci
				if fcase == 0 or fcase == 15:
					continue
				var cps : Array[Vector3] = []
				var cns : Array[Vector3] = []
				for ei in 4:
					var a : int = face_edges[ei][0]
					var b : int = face_edges[ei][1]
					if signf(dq[a]) == signf(dq[b]):
						continue
					var denom := dq[a] - dq[b]
					var t : float = 0.5 if absf(denom) < 1e-8 else dq[a] / denom
					t = clampf(t, 0.0, 1.0)
					var ca : Vector3i = corners[a]
					var cb : Vector3i = corners[b]
					var pa := base + Vector3(ca.x + 1, ca.y + 1, ca.z + 1) * voxel
					var pb := base + Vector3(cb.x + 1, cb.y + 1, cb.z + 1) * voxel
					cps.append(pa.lerp(pb, t))
					var ga : int = ca.x + ca.y * cs + ca.z * cs2
					var gb : int = cb.x + cb.y * cs + cb.z * cs2
					var na := Vector3(grad_x[ga], grad_y[ga], grad_z[ga])
					var nb := Vector3(grad_x[gb], grad_y[gb], grad_z[gb])
					cns.append(na.lerp(nb, t))
				if cps.size() < 2:
					continue
				@warning_ignore("integer_division")
				var n_pairs : int = cps.size() / 2
				for pi in n_pairs:
					var p0 : Vector3 = cps[pi * 2 + 0]
					var p1 : Vector3 = cps[pi * 2 + 1]
					var n0 : Vector3 = cns[pi * 2 + 0]
					var n1 : Vector3 = cns[pi * 2 + 1]
					var p0d : Vector3 = p0 + (planet_center - p0).normalized() * drop
					var p1d : Vector3 = p1 + (planet_center - p1).normalized() * drop
					var bi := positions.size()
					positions.append(p0); positions.append(p1)
					positions.append(p1d); positions.append(p0d)
					# Same surface normal on all 4 so the wall shades like the
					# terrain it continues from (finalise pass negates/outwards).
					normals.append(n0); normals.append(n1)
					normals.append(n1); normals.append(n0)
					# Double-sided so the seal holds from whichever side the
					# crack opens (the cull direction varies per cell).
					indices.append(bi + 0); indices.append(bi + 1); indices.append(bi + 2)
					indices.append(bi + 0); indices.append(bi + 2); indices.append(bi + 3)
					indices.append(bi + 0); indices.append(bi + 2); indices.append(bi + 1)
					indices.append(bi + 0); indices.append(bi + 3); indices.append(bi + 2)


# Boundary-face skirts: a strip of inward-dropping triangles per face cell
# whose surface line crosses the face. Cracks at LOD boundaries land *behind*
# this strip instead of showing the sky.
static func _append_skirts(
	positions: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array,
	d: PackedFloat32Array, gs: int, gs2: int, resolution: int,
	base: Vector3, voxel: float, planet_center: Vector3) -> void:
	var drop := voxel * SKIRT_DEPTH_FACTOR
	var faces := [
		[0, 0],
		[0, resolution],
		[1, 0],
		[1, resolution],
		[2, 0],
		[2, resolution],
	]
	for face in faces:
		var fixed_axis : int = face[0]
		var fixed_val  : int = face[1]
		var u_axis := (fixed_axis + 1) % 3
		var v_axis := (fixed_axis + 2) % 3
		for u in resolution:
			for v in resolution:
				# Four corners of the face cell, in chunk coords.
				var c00 := Vector3i.ZERO
				var c10 := Vector3i.ZERO
				var c01 := Vector3i.ZERO
				var c11 := Vector3i.ZERO
				c00[fixed_axis] = fixed_val; c00[u_axis] = u;     c00[v_axis] = v
				c10[fixed_axis] = fixed_val; c10[u_axis] = u + 1; c10[v_axis] = v
				c01[fixed_axis] = fixed_val; c01[u_axis] = u;     c01[v_axis] = v + 1
				c11[fixed_axis] = fixed_val; c11[u_axis] = u + 1; c11[v_axis] = v + 1
				var corners := [c00, c10, c01, c11]

				var dq := PackedFloat32Array(); dq.resize(4)
				for ci in 4:
					var c : Vector3i = corners[ci]
					dq[ci] = d[(c.x + 1) + (c.y + 1) * gs + (c.z + 1) * gs2]

				var fcase := 0
				for ci in 4:
					if dq[ci] > 0.0:
						fcase |= 1 << ci
				if fcase == 0 or fcase == 15:
					continue

				# Face edges: (corner_a, corner_b)
				var face_edges := [[0, 1], [1, 3], [3, 2], [2, 0]]
				var crossings : Array[Vector3] = []
				for ei in 4:
					var a : int = face_edges[ei][0]
					var b : int = face_edges[ei][1]
					if signf(dq[a]) == signf(dq[b]):
						continue
					var denom := dq[a] - dq[b]
					var t : float = 0.5 if absf(denom) < 1e-8 else dq[a] / denom
					t = clampf(t, 0.0, 1.0)
					var ca : Vector3i = corners[a]
					var cb : Vector3i = corners[b]
					var pa := base + Vector3(ca.x + 1, ca.y + 1, ca.z + 1) * voxel
					var pb := base + Vector3(cb.x + 1, cb.y + 1, cb.z + 1) * voxel
					crossings.append(pa.lerp(pb, t))
				if crossings.size() < 2:
					continue

				var p0 : Vector3 = crossings[0]
				var p1 : Vector3 = crossings[1]
				var drop0 := (planet_center - p0).normalized() * drop
				var drop1 := (planet_center - p1).normalized() * drop
				var p0d := p0 + drop0
				var p1d := p1 + drop1
				var mid := (p0 + p1) * 0.5
				var n_out := (mid - planet_center).normalized()

				# Double-sided emission: each quad becomes 4 triangles (CCW
				# pair + CW pair). The triangle's "outward" cull direction
				# depends on the iso-surface crossing geometry which varies
				# per cell, so we can't pick a single consistent winding.
				# Doubling up costs ~2× the skirt triangles but guarantees
				# the wall is visible from whichever side the crack opens.
				var base_idx := positions.size()
				positions.append(p0)
				positions.append(p1)
				positions.append(p1d)
				positions.append(p0d)
				normals.append(n_out)
				normals.append(n_out)
				normals.append(n_out)
				normals.append(n_out)
				# CCW pair.
				indices.append(base_idx + 0)
				indices.append(base_idx + 1)
				indices.append(base_idx + 2)
				indices.append(base_idx + 0)
				indices.append(base_idx + 2)
				indices.append(base_idx + 3)
				# CW pair (reverse winding).
				indices.append(base_idx + 0)
				indices.append(base_idx + 2)
				indices.append(base_idx + 1)
				indices.append(base_idx + 0)
				indices.append(base_idx + 3)
				indices.append(base_idx + 2)


# ────────────────────────────────────────────────────────────────────────────
# Transvoxel transition cells (Lengyel 2010). Full implementation:
#   • All 13 transition-cell corners primary-positioned on the boundary face
#     (per Lengyel). Vertices whose edge touches any high-res corner (0..8)
#     are moved to the SECONDARY position — half a voxel inward — so they
#     meet the regular mesh which has been carved out the same amount by
#     `_shift_regular_boundary_vertices`. Vertices whose edge involves only
#     half-res corners (9..12) stay on the boundary plane, where they meet
#     the coarse neighbour's surface exactly.
#   • Per-corner gradients are interpolated along each edge and written into
#     the mesh's normal array, then run through the same outward-radial
#     post-pass as the regular cells. Slab geometry now picks up real cliff
#     shading instead of falling back to a uniform radial normal.
#   • Per-face 2D vertex-reuse cache (one slot bank per face cell), keyed by
#     the `transitionCornerData` / `transitionVertexData` reuse encoding.
#     Vertices on shared edges are emitted once and looked up from the
#     adjacent cell on subsequent visits — eliminates the duplicate copies
#     the earlier version produced along every transition seam.
static func _build_transition_cells(
		d: PackedFloat32Array, gs: int, gs2: int, resolution: int,
		voxel: float, origin: Vector3, planet_center: Vector3, coarser_mask: int,
		grad_x: PackedFloat32Array, grad_y: PackedFloat32Array, grad_z: PackedFloat32Array,
		cs: int, cs2: int,
		density: Variant,
		positions: PackedVector3Array, normals: PackedVector3Array,
		indices: PackedInt32Array) -> void:
	for face_bit in 6:
		if (coarser_mask & (1 << face_bit)) == 0:
			continue
		_process_transition_face(
			face_bit, d, gs, gs2, resolution, voxel, origin, planet_center,
			grad_x, grad_y, grad_z, cs, cs2,
			density,
			positions, normals, indices)


# Iterate the (R/2)^2 transition cells on one face. `face_bit` 0..5 maps to
# -X, +X, -Y, +Y, -Z, +Z in the same convention as the rest of the file.
static func _process_transition_face(
		face_bit: int,
		d: PackedFloat32Array, gs: int, gs2: int, resolution: int,
		voxel: float, origin: Vector3, planet_center: Vector3,
		grad_x: PackedFloat32Array, grad_y: PackedFloat32Array, grad_z: PackedFloat32Array,
		cs: int, cs2: int,
		density: Variant,
		positions: PackedVector3Array, normals: PackedVector3Array,
		indices: PackedInt32Array) -> void:
	@warning_ignore("integer_division")
	var axis : int = face_bit / 2
	var side : int = face_bit & 1
	var u_axis := (axis + 1) % 3
	var v_axis := (axis + 2) % 3
	# Chunk-corner index along `axis` for the boundary face.
	var fixed_chunk : int = resolution if side == 1 else 0
	# Signed inward direction along `axis`: +1 for -face (we step into +axis),
	# -1 for +face.
	var inward_sign : float = -1.0 if side == 1 else 1.0
	# Secondary-position offset. Lengyel's paper uses half a fine voxel for
	# the slab thickness, but that's tens of metres at the root LOD which
	# makes the bridging geometry read as a cliff to the biome shader. We
	# clamp the slab thickness to a planetary-scale absolute maximum so it
	# stays a thin sliver regardless of voxel size — visually invisible at
	# distance, geometrically still crack-free.
	var slab_depth : float = minf(0.5 * voxel, 1.5)   # max 1.5 m thick
	var inward_off := Vector3.ZERO
	if axis == 0:
		inward_off.x = inward_sign * slab_depth
	elif axis == 1:
		inward_off.y = inward_sign * slab_depth
	else:
		inward_off.z = inward_sign * slab_depth

	# Per-face 2D vertex cache. One bank of 4 slots per face cell (the slot
	# index comes from `transitionCornerData` / the reuse-slot nibble of
	# `transitionVertexData`). -1 = empty.
	@warning_ignore("integer_division")
	var face_cells_u : int = resolution / 2
	@warning_ignore("integer_division")
	var face_cells_v : int = resolution / 2
	# 16 slots per face cell. The reuse-slot nibble in `transitionVertexData`
	# / `transitionCornerData` is 4 bits wide (values 0..15) and indexes a
	# per-cell vertex slot; in practice values up to 11 appear in Lengyel's
	# tables but we size the bank to the full nibble range to avoid out-of-
	# bounds writes on any case-code path. Total = face_cells² × 16 ints.
	var cache := PackedInt32Array()
	cache.resize(face_cells_u * face_cells_v * 16)
	cache.fill(-1)

	# Chunk-outward direction at this face — opposite of inward_off. Used
	# with the face-centre's planet-outward to decide ONCE per face (not
	# per cell) whether the lookup-table's natural winding produces
	# triangles facing AWAY from the planet. Per-cell decisions are unsafe
	# for chunks whose face straddles the planet's terminator: cell centres
	# near the terminator give a dot product near zero, so neighbouring
	# cells can land on opposite sides of the flip threshold, alternating
	# winding and producing visible seams. The face-centre decision is
	# stable across the entire face.
	var chunk_outward := -inward_off.normalized()
	# Face-centre = origin + (offset to the face's centre point), which is
	# half-size on each tangent axis, and 0 (for -face) or full size (for
	# +face) on the perpendicular axis.
	var size_v := float(resolution) * voxel
	var face_center_offset := Vector3.ZERO
	face_center_offset[axis] = float(fixed_chunk) * voxel
	face_center_offset[u_axis] = size_v * 0.5
	face_center_offset[v_axis] = size_v * 0.5
	var face_center := origin + face_center_offset
	var face_planet_radial := face_center - planet_center
	var face_radial_flip := false
	if face_planet_radial.length_squared() > 1e-12:
		face_radial_flip = face_planet_radial.normalized().dot(chunk_outward) < 0.0

	var fu := 0
	while fu + 2 <= resolution:
		var fv := 0
		while fv + 2 <= resolution:
			_emit_transition_cell(
				axis, u_axis, v_axis, fixed_chunk, inward_off, face_radial_flip,
				fu, fv, face_cells_v,
				d, gs, gs2, voxel, origin,
				grad_x, grad_y, grad_z, cs, cs2,
				density,
				cache, positions, normals, indices)
			fv += 2
		fu += 2


# Build, look up, and emit one transition cell at (fu, fv) on the given face.
static func _emit_transition_cell(
		axis: int, u_axis: int, v_axis: int, fixed_chunk: int, inward_off: Vector3,
		face_radial_flip: bool,
		fu: int, fv: int, face_cells_v: int,
		d: PackedFloat32Array, gs: int, gs2: int,
		voxel: float, origin: Vector3,
		grad_x: PackedFloat32Array, grad_y: PackedFloat32Array, grad_z: PackedFloat32Array,
		cs: int, cs2: int,
		density: Variant,
		cache: PackedInt32Array,
		positions: PackedVector3Array, normals: PackedVector3Array,
		indices: PackedInt32Array) -> void:

	# Sample the 9 fine corners on the boundary face. Layout per Lengyel:
	#   6 7 8
	#   3 4 5
	#   0 1 2
	# u increases left→right, v increases bottom→top.
	var samples : PackedFloat32Array = PackedFloat32Array()
	samples.resize(13)
	for sv in 3:
		for su in 3:
			samples[sv * 3 + su] = d[_face_sample_index(
				axis, u_axis, v_axis, fixed_chunk, fu + su, fv + sv, gs, gs2)]
	# Half-res samples 9..12 mirror corners 0, 2, 6, 8. The coarser
	# neighbour samples only at these coarse-aligned positions, so the
	# transition cell's low-res face replicates exactly what the coarse
	# chunk computes on the shared boundary.
	samples[9]  = samples[0]
	samples[10] = samples[2]
	samples[11] = samples[6]
	samples[12] = samples[8]

	# 9-bit case code. Bit set ⇔ sample BELOW isolevel (Lengyel's convention).
	# For our positive-inside SDF that means `sample < 0`. Bits are NOT in
	# sample order — Lengyel reordered them for table compactness.
	var case_code := 0
	if samples[0] < 0.0: case_code |= 0x001
	if samples[1] < 0.0: case_code |= 0x002
	if samples[2] < 0.0: case_code |= 0x004
	if samples[5] < 0.0: case_code |= 0x008
	if samples[8] < 0.0: case_code |= 0x010
	if samples[7] < 0.0: case_code |= 0x020
	if samples[6] < 0.0: case_code |= 0x040
	if samples[3] < 0.0: case_code |= 0x080
	if samples[4] < 0.0: case_code |= 0x100
	if case_code == 0 or case_code == 511:
		return  # all in or all out — no surface in this cell

	var cell_class_raw : int = TransvoxelTransitionTables.CELL_CLASS[case_code]
	var cell_class : int = cell_class_raw & 0x7f
	var flip_winding : bool = (cell_class_raw & 0x80) != 0
	var geom : int = TransvoxelTransitionTables.CELL_GEOM[cell_class]
	var vertex_count : int = geom >> 4
	var triangle_count : int = geom & 0x0f
	var class_indices : PackedInt32Array = TransvoxelTransitionTables.CELL_INDICES[cell_class]

	# Corner positions. Corners 0..8 (high-res face) sit at the SLAB depth,
	# one inward_off into the chunk. Corners 9..12 (low-res face) sit on
	# the boundary plane. With this layout the edge interpolant `t` does
	# the right thing on every edge type:
	#   • edges between two high-res corners (both 0..8): vertex lands on
	#     the high-res plane (= slab depth), matching the carved-out fine
	#     regular mesh exactly.
	#   • edges between two low-res corners (both 9..12): vertex lands on
	#     the boundary plane (= depth 0), matching the coarse neighbour's
	#     surface exactly.
	#   • cross-edges (one high-res endpoint, one low-res): vertex lands
	#     at a depth between 0 and slab_depth, the t-weighted blend of
	#     the two endpoints. This is what was wrong before — the previous
	#     version shifted the vertex by the FULL slab_depth on every
	#     high-res-involved edge, so cross-edges popped to slab_depth
	#     instead of bridging smoothly, producing the visible seam.
	var cpos : Array = []
	cpos.resize(13)
	for sv in 3:
		for su in 3:
			var boundary_pos := _corner_world_pos(
				axis, u_axis, v_axis, fixed_chunk, fu + su, fv + sv, voxel, origin)
			cpos[sv * 3 + su] = boundary_pos + inward_off
	cpos[9]  = _corner_world_pos(
			axis, u_axis, v_axis, fixed_chunk, fu + 0, fv + 0, voxel, origin)
	cpos[10] = _corner_world_pos(
			axis, u_axis, v_axis, fixed_chunk, fu + 2, fv + 0, voxel, origin)
	cpos[11] = _corner_world_pos(
			axis, u_axis, v_axis, fixed_chunk, fu + 0, fv + 2, voxel, origin)
	cpos[12] = _corner_world_pos(
			axis, u_axis, v_axis, fixed_chunk, fu + 2, fv + 2, voxel, origin)

	# Per-corner gradients. Corners 0..8 (high-res face) use the precomputed
	# fine-grid central differences — that matches the FINE chunk's regular
	# mesh exactly, so the high-res slab face has no shading kink against
	# the carved-out boundary vertices.
	#
	# Corners 9..12 (low-res face) DO NOT mirror the fine gradients any
	# longer. They use COARSE-resolution central differences sampled
	# directly from the density function at h = 2 * fine voxel. This
	# matches what the coarse neighbour's regular MC computes at the same
	# world position (it samples its own grid at coarse spacing), so the
	# low-res slab vertices and the coarse mesh's boundary vertices share
	# both position AND normal — eliminating the shading seam the old
	# fine-gradient mirroring left along every 1-LOD transition.
	#
	# Cost: 6 density samples per low-res corner × 4 corners per cell.
	# Per face (R/2)² cells: ~860 sample calls for R=12. Cheap relative to
	# the regular MC's R³ sampling.
	var cgrad : Array = []
	cgrad.resize(13)
	for sv in 3:
		for su in 3:
			cgrad[sv * 3 + su] = _corner_gradient(
				axis, u_axis, v_axis, fixed_chunk, fu + su, fv + sv,
				grad_x, grad_y, grad_z, cs, cs2)
	var coarse_h := 2.0 * voxel
	cgrad[9]  = _coarse_resolution_gradient(cpos[9],  density, coarse_h)
	cgrad[10] = _coarse_resolution_gradient(cpos[10], density, coarse_h)
	cgrad[11] = _coarse_resolution_gradient(cpos[11], density, coarse_h)
	cgrad[12] = _coarse_resolution_gradient(cpos[12], density, coarse_h)

	# Cache coordinates (one entry per 2×2 fine-cell area on the face). The
	# reuse-direction bits in the table use a 2D scheme: bit 0 = look up the
	# cell one step back in the u direction; bit 1 = look up one step back in
	# v. Only "back" directions are ever asked for, since we walk u-outer,
	# v-inner — so earlier cells have already been emitted.
	@warning_ignore("integer_division")
	var ccu : int = fu / 2
	@warning_ignore("integer_division")
	var ccv : int = fv / 2
	var direction_validity := 0
	if ccu > 0: direction_validity |= 1
	if ccv > 0: direction_validity |= 2

	var local_verts : PackedInt32Array = PackedInt32Array()
	local_verts.resize(vertex_count)

	for vi in vertex_count:
		var edge_code : int = TransvoxelTransitionTables.VERTEX_DATA[case_code * 12 + vi]
		var ca : int = (edge_code >> 4) & 0x0f
		var cb : int = edge_code & 0x0f
		var reuse_slot : int = (edge_code >> 8) & 0x0f
		var reuse_dir  : int = (edge_code >> 12) & 0x0f

		var sa : float = samples[ca]
		var sb : float = samples[cb]
		var denom := sb - sa
		var t : float
		var corner_exact := false
		if absf(denom) < 1e-8:
			t = 0.5
		else:
			t = sb / denom
			if t <= 0.0 or t >= 1.0:
				corner_exact = true
				t = clampf(t, 0.0, 1.0)
			else:
				t = clampf(t, 0.0, 1.0)

		var emitted_index := -1

		if corner_exact:
			# Vertex sits exactly on one corner — use CORNER_DATA's reuse
			# nibbles, not the edge_code reuse nibbles.
			var corner_index : int = cb if t <= 0.0 else ca
			var corner_data : int = TransvoxelTransitionTables.CORNER_DATA[corner_index]
			var c_slot : int = corner_data & 0x0f
			var c_dir  : int = (corner_data >> 4) & 0x0f
			if (c_dir & direction_validity) == c_dir and c_dir != 0:
				var prev_ccu := ccu - (c_dir & 1)
				var prev_ccv := ccv - ((c_dir >> 1) & 1)
				emitted_index = cache[(prev_ccu * face_cells_v + prev_ccv) * 16 + c_slot]
			if emitted_index < 0:
				emitted_index = _emit_transition_vertex(
					t, ca, cb, cpos, cgrad,
					positions, normals)
				cache[(ccu * face_cells_v + ccv) * 16 + c_slot] = emitted_index
		else:
			# Interior-of-edge vertex. Reuse_dir bits:
			#   0x1 = previous cell in -u, 0x2 = previous cell in -v,
			#   0x4 = interior edge (never reusable, never cacheable),
			#   0x8 = maximal edge (this vertex should be cached for later).
			var can_lookup := (reuse_dir & 0x3) != 0 and (reuse_dir & 0x4) == 0 \
					and (reuse_dir & direction_validity) == (reuse_dir & 0x3)
			if can_lookup:
				var prev_ccu := ccu - (reuse_dir & 1)
				var prev_ccv := ccv - ((reuse_dir >> 1) & 1)
				emitted_index = cache[(prev_ccu * face_cells_v + prev_ccv) * 16 + reuse_slot]
			if emitted_index < 0:
				emitted_index = _emit_transition_vertex(
					t, ca, cb, cpos, cgrad,
					positions, normals)
				# Cache for adjacent cells if this edge is "maximal"
				# (bit 3 set in reuse_dir).
				if (reuse_dir & 0x8) != 0:
					cache[(ccu * face_cells_v + ccv) * 16 + reuse_slot] = emitted_index

		local_verts[vi] = emitted_index

	# Emit triangles. Two flip sources XORed together: the lookup-table's
	# `flip_winding` bit (inverse-class case) and `face_radial_flip` (the
	# face is the chunk's planet-inner face, so the natural winding points
	# inward and cull_back would hide it).
	for ti in triangle_count:
		var i0 := local_verts[class_indices[ti * 3]]
		var i1 := local_verts[class_indices[ti * 3 + 1]]
		var i2 := local_verts[class_indices[ti * 3 + 2]]
		var do_flip := flip_winding != face_radial_flip   # XOR
		if do_flip:
			indices.append(i0); indices.append(i2); indices.append(i1)
		else:
			indices.append(i0); indices.append(i1); indices.append(i2)


# Emit a single transition-cell vertex. `t` is the edge interpolant such
# that vertex = pa*t + pb*(1-t) (matching Lengyel/Zylann's convention).
# The slab-depth offset is baked into `cpos` directly — corners 0..8 are
# already at slab depth, corners 9..12 are on the boundary plane — so the
# lerp produces the correct depth on every edge (high-res, low-res, or
# cross) without any per-vertex shift here.
static func _emit_transition_vertex(
		t: float, ca: int, cb: int,
		cpos: Array, cgrad: Array,
		positions: PackedVector3Array, normals: PackedVector3Array) -> int:
	var pa : Vector3 = cpos[ca]
	var pb : Vector3 = cpos[cb]
	var p := pa * t + pb * (1.0 - t)
	var ga : Vector3 = cgrad[ca]
	var gb : Vector3 = cgrad[cb]
	var g := ga * t + gb * (1.0 - t)
	positions.append(p)
	normals.append(g)   # raw +gradient — final pass negates and outward-flips
	return positions.size() - 1


# Shift every regular-mesh vertex that sits exactly on a coarser-LOD
# boundary face inward by half a voxel. This is the baked-in version of
# Lengyel's secondary position for the regular mesh: it opens the slab that
# `_build_transition_cells` fills, with no gap and no overlap.
#
# An eps tolerance of ~1% of a voxel keeps the test stable against rounding
# from the lerp inside `_emit_edge_vertex`. Vertices on edges that *cross*
# the boundary (i.e. not exactly on it) are untouched, which is what we
# want — those connect into the chunk interior at the normal fine depth.
static func _shift_regular_boundary_vertices(
		positions: PackedVector3Array, origin: Vector3, size: float,
		voxel: float, coarser_mask: int) -> void:
	# Same clamp as the transition mesher uses for its `slab_depth` — keeps
	# the carve-out matched to the slab so they meet exactly at the same
	# depth on every LOD.
	var amount : float = minf(0.5 * voxel, 1.5)
	var eps := voxel * 0.01
	var min_x := origin.x
	var max_x := origin.x + size
	var min_y := origin.y
	var max_y := origin.y + size
	var min_z := origin.z
	var max_z := origin.z + size
	for vi in positions.size():
		var p := positions[vi]
		var shifted := false
		if (coarser_mask & 1) != 0 and absf(p.x - min_x) < eps:
			p.x += amount
			shifted = true
		if (coarser_mask & 2) != 0 and absf(p.x - max_x) < eps:
			p.x -= amount
			shifted = true
		if (coarser_mask & 4) != 0 and absf(p.y - min_y) < eps:
			p.y += amount
			shifted = true
		if (coarser_mask & 8) != 0 and absf(p.y - max_y) < eps:
			p.y -= amount
			shifted = true
		if (coarser_mask & 16) != 0 and absf(p.z - min_z) < eps:
			p.z += amount
			shifted = true
		if (coarser_mask & 32) != 0 and absf(p.z - max_z) < eps:
			p.z -= amount
			shifted = true
		if shifted:
			positions[vi] = p


# Array index into the density grid `d` for a sample on the given boundary
# face at chunk-corner coords (ci_u, ci_v).
static func _face_sample_index(
		axis: int, u_axis: int, v_axis: int, fixed_chunk: int,
		ci_u: int, ci_v: int, gs: int, gs2: int) -> int:
	var arr := [0, 0, 0]
	arr[axis] = fixed_chunk + 1     # +1 for halo
	arr[u_axis] = ci_u + 1
	arr[v_axis] = ci_v + 1
	return arr[0] + arr[1] * gs + arr[2] * gs2


# World-space position of a transition-cell corner that lies on the boundary
# face, given its chunk-corner coords along the two tangent axes.
static func _corner_world_pos(
		axis: int, u_axis: int, v_axis: int, fixed_chunk: int,
		ci_u: int, ci_v: int, voxel: float, origin: Vector3) -> Vector3:
	var c := [0, 0, 0]
	c[axis] = fixed_chunk
	c[u_axis] = ci_u
	c[v_axis] = ci_v
	return origin + Vector3(c[0], c[1], c[2]) * voxel


# Per-corner gradient lookup on the corner grid (the (R+1)^3 grid the
# regular mesher already precomputed). Returns the raw ∇d vector — the
# final normal-finalisation pass at the end of `build()` negates it and
# flips it to outward radial if needed.
static func _corner_gradient(
		axis: int, u_axis: int, v_axis: int, fixed_chunk: int,
		ci_u: int, ci_v: int,
		grad_x: PackedFloat32Array, grad_y: PackedFloat32Array, grad_z: PackedFloat32Array,
		cs: int, cs2: int) -> Vector3:
	var c := [0, 0, 0]
	c[axis] = fixed_chunk
	c[u_axis] = ci_u
	c[v_axis] = ci_v
	var idx : int = c[0] + c[1] * cs + c[2] * cs2
	return Vector3(grad_x[idx], grad_y[idx], grad_z[idx])


# Compute the gradient of the density field at a world-space point using
# central differences at the COARSER neighbour's voxel spacing (`h`, which
# is 2 × the fine voxel for a standard 2:1 LOD transition). The result
# matches what the coarse chunk's regular MC computes for the same corner,
# so transition-cell low-res vertices and coarse-side boundary vertices
# share both their position and their shading normal.
static func _coarse_resolution_gradient(
		p: Vector3, density: Variant, h: float) -> Vector3:
	var dx : float = density.sample(p + Vector3(h, 0.0, 0.0)) \
			- density.sample(p - Vector3(h, 0.0, 0.0))
	var dy : float = density.sample(p + Vector3(0.0, h, 0.0)) \
			- density.sample(p - Vector3(0.0, h, 0.0))
	var dz : float = density.sample(p + Vector3(0.0, 0.0, h)) \
			- density.sample(p - Vector3(0.0, 0.0, h))
	return Vector3(dx, dy, dz)


# ────────────────────────────────────────────────────────────────────────────
# LOD safety skirts. Emits a thin downward-extruded strip of triangles
# beneath every iso-surface crossing on a coarser-mask boundary face.
# Where the transition cells perfectly stitch the surfaces (the normal
# 1:1 / 2:1 case after the Lengyel and gradient-matching fixes), the skirt
# sits flush below the regular mesh and is invisible from outside the
# planet. Where geometry gaps exist — 2-LOD violations the balance pass
# didn't catch, or the L-junctions where two transition slabs meet at a
# chunk edge — the skirt fills the visible "daylight through the surface"
# with terrain-shaded geometry that drops a small distance inward.
#
# The strip is double-sided (CCW + CW pair per quad). It costs ~4 extra
# triangles per boundary-face iso-crossing; for chunks with one or two
# coarser-mask faces that's a few dozen triangles at most.
#
# Drop depth: clamped to about twice the slab depth (≤ 3 m absolute). Big
# enough to cover the slab's worst-case 2-LOD-shaped mismatch; small enough
# to disappear behind the rest of the mesh at typical viewing angles.
static func _append_lod_safety_skirts(
		positions: PackedVector3Array, normals: PackedVector3Array,
		indices: PackedInt32Array,
		d: PackedFloat32Array, gs: int, gs2: int, resolution: int,
		base: Vector3, voxel: float, planet_center: Vector3,
		coarser_mask: int) -> void:
	var slab_depth : float = minf(0.5 * voxel, 1.5)
	var drop : float = maxf(slab_depth * 2.0, 2.0)
	# face_bit → [fixed_axis, fixed_val_on_chunk_corner_grid]
	var faces : Array = [
		[0, 0],            # bit 0 → -X
		[0, resolution],   # bit 1 → +X
		[1, 0],            # bit 2 → -Y
		[1, resolution],   # bit 3 → +Y
		[2, 0],            # bit 4 → -Z
		[2, resolution],   # bit 5 → +Z
	]
	for face_bit in 6:
		if (coarser_mask & (1 << face_bit)) == 0:
			continue
		var fixed_axis : int = faces[face_bit][0]
		var fixed_val  : int = faces[face_bit][1]
		var u_axis := (fixed_axis + 1) % 3
		var v_axis := (fixed_axis + 2) % 3
		for u in resolution:
			for v in resolution:
				# Sample the 4 face-cell corners.
				var c00 := Vector3i.ZERO
				var c10 := Vector3i.ZERO
				var c01 := Vector3i.ZERO
				var c11 := Vector3i.ZERO
				c00[fixed_axis] = fixed_val; c00[u_axis] = u;     c00[v_axis] = v
				c10[fixed_axis] = fixed_val; c10[u_axis] = u + 1; c10[v_axis] = v
				c01[fixed_axis] = fixed_val; c01[u_axis] = u;     c01[v_axis] = v + 1
				c11[fixed_axis] = fixed_val; c11[u_axis] = u + 1; c11[v_axis] = v + 1
				var corners := [c00, c10, c01, c11]
				var dq := PackedFloat32Array(); dq.resize(4)
				for ci in 4:
					var c : Vector3i = corners[ci]
					dq[ci] = d[(c.x + 1) + (c.y + 1) * gs + (c.z + 1) * gs2]
				var fcase := 0
				for ci in 4:
					if dq[ci] > 0.0:
						fcase |= 1 << ci
				if fcase == 0 or fcase == 15:
					continue
				# Detect iso-surface crossings along the 4 face edges.
				var face_edges := [[0, 1], [1, 3], [3, 2], [2, 0]]
				var crossings : Array[Vector3] = []
				for ei in 4:
					var a : int = face_edges[ei][0]
					var b : int = face_edges[ei][1]
					if signf(dq[a]) == signf(dq[b]):
						continue
					var denom := dq[a] - dq[b]
					var t : float = 0.5 if absf(denom) < 1e-8 else dq[a] / denom
					t = clampf(t, 0.0, 1.0)
					var ca : Vector3i = corners[a]
					var cb : Vector3i = corners[b]
					var pa := base + Vector3(ca.x + 1, ca.y + 1, ca.z + 1) * voxel
					var pb := base + Vector3(cb.x + 1, cb.y + 1, cb.z + 1) * voxel
					crossings.append(pa.lerp(pb, t))
				if crossings.size() < 2:
					continue
				# Emit one skirt quad per crossing pair (cases with 4 crossings
				# get two skirt strips). The strip drops radially toward planet
				# centre, double-sided so it seals from either side.
				var n_pairs : int = crossings.size() >> 1
				for pi in n_pairs:
					var p0 : Vector3 = crossings[pi * 2 + 0]
					var p1 : Vector3 = crossings[pi * 2 + 1]
					var drop0 : Vector3 = (planet_center - p0).normalized() * drop
					var drop1 : Vector3 = (planet_center - p1).normalized() * drop
					var p0d : Vector3 = p0 + drop0
					var p1d : Vector3 = p1 + drop1
					var mid : Vector3 = (p0 + p1) * 0.5
					var n_out : Vector3 = (mid - planet_center).normalized()
					var base_idx := positions.size()
					positions.append(p0)
					positions.append(p1)
					positions.append(p1d)
					positions.append(p0d)
					normals.append(n_out)
					normals.append(n_out)
					normals.append(n_out)
					normals.append(n_out)
					# CCW pair (front from outside).
					indices.append(base_idx + 0)
					indices.append(base_idx + 1)
					indices.append(base_idx + 2)
					indices.append(base_idx + 0)
					indices.append(base_idx + 2)
					indices.append(base_idx + 3)
					# CW pair (front from inside) — keeps the skirt visible
					# when the crack opens toward the planet's interior side.
					indices.append(base_idx + 0)
					indices.append(base_idx + 2)
					indices.append(base_idx + 1)
					indices.append(base_idx + 0)
					indices.append(base_idx + 3)
					indices.append(base_idx + 2)
