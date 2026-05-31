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

signal stats_changed(active_chunks: int, pending_chunks: int, total_tris: int, lod_violations: int)

@export var planet_radius : float = 4000.0
@export var world_seed    : int   = 1337
@export var base_chunk_size : float = 32.0       # smallest chunk side (LOD 0), world units
@export var max_lod       : int   = 7            # 0 = finest, max_lod = root depth
@export var voxel_resolution : int = 16          # cells per axis per chunk
@export var lod_factor    : float = 2.4          # subdivide when cam_dist < lod_factor * node_size
@export var collision_lod_max : int = 1          # build collision for chunks at this LOD or below
@export var scatter_lod_max : int = 1            # scatter props (rocks) on chunks at this LOD or below
@export var sea_level_offset : float = -12.0     # passed to scatter so it skips submerged triangles
@export var max_new_chunks_per_tick  : int = 96   # raised: with thousands of chunks pending, 16/tick takes ~10 s to drain — far longer than the atomic-swap hold window, so cracks appear; pushing throughput keeps the visible frontier ahead of the camera
@export var max_remesh_per_tick      : int = 128  # neighbour-mask re-meshes; prioritised so the atomic-swap gate releases fast
@export var max_free_chunks_per_tick : int = 64
@export var stale_tolerance : int = 90           # frames a chunk can be unvisited before free — wider window so the atomic-swap gate (parent meshed + fine neighbours re-meshed for new transition mask) ALWAYS completes before the old chunk is freed; was 30 (~0.5 s), too short under load
@export var terrain_material : Material

# View-cone culling. The far hemisphere is already dropped by _node_beyond_horizon
# and Godot frustum-culls off-screen DRAWING for free — but chunks behind/beside
# the camera are still GENERATED, meshed and walked every octree pass (CPU + RAM,
# not GPU). This skips generating nodes outside the camera's view cone so only the
# direction you're looking at is streamed. A near bubble around the camera is
# always kept (collision + instant turn-around), and the cone is widened by a
# margin so the boundary stays off-screen; fast spins may still pop. Toggle off if
# it ever culls something it shouldn't.
@export var view_cull_enabled    : bool  = true
@export var view_cull_margin_deg : float = 14.0   # extra half-angle past the frustum corner so the cull edge sits off-screen
@export var view_cull_keep_factor: float = 3.0    # near-bubble radius = this × the coarsest collision-chunk size

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

var _chunks        : Dictionary = {}   # key (packed int, see _key) → ChunkRecord
var _pending_load  : Array      = []   # keys queued for their FIRST mesh
var _pending_remesh: Array      = []   # keys queued to re-mesh after a neighbour-LOD mask change
var _generation   : int        = 0
var _camera       : Camera3D
var _total_tris   : int        = 0
# Re-traversal gating: the LOD octree only changes when the camera moves, so we
# skip the (expensive) traverse + 26-neighbour balance walk while it's roughly
# stationary. `_retraverse_threshold` is set in _ready to ~half a finest voxel.
var _last_cam_local      : Vector3 = Vector3(1e20, 1e20, 1e20)
var _retraverse_threshold: float   = 2.0
# View-cone cull state, recomputed each traversal (all in the planet's LOCAL
# frame, to match the octree). Rotation also triggers a retraverse — without it,
# spinning in place (no position change) would never re-stream the new view.
var _cam_forward_local      : Vector3 = Vector3(0, 0, 1)
var _last_cam_forward_local : Vector3 = Vector3(0, 0, 1)
var _cull_half_angle        : float   = 1.2   # frustum-corner half-angle (rad)
var _cull_keep_radius       : float   = 0.0   # near bubble always kept
# The 2:1-violation HUD stat is O(chunks·faces·depth); compute it occasionally,
# not every frame.
var _violation_frame     : int     = 0
var _cached_violations   : int     = 0
# Native (Rust) Transvoxel mesher, shared by every chunk. Null if the
# GDExtension didn't load (then no meshing happens — see the startup log).
var _native       : Object

class ChunkRecord:
	var chunk      : VoxelChunk
	var lod        : int
	var coords     : Vector3i
	var size       : float
	var origin     : Vector3
	var last_seen  : int = 0
	var has_mesh   : bool = false
	var tri_count  : int = 0
	var transition_mask : int = 0   # per-face bitmask of "neighbour is FINER" (transition side)


func _ready() -> void:
	# Create the native mesher first: the default DensityField delegates its
	# sampling to it (single source of truth with the mesh — see density.gd).
	if ClassDB.class_exists("NativeTerrain"):
		_native = ClassDB.instantiate("NativeTerrain")
	else:
		push_error("NativeTerrain GDExtension not loaded — no terrain will mesh.")
	# Default density is the Earth-like field. world.gd injects a different
	# one (e.g. CraterDensity for the moon) via `set_density()` BEFORE
	# add_child(planet) — in that case we skip the auto-init.
	if density == null:
		density = DensityField.new(planet_radius, world_seed, _native)
	planet_center = Vector3.ZERO   # planet's own local origin
	if terrain_material == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.45, 0.4, 0.32)
		terrain_material = m
	_scatter_mesh     = TerrainScatter.make_rock_mesh()
	_scatter_material = TerrainScatter.make_rock_material()
	_retraverse_threshold = base_chunk_size / float(voxel_resolution) * 0.5
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
	_update_view_cone()
	# Re-decide the LOD octree (the costly traverse + inline balance walk) when
	# the camera has moved OR the octree hasn't settled yet. "Unsettled" = work
	# still queued: the materialised-state balance net (_face_neighbor_has_finer_chunk)
	# resolves a 2:1 cascade one ring per traversal and feeds the new chunks into
	# _pending_load, so as long as a queue is non-empty we must keep traversing to
	# let the cascade finish — otherwise it would freeze the moment the camera
	# stops, stranding a ring of violations. Once everything is balanced and meshed
	# the queues drain, this falls back to the camera-moved gate, and hovering
	# costs nothing again (the framerate win).
	var camera_moved := cam_local.distance_to(_last_cam_local) > _retraverse_threshold
	# Pure rotation moves no chunks but changes which side of the planet is in the
	# view cone, so it must also re-stream. ~2° hysteresis avoids per-frame churn.
	var camera_rotated := view_cull_enabled \
			and _cam_forward_local.dot(_last_cam_forward_local) < 0.99939
	var octree_unsettled := not _pending_load.is_empty() or not _pending_remesh.is_empty()
	if camera_moved or camera_rotated or octree_unsettled:
		_last_cam_local = cam_local
		_last_cam_forward_local = _cam_forward_local
		_traverse_root(cam_local)
		_collect_stale_chunks()
		# Balance is enforced INLINE during traversal; no post-pass (it punched
		# holes by freeing coarse chunks before their finer replacements built).
		#
		# Neighbour masks only depend on which chunk RECORDS exist (see
		# _compute_coarser_mask — it tests _chunks.has(), not has_mesh), and the
		# chunk set only changes here (traverse creates, collect_stale frees).
		# So when the camera hasn't moved past the threshold the masks are
		# provably unchanged, and re-walking every chunk × 6 faces × depth each
		# idle frame was pure wasted main-thread work — the "low FPS while the
		# CPU is barely busy" smell. Run it only when the set actually changed.
		_update_neighbor_masks()
	else:
		for rec in _chunks.values():
			(rec as ChunkRecord).last_seen = _generation
	_drain_pending_load()
	_poll_native()
	_update_scatter_material_uniforms()
	# 2:1-violation stat is expensive — refresh it ~twice a second, not per frame.
	_violation_frame += 1
	if _violation_frame >= 30:
		_violation_frame = 0
		_cached_violations = _count_balance_violations()
	stats_changed.emit(_chunks.size(), _pending_load.size() + _pending_remesh.size(),
			_total_tris, _cached_violations)


# Push planet-world transform into the rock material so its biome math runs
# in the planet's local frame (rotation-invariant under spin, position-correct
# under orbit). planet_radius + polar_axis are static and set in `set_scatter_axis()`.
func _update_scatter_material_uniforms() -> void:
	if _scatter_material == null or not (_scatter_material is ShaderMaterial):
		return
	var sm := _scatter_material as ShaderMaterial
	sm.set_shader_parameter("planet_center", global_position)
	sm.set_shader_parameter("planet_basis_inv", global_transform.basis.inverse())


## Called by world.gd after the planet is constructed — sets the static
## uniforms on the rock material (polar axis in object space, base radius).
func set_scatter_axis(polar_axis_object: Vector3) -> void:
	if _scatter_material != null and _scatter_material is ShaderMaterial:
		var sm := _scatter_material as ShaderMaterial
		sm.set_shader_parameter("polar_axis", polar_axis_object.normalized())
		sm.set_shader_parameter("planet_radius", planet_radius)


# Collect finished meshes from the native thread pool and route each back to
# its chunk by instance id. take_all_ready drains the WHOLE map every frame
# (even results for freed chunks — instance_from_id returns null for those and
# we just skip them), so the native result map can't leak.
func _poll_native() -> void:
	if _native == null:
		return
	# One batched drain: a single lock + single FFI hop for all finished chunks,
	# each entry carrying its own "id".
	var batch : Array = _native.call("take_all_ready")
	for res in batch:
		var obj := instance_from_id(int(res["id"]))
		if obj != null and obj is VoxelChunk:
			(obj as VoxelChunk).apply_native_result(res)


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
				var root_center := origin + Vector3(root_size, root_size, root_size) * 0.5
				if _node_beyond_horizon(root_center, root_size, cam_pos):
					continue
				if _node_outside_view_cone(origin, root_size, root_center, cam_pos):
					continue
				_visit_node(max_lod, Vector3i(ix, iy, iz), origin, root_size, cam_pos)


func _visit_node(lod: int, coords: Vector3i, origin: Vector3, size: float, cam_pos: Vector3) -> void:
	var center := origin + Vector3(size, size, size) * 0.5
	# Drop the whole subtree if it's behind the planet's horizon or outside the
	# camera's view cone.
	if _node_beyond_horizon(center, size, cam_pos):
		return
	if _node_outside_view_cone(origin, size, center, cam_pos):
		return
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
		# Two complementary balance tests, OR'd:
		#  1. Position estimate — predicts a finer neighbour from camera distance.
		#     Cheap and forward-looking, but OPEN-LOOP: it can't see a neighbour
		#     that is finer only because BALANCE forced it (a transitive cascade),
		#     so on its own it leaves a persistent ring of 2:1 violations.
		#  2. Materialised-state test — looks at the chunks that ACTUALLY exist and
		#     splits us if a real chunk two LODs finer already borders our face,
		#     regardless of why it's finer. This closes the loop: the cascade
		#     propagates one ring per frame and settles, driving the violation
		#     count to zero. Monotone (only ever adds subdivisions), so the
		#     atomic-swap free gate still prevents holes.
		if _balance_requires_subdivide(lod, center, size, cam_pos) \
				or _face_neighbor_has_finer_chunk(lod, coords):
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


# Returns true if any of the 26 neighbours (6 faces + 12 edges + 8 corners) of
# a chunk at `lod` would be a leaf at LOD ≤ lod - 2 (a 2:1 violation). This is
# the FULL octree restriction, not just face restriction: the radial LOD
# frontier cuts diagonally across the cubic chunk grid, so the worst seams are
# at cells that meet only along an edge or corner — a face-only check leaves
# those free to differ by 2+ LODs. We don't inspect `_chunks` (traversal may
# not have visited the adjacent subtree yet); instead we replicate the octree's
# subdivision decision at the neighbour POSITION. Returning true cascades — each
# lod-1 child runs the same check, so a cell next to a finer region steps down
# until balanced.
#
# Per neighbour we test the point of its cell nearest the camera. Leaf-LOD is
# monotonic in camera distance (closer = finer), so that single point carries
# the finest leaf-LOD in the neighbour and is the exact binding 2:1 constraint.
func _balance_requires_subdivide(
		lod: int, center: Vector3, size: float, cam_pos: Vector3) -> bool:
	var half := size * 0.5
	var threshold_floor := lod - 2
	var nudge := size * 0.01
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var d := Vector3i(dx, dy, dz)
				# Skip neighbours holding no terrain — nothing there to mismatch,
				# and forcing a split would just burn chunks toward empty space.
				var nbr_center := center + Vector3(dx, dy, dz) * size
				if not _aabb_intersects_planet(nbr_center - Vector3(half, half, half), size):
					continue
				# Closest point of the neighbour cell to the camera: on each axis
				# the cell shares (d==0) we clamp the camera coord to our extent;
				# on each axis it's offset (d!=0) we sit just past that boundary.
				var p := Vector3.ZERO
				for axis in 3:
					var dd : int = d[axis]
					if dd != 0:
						p[axis] = center[axis] + float(dd) * (half + nudge)
					else:
						p[axis] = clampf(cam_pos[axis], center[axis] - half, center[axis] + half)
				if _leaf_lod_at_position(p, cam_pos) <= threshold_floor:
					return true
	return false


# Materialised-state balance net. Returns true if a real chunk TWO LODs finer
# already exists face-adjacent to the cell at (lod, coords) — a live 2:1
# violation that the distance-based predicate missed (because the neighbour was
# itself balance-forced finer, not distance-forced). Splitting us to lod-1 makes
# the boundary a single step again; the freed coarse parent is held by the
# atomic-swap gate until our children mesh, so no hole opens.
#
# We check the lod-2 cells that tile each of our 6 faces (a 4×4 grid per face).
# Only faces are tested — that's exactly what the HUD violation stat counts, and
# edge/corner cases are already covered by the 26-neighbour position predicate.
func _face_neighbor_has_finer_chunk(lod: int, coords: Vector3i) -> bool:
	if lod < 2:
		return false
	# Any adjacent leaf at lod <= lod-2 is a 2:1 violation. We sample the centre of
	# each lod-2 cell tiling our 6 faces and ask what leaf ACTUALLY covers it (at
	# any depth). Because subdivision is all-or-nothing, a lod-2 cell that is split
	# has its centre inside a finer leaf, so centre-sampling detects violations of
	# arbitrary depth — not just exactly lod-2 (the bug that left ~30 deep jumps).
	var threshold := lod - 2
	var size_lod2 : float = base_chunk_size * pow(2.0, float(threshold))
	var faces := [
		Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
		Vector3i(0, -1, 0), Vector3i(0, 1, 0),
		Vector3i(0, 0, -1), Vector3i(0, 0, 1),
	]
	for dir : Vector3i in faces:
		# Neighbour cell at our LOD, expressed in lod-2 cell coords (4× finer).
		var ncoords := coords + dir
		var base := ncoords * 4
		var axis := 0 if dir.x != 0 else (1 if dir.y != 0 else 2)
		# The lod-2 layer of the neighbour that actually touches our shared face:
		# its low side when the neighbour is on our +axis, its high side on -axis.
		var near : int = 0 if dir[axis] > 0 else 3
		var u := (axis + 1) % 3
		var v := (axis + 2) % 3
		for du in 4:
			for dv in 4:
				var c := base
				c[axis] = base[axis] + near
				c[u] = base[u] + du
				c[v] = base[v] + dv
				var center := (Vector3(c) + Vector3.ONE * 0.5) * size_lod2
				if _has_leaf_at_or_below(center, threshold):
					return true
	return false


# True if an existing leaf chunk covers world point `p` at some lod <= max_lod_inc.
# `_chunks` holds leaves only, so we probe finest-first and stop at the first hit
# (that's the unique leaf containing `p`); coarser-than-threshold leaves return
# false. Bounded to threshold+1 lookups.
func _has_leaf_at_or_below(p: Vector3, max_lod_inc: int) -> bool:
	for l in range(0, max_lod_inc + 1):
		var sz : float = base_chunk_size * pow(2.0, float(l))
		var cc := Vector3i(floori(p.x / sz), floori(p.y / sz), floori(p.z / sz))
		if _chunks.has(_key(l, cc)):
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
	# Native mesher + the seed it rebuilds the density from.
	rec.chunk.native = _native
	rec.chunk.world_seed = world_seed
	# Capture rec via the closure so we can keep the running triangle total. The
	# chunk already knows its own tri_count at apply time, so we just read it
	# (no expensive surface_get_arrays() mesh readback). Subtract the previous
	# count before adding the new one so a re-mesh (mask change) doesn't drift
	# the total upward.
	rec.chunk.mesh_ready.connect(func(c: VoxelChunk) -> void:
		rec.has_mesh = true
		_total_tris -= rec.tri_count
		rec.tri_count = c.tri_count
		_total_tris += rec.tri_count)
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
		# ATOMIC LOD swap: only free a stale chunk once its replacement is BOTH
		# meshed AND consistent with its neighbours. For coarsening that means
		# the parent is meshed *and* the parent's finer neighbours have re-meshed
		# to include their transition toward it — otherwise we'd briefly show the
		# coarse parent next to a still-fine neighbour with no transition (the
		# transient crack). Holding the old fine chunk until then keeps the
		# boundary consistent through the swap.
		var has_replacement := _coarsening_ready(rec) or _has_ready_children(rec)
		var force_free := age > stale_tolerance * 8
		if not has_replacement and not force_free:
			continue
		_total_tris -= rec.tri_count
		if rec.chunk:
			rec.chunk.release()
		_chunks.erase(key)
		freed += 1


# Atomic-swap gate for coarsening: the parent is meshed AND every finer chunk
# bordering the parent has re-meshed to include its transition toward the
# parent. Until then, freeing `rec` would expose the coarse parent next to a
# fine neighbour with a stale (no-transition) boundary — the transient crack.
func _coarsening_ready(rec: ChunkRecord) -> bool:
	if rec.lod >= max_lod:
		return false
	var p_coords := Vector3i(rec.coords.x >> 1, rec.coords.y >> 1, rec.coords.z >> 1)
	var parent : ChunkRecord = _chunks.get(_key(rec.lod + 1, p_coords))
	if parent == null or not parent.has_mesh:
		return false
	if parent.lod == 0:
		return true
	var fine_lod := parent.lod - 1
	var faces := [
		[Vector3i(-1, 0, 0), 0, -1], [Vector3i(1, 0, 0), 0, 1],
		[Vector3i(0, -1, 0), 1, -1], [Vector3i(0, 1, 0), 1, 1],
		[Vector3i(0, 0, -1), 2, -1], [Vector3i(0, 0, 1), 2, 1],
	]
	for f in faces:
		var delta : Vector3i = f[0]
		var axis  : int      = f[1]
		var sgn   : int      = f[2]
		var nbr := parent.coords + delta
		# The 2×2 finer children of the neighbour cell that touch the parent's
		# shared face. If any exists and is mid-re-mesh, hold off freeing.
		var base := nbr * 2
		var near : int = 0 if sgn > 0 else 1
		var u := (axis + 1) % 3
		var v := (axis + 2) % 3
		for du in 2:
			for dv in 2:
				var child := base
				child[axis] = base[axis] + near
				child[u] = base[u] + du
				child[v] = base[v] + dv
				var c : ChunkRecord = _chunks.get(_key(fine_lod, child))
				if c != null and c.chunk != null and c.chunk.is_dirty():
					return false
	return true


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


# Diagnostic: count face-adjacent chunk pairs whose LOD differs by ≥ 2 (a
# broken 2:1 restriction). Transvoxel transition cells can only stitch a 1-LOD
# step, so any nonzero count here is a real source of boundary gaps. This is
# computed AFTER the balance passes, so it reflects the final structural state
# each frame — if it reads 0 but seams still show, the seams are in the
# transition-cell mesh itself, not the LOD layout; if it reads > 0, the balance
# is genuinely failing. Surfaced on the HUD so we can tell which is which.
func _count_balance_violations() -> int:
	var count := 0
	for key in _chunks.keys():
		var rec : ChunkRecord = _chunks[key]
		for face_bit in 6:
			var nbr := _coarsest_face_neighbour(rec, face_bit)
			if nbr == null:
				continue
			if absi(nbr.lod - rec.lod) >= 2:
				count += 1
	return count


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


# Walk every active leaf and compute its 6-bit transition mask. Queue a re-mesh
# whenever the mask differs from the one the chunk was last built with — that
# keeps the boundary watertight as the LOD frontier shifts. Throttled via the
# low-priority `_pending_remesh` queue.
func _update_neighbor_masks() -> void:
	for key in _chunks.keys():
		var rec : ChunkRecord = _chunks[key]
		if not rec.has_mesh:
			# Set directly so the first request_build snapshots the right value.
			rec.transition_mask = _compute_coarser_mask(rec.lod, rec.coords)
			if rec.chunk:
				rec.chunk.transition_mask = rec.transition_mask
			continue
		var new_mask := _compute_coarser_mask(rec.lod, rec.coords)
		if rec.chunk and rec.chunk.set_transition_mask(new_mask):
			rec.transition_mask = new_mask
			# Deferred low-priority re-queue: lets a burst of transient mask
			# flips (neighbours streaming in) collapse into one re-mesh.
			if not _pending_remesh.has(key):
				_pending_remesh.append(key)


# For chunk at (lod, coords), find faces whose neighbour is COARSER — the side
# on which THIS finer block emits Transvoxel transition cells (the convention
# the hand-rolled mesher in mesher.rs uses). A face is coarser-bordering when
# its same-LOD neighbour cell is absent but an ANCESTOR (parent, grandparent…)
# of that cell is an active chunk. Returns a 6-bit mask:
#   bit 0 -X, 1 +X, 2 -Y, 3 +Y, 4 -Z, 5 +Z.
func _compute_coarser_mask(lod: int, coords: Vector3i) -> int:
	if lod >= max_lod:
		return 0
	var mask := 0
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
		# Same-LOD neighbour present? Then no transition on this face.
		if _chunks.has(_key(lod, nbr_coords)):
			continue
		# Walk the ancestor chain until we find an active chunk covering the
		# neighbour cell; if found, that neighbour is coarser → transition.
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
	# Re-meshes FIRST. A re-mesh is a boundary that has a transition mismatch
	# RIGHT NOW (a coarsening neighbour) — submitting it promptly releases the
	# atomic-swap gate quickly, so the old fine chunks aren't held long and the
	# transient window stays tiny. Meshing is off-thread, so this just queues to
	# the worker pool; getting the seam-fixers in first is what matters.
	var remeshed := 0
	while remeshed < max_remesh_per_tick and not _pending_remesh.is_empty():
		var rkey : int = _pending_remesh.pop_front()
		if not _chunks.has(rkey):
			continue
		var rrec : ChunkRecord = _chunks[rkey]
		if (_generation - rrec.last_seen) > stale_tolerance:
			continue
		rrec.chunk.request_build()
		remeshed += 1
	# Then initial meshes for newly-revealed chunks.
	var dispatched := 0
	while dispatched < max_new_chunks_per_tick and not _pending_load.is_empty():
		var key : int = _pending_load.pop_front()
		if not _chunks.has(key):
			continue
		var rec : ChunkRecord = _chunks[key]
		if (_generation - rec.last_seen) > stale_tolerance:
			continue
		rec.chunk.request_build()
		dispatched += 1


# Pack (lod, coords) into a single 64-bit int key for the _chunks dictionary.
# Int keys hash far faster than the old "%d_%d_%d_%d" strings — and the hot path
# (traversal + the balance net's _has_leaf_at_or_below) does a great many lookups
# per frame. Layout: lod in bits 48-51, then x/y/z in 16-bit signed fields. 16
# bits gives a ±32768 coord range per axis — at LOD 0 the finest coords reach
# ±base_chunk_size·2^max_lod / base_chunk_size = ±2^max_lod, so this holds for
# max_lod up to 15 (we run 9). Nothing ever decodes the key, so the packing only
# needs to be collision-free, which it is within that range.
func _key(lod: int, coords: Vector3i) -> int:
	return (lod << 48) \
		| ((coords.x & 0xFFFF) << 32) \
		| ((coords.y & 0xFFFF) << 16) \
		| (coords.z & 0xFFFF)


# Recompute the camera view cone (local frame) + the near-keep bubble. Cheap;
# called once per frame before traversal.
func _update_view_cone() -> void:
	if _camera == null:
		return
	# Godot cameras look down -Z. Bring forward into the planet's LOCAL frame so
	# it compares directly against node centres (which are local).
	var fwd_world := -_camera.global_transform.basis.z
	_cam_forward_local = (global_transform.basis.inverse() * fwd_world).normalized()
	# Half-angle to the frustum CORNER, from vertical FOV + viewport aspect, so the
	# cone fully encloses the rectangular frustum and never culls an on-screen node.
	var tan_v := tan(deg_to_rad(_camera.fov) * 0.5)
	var aspect := 1.7777778
	var vp := get_viewport()
	if vp != null:
		var vs := vp.get_visible_rect().size
		if vs.y > 0.0:
			aspect = vs.x / vs.y
	var tan_h := tan_v * aspect
	_cull_half_angle = atan(sqrt(tan_v * tan_v + tan_h * tan_h))
	_cull_keep_radius = base_chunk_size * pow(2.0, float(collision_lod_max + 1)) * view_cull_keep_factor


# View-cone culling. Skips generating a node whose bounding sphere lies entirely
# outside the camera's (margin-widened) view cone — UNLESS it overlaps the near
# bubble, which is always kept so collision under the player and instant
# turn-around survive. Complements the horizon cull (which drops the far side);
# together they keep only the chunks you can actually look at.
func _node_outside_view_cone(origin: Vector3, size: float, center: Vector3, cam_pos: Vector3) -> bool:
	if not view_cull_enabled:
		return false
	# Nearest point of the node cube to the camera — keeps any node overlapping
	# the bubble, including huge coarse roots whose centre is far away.
	var nearest := Vector3(
		clampf(cam_pos.x, origin.x, origin.x + size),
		clampf(cam_pos.y, origin.y, origin.y + size),
		clampf(cam_pos.z, origin.z, origin.z + size))
	if cam_pos.distance_to(nearest) <= _cull_keep_radius:
		return false
	var to_node := center - cam_pos
	var dist := to_node.length()
	if dist < 1e-3:
		return false
	var dir := to_node / dist
	var node_bound := size * 0.8660254   # half the cube's space-diagonal
	var node_ang := asin(clampf(node_bound / dist, -1.0, 1.0))
	var ang := acos(clampf(_cam_forward_local.dot(dir), -1.0, 1.0))
	return ang > _cull_half_angle + node_ang + deg_to_rad(view_cull_margin_deg)


# Far-side (horizon) culling. A node is skipped only when its entire bounding
# sphere sits behind the planet's horizon as seen from the camera — i.e. the
# body itself occludes it regardless of where the camera looks. Near the
# surface this removes most of the planet (the whole far hemisphere plus the
# occluded near-horizon band); far-side chunks already built get freed via the
# normal stale path once traversal stops visiting them.
func _node_beyond_horizon(center: Vector3, size: float, cam_pos: Vector3) -> bool:
	var cam_dist := cam_pos.length()
	var center_dist := center.length()
	if cam_dist < 1.0 or center_dist < 1.0:
		return false
	var cam_dir := cam_pos / cam_dist
	var node_dir := center / center_dist
	var ang := acos(clampf(cam_dir.dot(node_dir), -1.0, 1.0))
	# Visible-cap half-angle = the camera-side horizon of the (mean) body, PLUS
	# the extra angular reach of the tallest terrain that can peek over that
	# horizon (so a visible summit is never culled), PLUS the node's own angular
	# radius, PLUS a small safety pad.
	var occ_r : float = planet_radius
	var max_r : float = density.max_surface_radius()
	var cam_horizon : float = (acos(clampf(occ_r / cam_dist, -1.0, 1.0)) if cam_dist > occ_r else 0.0)
	var peak_reach : float = acos(clampf(occ_r / max_r, -1.0, 1.0))
	var node_bound := size * 0.8660254   # half the cube's space-diagonal
	var node_ang := asin(clampf(node_bound / center_dist, -1.0, 1.0))
	return ang > cam_horizon + peak_reach + node_ang + 0.05


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
