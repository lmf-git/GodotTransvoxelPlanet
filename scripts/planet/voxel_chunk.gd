class_name VoxelChunk
extends Node3D

## A single voxel chunk: density grid → marching-cubes mesh + (optional) collision.
##
## Threading model — important: all meshing happens in the Rust thread pool
## (NativeTerrain). This node never spawns a thread. request_build() submits the
## job by instance id; the Rust worker writes the finished mesh into the native
## result map (it never references this node), and Planet._poll_native drains the
## batch each frame and calls apply_native_result() here, on the main thread. So
## the chunk can be freed at any time without affecting an in-flight job.

signal mesh_ready(chunk: VoxelChunk)

var origin        : Vector3
var size          : float
var lod           : int
var resolution    : int
# Density: duck-typed (either DensityField or CraterDensity).
var density       : Variant
var planet_center : Vector3
var build_collision : bool = false
var material      : Material

# Scatter (rocks). Disabled when scatter_mesh is null or LOD > scatter_lod_max.
var scatter_mesh     : Mesh        # shared rock mesh
var scatter_material : Material    # shared rock material
var scatter_lod_max  : int   = 1
var planet_radius_for_scatter : float = 0.0
var sea_level_offset_for_scatter : float = 0.0

# Transvoxel transition mask. Per the `transvoxel` crate's convention this
# marks faces whose neighbour is FINER (higher-res) — the side on which THIS
# (coarser) block emits a transition face. Bit 0 -X, 1 +X, 2 -Y, 3 +Y, 4 -Z, 5 +Z.
var transition_mask : int = 0
var _last_built_mask : int = -1   # the mask the current mesh was built with

# Native (Rust) mesher + the seed it needs to rebuild the density. Set by the
# planet before the first build. When `native` is null we have no mesher.
var native      : Object
var world_seed  : int = 0

var _mesh_instance : MeshInstance3D
var _static_body   : StaticBody3D
var _coll_shape    : CollisionShape3D
var _scatter_mmi   : MultiMeshInstance3D
var _pending       : bool = false   # a native mesh job is in flight
var _alive         : bool = true
var _has_mesh      : bool = false
# Triangle count of the currently-applied mesh. Set here at apply time (we
# already have the index array) so the planet doesn't have to read the whole
# mesh back out with surface_get_arrays() just to count it.
var tri_count      : int  = 0


func setup(
		p_origin: Vector3,
		p_size: float,
		p_lod: int,
		p_resolution: int,
		p_density: Variant,
		p_planet_center: Vector3,
		p_material: Material,
		p_build_collision: bool) -> void:
	origin = p_origin
	size = p_size
	lod = p_lod
	resolution = p_resolution
	density = p_density
	planet_center = p_planet_center
	material = p_material
	build_collision = p_build_collision
	position = Vector3.ZERO
	name = "Chunk_L%d_%d_%d_%d" % [lod, int(origin.x), int(origin.y), int(origin.z)]
	# Meshing is owned by the Rust thread pool; results are pushed in via
	# apply_native_result() (called from Planet._poll_native). The chunk itself
	# has no per-frame work, so don't pay for an empty _process callback on every
	# one of the thousands of live chunks.
	set_process(false)


func request_build() -> void:
	# Non-blocking: submit the chunk to the native thread pool and return. The
	# planet collects the finished mesh via poll/take and calls
	# apply_native_result() — so meshing runs off the main thread (good FPS)
	# without ever calling gdext from a worker (the part that crashed).
	if native == null or not _alive or _pending:
		return
	_pending = true
	_last_built_mask = transition_mask
	native.call("submit_chunk", get_instance_id(), world_seed,
		float(planet_radius_for_scatter), origin, size, resolution,
		transition_mask, planet_center, build_collision)


# Called by the planet octree when this chunk's native mesh is ready.
func apply_native_result(result: Dictionary) -> void:
	_pending = false
	if not _alive:
		queue_free()
		return
	_apply_mesh(result)
	_has_mesh = true
	mesh_ready.emit(self)


# Called by the planet octree when neighbour LODs change. Returns true if the
# mask changed and the chunk should be re-meshed.
func set_transition_mask(mask: int) -> bool:
	if mask == transition_mask:
		return false
	transition_mask = mask
	return _has_mesh and mask != _last_built_mask


# "My currently DISPLAYED mesh isn't consistent with my current transition mask"
# — either a mesh job is in flight (the new mesh hasn't been applied yet) or the
# mask changed and no job is queued yet. Used by the atomic-swap gate so old
# geometry is held until the replacement's neighbours are actually re-meshed
# (not merely submitted — `_last_built_mask` updates at submit time).
func is_dirty() -> bool:
	return _pending or transition_mask != _last_built_mask


func _apply_mesh(result: Dictionary) -> void:
	var positions : PackedVector3Array = result.get("positions", PackedVector3Array())
	var normals   : PackedVector3Array = result.get("normals",   PackedVector3Array())
	var indices   : PackedInt32Array   = result.get("indices",   PackedInt32Array())
	var empty     : bool               = result.get("empty", true)

	if empty or indices.size() == 0:
		tri_count = 0
		_ensure_mesh_instance()
		_mesh_instance.mesh = null
		_remove_collision()
		return

	@warning_ignore("integer_division")
	tri_count = indices.size() / 3
	_ensure_mesh_instance()
	var mesh := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = positions
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_INDEX]  = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if material:
		mesh.surface_set_material(0, material)
	_mesh_instance.mesh = mesh

	if build_collision:
		_ensure_collision()
		# Reuse the existing shape if present; otherwise create one. Avoids
		# churning the physics server when re-meshing (e.g. on neighbour-LOD
		# mask changes — see planet.gd `_update_neighbor_masks`).
		var shape : ConcavePolygonShape3D = _coll_shape.shape as ConcavePolygonShape3D
		if shape == null:
			shape = ConcavePolygonShape3D.new()
			_coll_shape.shape = shape
		# The worker already de-indexed the triangle soup for us (only for chunks
		# that asked, via build_collision), so we no longer gather it per-index on
		# the main thread.
		shape.set_faces(result.get("collision_faces", PackedVector3Array()))
	else:
		_remove_collision()

	_update_scatter(positions, normals, indices)


func _update_scatter(positions: PackedVector3Array, normals: PackedVector3Array,
		indices: PackedInt32Array) -> void:
	if scatter_mesh == null or lod > scatter_lod_max:
		# Clear any leftover scatter (e.g. if this chunk had it before and
		# then we downgraded — rare, but cheap to handle).
		if _scatter_mmi:
			_scatter_mmi.visible = false
		return
	var coords_seed := hash([int(origin.x), int(origin.y), int(origin.z), lod])
	var xforms := TerrainScatter.build_rock_transforms(
		positions, normals, indices,
		planet_center, planet_radius_for_scatter,
		sea_level_offset_for_scatter, coords_seed)
	@warning_ignore("integer_division")
	var count : int = xforms.size() / 12
	if count == 0:
		if _scatter_mmi:
			_scatter_mmi.visible = false
		return
	_ensure_scatter_mmi()
	var mm : MultiMesh = _scatter_mmi.multimesh
	mm.instance_count = count
	# build_rock_transforms already lays each instance out as 12 floats in the
	# exact MultiMesh TRANSFORM_3D buffer order (3 rows of 4), so we can hand the
	# whole array over in one assignment instead of rebuilding a Basis +
	# Transform3D and calling set_instance_transform() per rock.
	mm.buffer = xforms
	_scatter_mmi.visible = true


func _ensure_scatter_mmi() -> void:
	if _scatter_mmi != null:
		return
	_scatter_mmi = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = scatter_mesh
	_scatter_mmi.multimesh = mm
	_scatter_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_scatter_mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	if scatter_material:
		_scatter_mmi.material_override = scatter_material
	add_child(_scatter_mmi)


func _ensure_mesh_instance() -> void:
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(_mesh_instance)


func _ensure_collision() -> void:
	if _static_body == null:
		_static_body = StaticBody3D.new()
		_coll_shape  = CollisionShape3D.new()
		_static_body.add_child(_coll_shape)
		_static_body.collision_layer = 1
		_static_body.collision_mask  = 0
		add_child(_static_body)


func _remove_collision() -> void:
	if _coll_shape:
		_coll_shape.shape = null


func has_mesh() -> bool:
	return _has_mesh


func release() -> void:
	# Safe to free immediately: the Rust worker never references this node (it
	# only writes into the native result map, keyed by instance id). If a job is
	# still in flight, Planet._poll_native still drains and discards the result —
	# instance_from_id() returns null once we're freed — so nothing leaks.
	_alive = false
	queue_free()
