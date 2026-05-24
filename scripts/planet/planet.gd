class_name Planet
extends Node3D

## Octree-streamed voxel planet.
##
## Each frame we walk an octree rooted at multiple coarse cells that tile the
## planet's bounding cube. For every node, if the camera is "close enough"
## relative to the node's size (controlled by `lod_factor`), we subdivide;
## otherwise the node is a leaf and owns a VoxelChunk meshed at that level.
##
## Nodes that don't intersect the planet shell [min_surface_radius,
## max_surface_radius] are pruned — most of the bounding cube is empty space.
##
## Generation counting tags each visited record every frame. Records whose
## last-seen generation is stale by more than `stale_tolerance` frames get
## freed; the tolerance lets newly-subdivided child chunks finish meshing
## before their parent disappears, hiding the "hole" pop-through.
##
## Spawn and free are both throttled per-tick so the main thread never stalls.

signal stats_changed(active_chunks: int, pending_chunks: int, total_tris: int)

@export var planet_radius : float = 4000.0
@export var world_seed    : int   = 1337
@export var base_chunk_size : float = 32.0       # smallest chunk side (LOD 0), world units
@export var max_lod       : int   = 7            # 0 = finest, max_lod = root depth
@export var voxel_resolution : int = 16          # cells per axis per chunk
@export var lod_factor    : float = 2.4          # subdivide when cam_dist < lod_factor * node_size
@export var collision_lod_max : int = 1          # build collision for chunks at this LOD or below
@export var scatter_lod_max : int = 1            # scatter props (rocks) on chunks at this LOD or below
@export var sea_level_offset : float = -12.0     # passed to scatter so it skips submerged triangles
@export var max_new_chunks_per_tick  : int = 4
@export var max_free_chunks_per_tick : int = 8
@export var stale_tolerance : int = 30           # frames a chunk can be unvisited before free
@export var terrain_material : Material

# Shared scatter resources — created once, referenced by every chunk's
# MultiMeshInstance3D. Saves N MeshInstances and N materials across N chunks.
var _scatter_mesh     : Mesh
var _scatter_material : Material

# Density field — typed loosely as Variant so we can plug in either
# DensityField (Earth-like) or CraterDensity (Moon-like) without subclassing.
# Anything that exposes `sample(p)`, `max_surface_radius()` and
# `min_surface_radius()` works here.
var density : Variant
# Planet center in the planet's LOCAL frame is always Vector3.ZERO. The
# world-space center moves as the parent PlanetSystem orbits — `planet_center`
# is exposed for shaders that work in world space, but the octree and chunk
# mesher all operate in the planet's local frame.
var planet_center : Vector3 = Vector3.ZERO

var _chunks       : Dictionary = {}   # key (String) → ChunkRecord
var _pending_load : Array      = []   # keys queued to mesh
var _generation   : int        = 0
var _camera       : Camera3D
var _total_tris   : int        = 0

class ChunkRecord:
	var chunk      : VoxelChunk
	var lod        : int
	var coords     : Vector3i
	var size       : float
	var origin     : Vector3
	var last_seen  : int = 0
	var has_mesh   : bool = false
	var tri_count  : int = 0
	var coarser_mask : int = 0   # per-face bitmask of "neighbour is coarser"


func _ready() -> void:
	# Default density is the Earth-like field. world.gd injects a different
	# one (e.g. CraterDensity for the moon) via `set_density()` BEFORE
	# add_child(planet) — in that case we skip the auto-init.
	if density == null:
		density = DensityField.new(planet_radius, world_seed)
	planet_center = Vector3.ZERO   # planet's own local origin
	if terrain_material == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.45, 0.4, 0.32)
		terrain_material = m
	_scatter_mesh     = TerrainScatter.make_rock_mesh()
	_scatter_material = TerrainScatter.make_rock_material()
	_camera = _find_camera()


# Inject an external density object. Must have `sample`, `max_surface_radius`,
# and `min_surface_radius` methods. Call BEFORE add_child(planet).
func set_density(d: Variant) -> void:
	density = d


func set_camera(c: Camera3D) -> void:
	_camera = c


func _find_camera() -> Camera3D:
	var vp := get_viewport()
	if vp == null:
		return null
	return vp.get_camera_3d()


func _process(_dt: float) -> void:
	if _camera == null:
		_camera = _find_camera()
		if _camera == null:
			return
	_generation += 1
	# Convert the camera's world position into this planet's local frame so
	# the octree (which works in the planet's local space) compares apples
	# to apples even when the parent PlanetSystem has orbited or rotated.
	var cam_local := to_local(_camera.global_position)
	_traverse_root(cam_local)
	_collect_stale_chunks()
	# (Balance is now enforced inline inside `_visit_node` via
	# `_balance_requires_subdivide`, so we don't need a separate post-pass
	# here. The old `_enforce_octree_balance` is kept below as a defence-
	# in-depth net but should normally be a no-op now.)
	_enforce_octree_balance()
	_update_neighbor_masks()
	_drain_pending_load()
	stats_changed.emit(_chunks.size(), _pending_load.size(), _total_tris)


func _traverse_root(cam_pos: Vector3) -> void:
	var root_size := base_chunk_size * pow(2.0, float(max_lod))
	var outer : float = density.max_surface_radius()
	var span := ceili(outer / root_size) + 1
	for iz in range(-span, span):
		for iy in range(-span, span):
			for ix in range(-span, span):
				var origin := Vector3(ix, iy, iz) * root_size
				if not _aabb_intersects_planet(origin, root_size):
					continue
				_visit_node(max_lod, Vector3i(ix, iy, iz), origin, root_size, cam_pos)


func _visit_node(lod: int, coords: Vector3i, origin: Vector3, size: float, cam_pos: Vector3) -> void:
	var center := origin + Vector3(size, size, size) * 0.5
	var dist := cam_pos.distance_to(center)
	var subdivide := lod > 0 and dist < size * lod_factor

	# Balance enforcement BAKED INTO traversal. Even if our own distance
	# doesn't justify subdividing, we must subdivide whenever any face-
	# adjacent position would be at a leaf LOD 2 or more levels finer than
	# us — otherwise we leave behind a coarse leaf that the post-traversal
	# balance pass would split, only for traversal to recreate it next
	# frame (oscillation). With the check here, the offending coarse leaf
	# never gets created in the first place. The cascading is implicit:
	# each child we create at lod-1 runs the same check, so balance
	# propagates all the way down to LOD 0 as needed.
	if not subdivide and lod >= 2:
		if _balance_requires_subdivide(lod, center, size, cam_pos):
			subdivide = true

	if subdivide:
		var half := size * 0.5
		for child in 8:
			var dx := child & 1
			var dy := (child >> 1) & 1
			var dz := (child >> 2) & 1
			var child_origin := origin + Vector3(dx, dy, dz) * half
			var child_coords := Vector3i(coords.x * 2 + dx, coords.y * 2 + dy, coords.z * 2 + dz)
			if not _aabb_intersects_planet(child_origin, half):
				continue
			_visit_node(lod - 1, child_coords, child_origin, half, cam_pos)
		return

	# Leaf — touch the record so it stays alive this tick.
	var rec := _ensure_chunk(lod, coords, origin, size)
	rec.last_seen = _generation


# Returns true if any of the 6 face-adjacent positions of a chunk at `lod`
# with the given center/size would be inside a leaf at LOD ≤ lod - 2 (a 2:1
# violation). We don't inspect `_chunks` because traversal might not have
# visited the adjacent subtree yet; instead we replicate the subdivision
# decision an octree walk would make at each face-adjacent POSITION.
# Returning true cascades naturally — children at lod-1 run the same check.
#
# We use TWO sample points per face to catch the realistic worst case:
# the face centre (camera roughly perpendicular to the chunk) and a corner
# of the face (camera at a grazing angle, which is what makes the nearest
# face-adjacent leaf much smaller than the face centre would suggest —
# the original failure mode that produced the "4 nearest chunks 2 LODs
# above their neighbours" report).
func _balance_requires_subdivide(
		lod: int, center: Vector3, size: float, cam_pos: Vector3) -> bool:
	var half := size * 0.5
	# Each entry is [axis, sign]. The 6 entries cover the 6 faces; for each
	# face we test the centre and the four corners (5 points × 6 faces =
	# 30 samples). 30 ancestor walks per chunk per frame is still cheap.
	var face_dirs : Array = [
		[0, -1], [0, 1], [1, -1], [1, 1], [2, -1], [2, 1],
	]
	var threshold_floor := lod - 2
	for fd in face_dirs:
		var axis : int = fd[0]
		var sign_ : int = fd[1]
		# Build a point just beyond the face in the outward direction. We
		# step half-a-voxel past the face plane so the sample lands inside
		# the face-adjacent cell, not on the boundary plane itself.
		var nudge := size * 0.01
		var face_offset := Vector3.ZERO
		face_offset[axis] = float(sign_) * (half + nudge)
		# Centre of the face, plus the 4 corners.
		var u_axis := (axis + 1) % 3
		var v_axis := (axis + 2) % 3
		var samples : Array = []
		samples.append(Vector3.ZERO)             # centre
		samples.append(Vector3.ZERO)
		samples.append(Vector3.ZERO)
		samples.append(Vector3.ZERO)
		samples.append(Vector3.ZERO)
		samples[1][u_axis] = -half; samples[1][v_axis] = -half
		samples[2][u_axis] =  half; samples[2][v_axis] = -half
		samples[3][u_axis] = -half; samples[3][v_axis] =  half
		samples[4][u_axis] =  half; samples[4][v_axis] =  half
		for s in samples:
			var nbr_pos : Vector3 = center + face_offset + s
			if _leaf_lod_at_position(nbr_pos, cam_pos) <= threshold_floor:
				return true
	return false


# Returns the LOD at which the OCTREE CELL containing position `p` would
# be a leaf. Walks the standard subdivision criterion from the root down,
# computing each enclosing cell's centre and asking whether it subdivides.
# This is what the actual chunk at `p` will be after traversal — strictly
# more accurate than asking "what LOD would a chunk CENTRED at p be at",
# because the cell containing `p` is centred on the octree grid, not on
# `p` itself. The old "distance-only" version was wrong by up to ½ size
# in the worst case, which is exactly the regime where 2:1 violations sneak
# through.
func _leaf_lod_at_position(p: Vector3, cam_pos: Vector3) -> int:
	var cur_lod : int = max_lod
	while cur_lod > 0:
		var cur_size : float = base_chunk_size * pow(2.0, float(cur_lod))
		var cell_origin := Vector3(
				floor(p.x / cur_size) * cur_size,
				floor(p.y / cur_size) * cur_size,
				floor(p.z / cur_size) * cur_size)
		var cell_center : Vector3 = cell_origin + Vector3.ONE * (cur_size * 0.5)
		var cell_dist : float = cam_pos.distance_to(cell_center)
		# Standard subdivision criterion: subdivide if dist < size * lod_factor.
		# So leaf if dist ≥ size * lod_factor.
		if cell_dist >= cur_size * lod_factor:
			return cur_lod
		cur_lod -= 1
	return 0


func _ensure_chunk(lod: int, coords: Vector3i, origin: Vector3, size: float) -> ChunkRecord:
	var key := _key(lod, coords)
	if _chunks.has(key):
		return _chunks[key]
	var rec := ChunkRecord.new()
	rec.lod = lod
	rec.coords = coords
	rec.size = size
	rec.origin = origin
	rec.chunk = VoxelChunk.new()
	add_child(rec.chunk)
	rec.chunk.setup(
		origin,
		size,
		lod,
		voxel_resolution,
		density,
		planet_center,
		terrain_material,
		lod <= collision_lod_max)
	rec.chunk.scatter_mesh     = _scatter_mesh
	rec.chunk.scatter_material = _scatter_material
	rec.chunk.scatter_lod_max  = scatter_lod_max
	rec.chunk.planet_radius_for_scatter = planet_radius
	rec.chunk.sea_level_offset_for_scatter = sea_level_offset
	# Capture rec via the closure so we can count triangles when ready.
	rec.chunk.mesh_ready.connect(func(c: VoxelChunk) -> void:
		rec.has_mesh = true
		var mi := _mesh_instance_of(c)
		if mi and mi.mesh:
			var arr := (mi.mesh as ArrayMesh).surface_get_arrays(0)
			if arr.size() > Mesh.ARRAY_INDEX and arr[Mesh.ARRAY_INDEX] != null:
				@warning_ignore("integer_division")
				var tc : int = (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
				rec.tri_count = tc
				_total_tris += tc)
	_pending_load.append(key)
	_chunks[key] = rec
	return rec


func _collect_stale_chunks() -> void:
	var freed := 0
	for key in _chunks.keys():
		if freed >= max_free_chunks_per_tick:
			break
		var rec : ChunkRecord = _chunks[key]
		var age := _generation - rec.last_seen
		if age <= stale_tolerance:
			continue
		# Don't drop a chunk while it's still the only mesh covering its
		# region. That's the "chunks vanish when I move closer" bug: when the
		# camera crosses a subdivide threshold we stop visiting the parent
		# and start visiting the 8 children, but the children take time on
		# the worker pool to mesh. If we free the parent before any child
		# has a mesh, that volume is uncovered → visible hole. Same in
		# reverse when the camera moves away (children stale, parent still
		# meshing). Wait for a viable replacement first; only force-free
		# after a hard cap so a wedged transition can't leak forever.
		var has_replacement := _has_ready_parent(rec) or _has_ready_children(rec)
		var force_free := age > stale_tolerance * 8
		if not has_replacement and not force_free:
			continue
		_total_tris -= rec.tri_count
		if rec.chunk:
			rec.chunk.release()
		_chunks.erase(key)
		freed += 1


# True if the coarser octree parent of `rec` exists and has a finished mesh.
# Used as a "we can free this fine chunk now" check during coarsening.
func _has_ready_parent(rec: ChunkRecord) -> bool:
	if rec.lod >= max_lod:
		return false
	var parent_coords := Vector3i(rec.coords.x >> 1, rec.coords.y >> 1, rec.coords.z >> 1)
	var parent_key := _key(rec.lod + 1, parent_coords)
	if not _chunks.has(parent_key):
		return false
	return (_chunks[parent_key] as ChunkRecord).has_mesh


# True if every finer child of `rec` that the octree needs is meshed. Used as
# a "we can free this coarse chunk now" check during subdivision. Children
# whose AABB doesn't intersect the planet shell never get spawned, so we
# treat them as already-satisfied.
func _has_ready_children(rec: ChunkRecord) -> bool:
	if rec.lod == 0:
		return false
	var fine_lod := rec.lod - 1
	var half := rec.size * 0.5
	for child in 8:
		var dx := child & 1
		var dy := (child >> 1) & 1
		var dz := (child >> 2) & 1
		var child_origin := rec.origin + Vector3(dx, dy, dz) * half
		if not _aabb_intersects_planet(child_origin, half):
			continue
		var child_coords := Vector3i(rec.coords.x * 2 + dx, rec.coords.y * 2 + dy, rec.coords.z * 2 + dz)
		var child_key := _key(fine_lod, child_coords)
		if not _chunks.has(child_key):
			return false
		if not (_chunks[child_key] as ChunkRecord).has_mesh:
			return false
	return true


# Enforce a 2:1 (restricted) octree across the active chunk set. After the
# main traversal a coarse chunk can end up face-adjacent to chunks 2+ LODs
# finer — usually at sharp distance transitions (e.g. the camera grazing the
# planet's horizon). Lengyel's transition cells assume strictly 2:1, so any
# 4:1+ neighbour creates visible gaps. We fix it by finding every coarse
# chunk that has a finer-than-allowed face neighbour and force-subdividing
# it; cascading is handled by looping until a pass finds no violations
# (capped to avoid runaway when the camera moves fast).
func _enforce_octree_balance() -> void:
	var max_passes := 6
	for _pass_idx in max_passes:
		# Collect distinct coarse chunks that violate the 2:1 rule. We walk
		# from each fine chunk's perspective, ask which ancestor of each
		# face-adjacent position is active in the octree, and queue that
		# ancestor for subdivision iff its LOD is ≥ 2 greater than ours.
		var unique_split : Dictionary = {}
		for key in _chunks.keys():
			var rec : ChunkRecord = _chunks[key]
			if rec.lod >= max_lod - 1:
				continue   # no neighbour can be 2+ LODs coarser if we're already near root
			for face_bit in 6:
				var coarse_rec := _coarsest_face_neighbour(rec, face_bit)
				if coarse_rec == null:
					continue
				if coarse_rec.lod >= rec.lod + 2:
					unique_split[_key(coarse_rec.lod, coarse_rec.coords)] = coarse_rec
		if unique_split.is_empty():
			return
		for r in unique_split.values():
			if _chunks.has(_key(r.lod, r.coords)):
				_split_chunk(r)


# Walk up the ancestor chain from `rec`'s face neighbour at the same LOD
# until we find an active chunk in `_chunks`, or run out of levels. Returns
# the active chunk record, or null if no chunk covers that neighbour cell.
# O(max_lod) lookups per call.
func _coarsest_face_neighbour(rec: ChunkRecord, face_bit: int) -> ChunkRecord:
	var delta := Vector3i.ZERO
	match face_bit:
		0: delta = Vector3i(-1, 0, 0)
		1: delta = Vector3i(1, 0, 0)
		2: delta = Vector3i(0, -1, 0)
		3: delta = Vector3i(0, 1, 0)
		4: delta = Vector3i(0, 0, -1)
		5: delta = Vector3i(0, 0, 1)
	# At rec's own LOD, the cell sharing the face is rec.coords + delta.
	var cur_coords := rec.coords + delta
	var cur_lod := rec.lod
	while cur_lod <= max_lod:
		var k := _key(cur_lod, cur_coords)
		if _chunks.has(k):
			return _chunks[k] as ChunkRecord
		# Move up one ancestor level.
		cur_coords = Vector3i(cur_coords.x >> 1, cur_coords.y >> 1, cur_coords.z >> 1)
		cur_lod += 1
	return null


# Replace a single chunk with its 8 children at lod-1, mirroring the leaf-
# creation path in `_visit_node`/`_ensure_chunk`. The children's last_seen
# is stamped with the current generation so the stale-collector doesn't
# immediately reap them again on the next tick.
func _split_chunk(rec: ChunkRecord) -> void:
	var key := _key(rec.lod, rec.coords)
	if not _chunks.has(key):
		return
	_total_tris -= rec.tri_count
	if rec.chunk:
		rec.chunk.release()
	_chunks.erase(key)
	var child_lod := rec.lod - 1
	var child_size := rec.size * 0.5
	for child in 8:
		var dx := child & 1
		var dy := (child >> 1) & 1
		var dz := (child >> 2) & 1
		var child_origin := rec.origin + Vector3(dx, dy, dz) * child_size
		if not _aabb_intersects_planet(child_origin, child_size):
			continue
		var child_coords := Vector3i(
				rec.coords.x * 2 + dx, rec.coords.y * 2 + dy, rec.coords.z * 2 + dz)
		var child_rec := _ensure_chunk(child_lod, child_coords, child_origin, child_size)
		child_rec.last_seen = _generation


# Walk every active leaf and compute its 6-bit "coarser neighbour" mask.
# Queue a re-mesh whenever the mask differs from the one the chunk was last
# built with — that's the trigger for keeping the boundary crack-free as the
# LOD frontier shifts. The re-mesh goes through the normal pending_load queue,
# so it's throttled by `max_new_chunks_per_tick`.
func _update_neighbor_masks() -> void:
	for key in _chunks.keys():
		var rec : ChunkRecord = _chunks[key]
		if not rec.has_mesh:
			# Will pick up the right mask when the initial mesh runs — set it
			# directly so request_build snapshots the correct value.
			rec.coarser_mask = _compute_coarser_mask(rec.lod, rec.coords)
			if rec.chunk:
				rec.chunk.coarser_mask = rec.coarser_mask
			continue
		var new_mask := _compute_coarser_mask(rec.lod, rec.coords)
		if rec.chunk and rec.chunk.set_coarser_mask(new_mask):
			rec.coarser_mask = new_mask
			# Re-queue. request_build is a no-op while a task is still in
			# flight, so we use the pending queue to throttle re-mesh waves.
			if not _pending_load.has(key):
				_pending_load.append(key)


# For chunk at (lod, coords), check each of 6 face directions: is the
# neighbour at the same LOD missing AND its coarser parent present? If so,
# that face has a coarser neighbour. Returns a 6-bit mask:
#   bit 0 -X, 1 +X, 2 -Y, 3 +Y, 4 -Z, 5 +Z.
func _compute_coarser_mask(lod: int, coords: Vector3i) -> int:
	if lod >= max_lod:
		return 0
	var mask := 0
	# 6 face offsets in coord-space (Δix, Δiy, Δiz, bit_index)
	var offsets := [
		[Vector3i(-1, 0, 0), 0],
		[Vector3i( 1, 0, 0), 1],
		[Vector3i(0, -1, 0), 2],
		[Vector3i(0,  1, 0), 3],
		[Vector3i(0, 0, -1), 4],
		[Vector3i(0, 0,  1), 5],
	]
	for off in offsets:
		var delta : Vector3i = off[0]
		var bit   : int      = off[1]
		var nbr_coords := coords + delta
		# Same-LOD neighbour present? Then no transition cells needed on this face.
		if _chunks.has(_key(lod, nbr_coords)):
			continue
		# Walk the ancestor chain (parent, grandparent, …) until we find an
		# active chunk covering the neighbour cell. `_enforce_octree_balance`
		# tries to keep the LOD difference at 1, but during the frames in
		# which it hasn't converged yet (camera moving fast, chunks still
		# meshing) the neighbour can sit 2+ LODs above us. We still want to
		# emit transition cells in that transient — the geometry is only
		# 2:1-shaped so the stitch isn't perfect for a 4:1+ gap, but it's
		# vastly preferable to leaving a hole until balance finishes.
		var anc_coords := Vector3i(nbr_coords.x >> 1, nbr_coords.y >> 1, nbr_coords.z >> 1)
		var anc_lod := lod + 1
		while anc_lod <= max_lod:
			if _chunks.has(_key(anc_lod, anc_coords)):
				mask |= 1 << bit
				break
			anc_coords = Vector3i(anc_coords.x >> 1, anc_coords.y >> 1, anc_coords.z >> 1)
			anc_lod += 1
	return mask


func _drain_pending_load() -> void:
	var n := mini(max_new_chunks_per_tick, _pending_load.size())
	for i in n:
		var key : String = _pending_load.pop_front()
		if not _chunks.has(key):
			continue
		var rec : ChunkRecord = _chunks[key]
		# Skip if went stale before we got to it.
		if (_generation - rec.last_seen) > stale_tolerance:
			continue
		rec.chunk.request_build()


func _key(lod: int, coords: Vector3i) -> String:
	return "%d_%d_%d_%d" % [lod, coords.x, coords.y, coords.z]


func _mesh_instance_of(c: VoxelChunk) -> MeshInstance3D:
	for child in c.get_children():
		if child is MeshInstance3D:
			return child
	return null


func _aabb_intersects_planet(origin: Vector3, size: float) -> bool:
	var center := origin + Vector3(size, size, size) * 0.5
	var cube_radius := size * 0.5 * 1.7320508
	var center_dist := center.distance_to(planet_center)
	var min_r : float = density.min_surface_radius()
	var max_r : float = density.max_surface_radius()
	if center_dist - cube_radius > max_r:
		return false
	if center_dist + cube_radius < min_r:
		return false
	return true


# ─── Helpers exposed for the player controller ──────────────────────────────
# All accept WORLD-space positions and return WORLD-space results, even though
# density sampling itself happens in the planet's local frame.

func altitude_above_surface(world_pos: Vector3) -> float:
	# density ≈ surface_r - |p_local|, so altitude ≈ -density at the local point.
	var d : float = density.sample(to_local(world_pos))
	return -d


func gravity_dir(world_pos: Vector3) -> Vector3:
	var center_world := global_position
	var to_center := center_world - world_pos
	if to_center.length_squared() < 1e-6:
		return Vector3.DOWN
	return to_center.normalized()


# Project a world point straight down to the iso-surface. Newton's method on
# f(r) = density(n_local * r); f drops roughly linearly with r, so step is
# r ← r + f(r). The returned point is in WORLD space.
func surface_point_below(world_pos: Vector3) -> Vector3:
	var p_local := to_local(world_pos)
	var r := p_local.length()
	if r < 1e-3:
		var dr : float = density.radius
		return to_global(Vector3.UP * dr)
	var n := p_local / r
	for _i in 8:
		var d : float = density.sample(n * r)
		r += d
	return to_global(n * r)
