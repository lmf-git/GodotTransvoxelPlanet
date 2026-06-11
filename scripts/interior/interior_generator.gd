class_name InteriorGenerator
extends RefCounted

## Generates physics colliders and visual meshes from InteriorLayout definitions
## Replaces hardcoded geometry creation with data-driven approach

## Generate static physics colliders for an interior layout
## Returns array of RID colliders that were created
static func generate_colliders(layout: InteriorLayout, physics_space: RID) -> Array[RID]:
	if not physics_space.is_valid():
		push_error("Invalid physics space provided to InteriorGenerator")
		return []

	var colliders: Array[RID] = []

	for room in layout.rooms:
		var room_colliders = _generate_room_colliders(room, physics_space)
		colliders.append_array(room_colliders)

	return colliders

## Generate visual meshes for an interior layout
## Returns a Node3D containing all visual geometry
static func generate_visuals(layout: InteriorLayout, parent_body: Node3D) -> Node3D:
	var visuals = Node3D.new()
	visuals.name = "InteriorVisuals"

	for room in layout.rooms:
		_generate_room_visuals(room, visuals)

	if parent_body:
		parent_body.add_child(visuals)

	return visuals

## Generate a scene-tree StaticBody3D with CollisionShape3D boxes for the
## layout — for interiors that live in the ordinary world physics space (e.g.
## enterable buildings on the planet surface) rather than a proxy space.
## Layout-local frame: Y up, entrance toward +Z (rooms with no front wall).
static func generate_static_body(layout: InteriorLayout) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "InteriorColliders"
	body.collision_layer = 1   # environment layer — the player capsule walks on it
	body.collision_mask = 0
	for room in layout.rooms:
		var half_ext: Vector3 = room.get_half_extents()
		var center: Vector3 = room.get_world_position()
		var panels: Array = []
		if room.has_floor:
			panels.append([Vector3(half_ext.x, 0.1, half_ext.z), center + Vector3(0, -half_ext.y + 0.1, 0)])
		if room.has_ceiling:
			panels.append([Vector3(half_ext.x, 0.1, half_ext.z), center + Vector3(0, half_ext.y - 0.1, 0)])
		if room.has_left_wall:
			panels.append([Vector3(0.1, half_ext.y, half_ext.z), center + Vector3(-half_ext.x, 0, 0)])
		if room.has_right_wall:
			panels.append([Vector3(0.1, half_ext.y, half_ext.z), center + Vector3(half_ext.x, 0, 0)])
		if room.has_front_wall:
			panels.append([Vector3(half_ext.x, half_ext.y, 0.1), center + Vector3(0, 0, half_ext.z)])
		if room.has_back_wall:
			panels.append([Vector3(half_ext.x, half_ext.y, 0.1), center + Vector3(0, 0, -half_ext.z)])
		for p in panels:
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = (p[0] as Vector3) * 2.0   # BoxShape3D takes full size, not half-extents
			cs.shape = shape
			cs.position = p[1]
			body.add_child(cs)
	return body


## Generate collision shapes for dock proxy body
## Returns array of shape data [shape_rid, transform] pairs
static func generate_dock_shapes(layout: InteriorLayout) -> Array:
	var shapes: Array = []

	for room in layout.rooms:
		var room_shapes = _generate_room_dock_shapes(room)
		shapes.append_array(room_shapes)

	return shapes

## Private: Generate colliders for a single room
static func _generate_room_colliders(room: RoomDefinition, physics_space: RID) -> Array[RID]:
	var colliders: Array[RID] = []
	var half_ext = room.get_half_extents()
	var room_center = room.get_world_position()

	# Floor collider
	if room.has_floor:
		var floor_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(floor_shape, Vector3(half_ext.x, 0.1, half_ext.z))

		var floor_body = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(floor_body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_space(floor_body, physics_space)
		PhysicsServer3D.body_add_shape(floor_body, floor_shape)

		var floor_pos = room_center + Vector3(0, -half_ext.y + 0.1, 0)
		PhysicsServer3D.body_set_state(floor_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			Transform3D(Basis(), floor_pos))
		PhysicsServer3D.body_set_collision_layer(floor_body, 1)
		PhysicsServer3D.body_set_collision_mask(floor_body, 1)
		colliders.append(floor_body)

	# Ceiling collider
	if room.has_ceiling:
		var ceiling_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(ceiling_shape, Vector3(half_ext.x, 0.1, half_ext.z))

		var ceiling_body = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(ceiling_body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_space(ceiling_body, physics_space)
		PhysicsServer3D.body_add_shape(ceiling_body, ceiling_shape)

		var ceiling_pos = room_center + Vector3(0, half_ext.y - 0.1, 0)
		PhysicsServer3D.body_set_state(ceiling_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			Transform3D(Basis(), ceiling_pos))
		PhysicsServer3D.body_set_collision_layer(ceiling_body, 1)
		PhysicsServer3D.body_set_collision_mask(ceiling_body, 1)
		colliders.append(ceiling_body)

	# Left wall collider
	if room.has_left_wall:
		var left_wall_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(left_wall_shape, Vector3(0.1, half_ext.y, half_ext.z))

		var left_wall_body = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(left_wall_body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_space(left_wall_body, physics_space)
		PhysicsServer3D.body_add_shape(left_wall_body, left_wall_shape)

		var left_pos = room_center + Vector3(-half_ext.x, 0, 0)
		PhysicsServer3D.body_set_state(left_wall_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			Transform3D(Basis(), left_pos))
		PhysicsServer3D.body_set_collision_layer(left_wall_body, 1)
		PhysicsServer3D.body_set_collision_mask(left_wall_body, 1)
		colliders.append(left_wall_body)

	# Right wall collider
	if room.has_right_wall:
		var right_wall_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(right_wall_shape, Vector3(0.1, half_ext.y, half_ext.z))

		var right_wall_body = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(right_wall_body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_space(right_wall_body, physics_space)
		PhysicsServer3D.body_add_shape(right_wall_body, right_wall_shape)

		var right_pos = room_center + Vector3(half_ext.x, 0, 0)
		PhysicsServer3D.body_set_state(right_wall_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			Transform3D(Basis(), right_pos))
		PhysicsServer3D.body_set_collision_layer(right_wall_body, 1)
		PhysicsServer3D.body_set_collision_mask(right_wall_body, 1)
		colliders.append(right_wall_body)

	# Front wall collider
	if room.has_front_wall:
		var front_wall_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(front_wall_shape, Vector3(half_ext.x, half_ext.y, 0.1))

		var front_wall_body = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(front_wall_body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_space(front_wall_body, physics_space)
		PhysicsServer3D.body_add_shape(front_wall_body, front_wall_shape)

		var front_pos = room_center + Vector3(0, 0, half_ext.z)
		PhysicsServer3D.body_set_state(front_wall_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			Transform3D(Basis(), front_pos))
		PhysicsServer3D.body_set_collision_layer(front_wall_body, 1)
		PhysicsServer3D.body_set_collision_mask(front_wall_body, 1)
		colliders.append(front_wall_body)

	# Back wall collider
	if room.has_back_wall:
		var back_wall_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(back_wall_shape, Vector3(half_ext.x, half_ext.y, 0.1))

		var back_wall_body = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(back_wall_body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_space(back_wall_body, physics_space)
		PhysicsServer3D.body_add_shape(back_wall_body, back_wall_shape)

		var back_pos = room_center + Vector3(0, 0, -half_ext.z)
		PhysicsServer3D.body_set_state(back_wall_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			Transform3D(Basis(), back_pos))
		PhysicsServer3D.body_set_collision_layer(back_wall_body, 1)
		PhysicsServer3D.body_set_collision_mask(back_wall_body, 1)
		colliders.append(back_wall_body)

	return colliders

## Private: Generate visual meshes for a single room
static func _generate_room_visuals(room: RoomDefinition, parent: Node3D) -> void:
	var half_ext = room.get_half_extents()
	var room_center = room.get_world_position()

	var floor_material = StandardMaterial3D.new()
	floor_material.albedo_color = room.floor_color
	floor_material.metallic = 0.0
	floor_material.roughness = 0.8

	var wall_material = StandardMaterial3D.new()
	wall_material.albedo_color = room.wall_color
	wall_material.metallic = 0.0
	wall_material.roughness = 0.7

	# Floor mesh
	if room.has_floor:
		var floor_mesh = MeshInstance3D.new()
		floor_mesh.mesh = BoxMesh.new()
		floor_mesh.mesh.size = Vector3(room.dimensions.x, 0.1, room.dimensions.z)
		floor_mesh.material_override = floor_material
		floor_mesh.position = room_center + Vector3(0, -half_ext.y + 0.05, 0)
		floor_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(floor_mesh)

	# Ceiling mesh
	if room.has_ceiling:
		var ceiling_mesh = MeshInstance3D.new()
		ceiling_mesh.mesh = BoxMesh.new()
		ceiling_mesh.mesh.size = Vector3(room.dimensions.x, 0.1, room.dimensions.z)
		ceiling_mesh.material_override = wall_material
		ceiling_mesh.position = room_center + Vector3(0, half_ext.y - 0.05, 0)
		ceiling_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(ceiling_mesh)

	# Left wall mesh
	if room.has_left_wall:
		var left_wall = MeshInstance3D.new()
		left_wall.mesh = BoxMesh.new()
		left_wall.mesh.size = Vector3(0.1, room.dimensions.y, room.dimensions.z)
		left_wall.material_override = wall_material
		left_wall.position = room_center + Vector3(-half_ext.x, 0, 0)
		parent.add_child(left_wall)

	# Right wall mesh
	if room.has_right_wall:
		var right_wall = MeshInstance3D.new()
		right_wall.mesh = BoxMesh.new()
		right_wall.mesh.size = Vector3(0.1, room.dimensions.y, room.dimensions.z)
		right_wall.material_override = wall_material
		right_wall.position = room_center + Vector3(half_ext.x, 0, 0)
		parent.add_child(right_wall)

	# Front wall mesh
	if room.has_front_wall:
		var front_wall = MeshInstance3D.new()
		front_wall.mesh = BoxMesh.new()
		front_wall.mesh.size = Vector3(room.dimensions.x, room.dimensions.y, 0.1)
		front_wall.material_override = wall_material
		front_wall.position = room_center + Vector3(0, 0, half_ext.z)
		parent.add_child(front_wall)

	# Back wall mesh
	if room.has_back_wall:
		var back_wall = MeshInstance3D.new()
		back_wall.mesh = BoxMesh.new()
		back_wall.mesh.size = Vector3(room.dimensions.x, room.dimensions.y, 0.1)
		back_wall.material_override = wall_material
		back_wall.position = room_center + Vector3(0, 0, -half_ext.z)
		parent.add_child(back_wall)

## Private: Generate dock proxy shapes for a single room
static func _generate_room_dock_shapes(room: RoomDefinition) -> Array:
	var shapes: Array = []
	var half_ext = room.get_half_extents()
	var room_center = room.get_world_position()

	# Floor shape
	if room.has_floor:
		var floor_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(floor_shape, Vector3(half_ext.x, 0.15, half_ext.z))
		var floor_transform = Transform3D(Basis(), room_center + Vector3(0, -half_ext.y + 0.1, 0))
		shapes.append([floor_shape, floor_transform])

	# Ceiling shape
	if room.has_ceiling:
		var ceiling_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(ceiling_shape, Vector3(half_ext.x, 0.1, half_ext.z))
		var ceiling_transform = Transform3D(Basis(), room_center + Vector3(0, half_ext.y - 0.1, 0))
		shapes.append([ceiling_shape, ceiling_transform])

	# Left wall shape
	if room.has_left_wall:
		var left_wall_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(left_wall_shape, Vector3(0.1, half_ext.y, half_ext.z))
		var left_transform = Transform3D(Basis(), room_center + Vector3(-half_ext.x, 0, 0))
		shapes.append([left_wall_shape, left_transform])

	# Right wall shape
	if room.has_right_wall:
		var right_wall_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(right_wall_shape, Vector3(0.1, half_ext.y, half_ext.z))
		var right_transform = Transform3D(Basis(), room_center + Vector3(half_ext.x, 0, 0))
		shapes.append([right_wall_shape, right_transform])

	# Front wall shape
	if room.has_front_wall:
		var front_wall_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(front_wall_shape, Vector3(half_ext.x, half_ext.y, 0.1))
		var front_transform = Transform3D(Basis(), room_center + Vector3(0, 0, half_ext.z))
		shapes.append([front_wall_shape, front_transform])

	# Back wall shape
	if room.has_back_wall:
		var back_wall_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(back_wall_shape, Vector3(half_ext.x, half_ext.y, 0.1))
		var back_transform = Transform3D(Basis(), room_center + Vector3(0, 0, -half_ext.z))
		shapes.append([back_wall_shape, back_transform])

	return shapes
