class_name InteriorLayout
extends RefCounted

## Defines a modular interior layout consisting of multiple rooms
## Rooms are arranged on a 3D grid and can be connected by removing walls

## Array of room definitions in this layout
var rooms: Array[RoomDefinition] = []

## Base scale multiplier for all rooms (used by containers to scale up)
var scale_multiplier: float = 1.0

func _init(p_scale_multiplier: float = 1.0) -> void:
	scale_multiplier = p_scale_multiplier

## Add a room to the layout
func add_room(room: RoomDefinition) -> void:
	rooms.append(room)

## Get all rooms at a specific grid position
func get_room_at(grid_pos: Vector3i) -> RoomDefinition:
	for room in rooms:
		if room.grid_position == grid_pos:
			return room
	return null

## Automatically remove walls between adjacent rooms to create doorways
func auto_connect_rooms() -> void:
	for i in range(rooms.size()):
		var room_a = rooms[i]
		for j in range(i + 1, rooms.size()):
			var room_b = rooms[j]
			var diff = room_b.grid_position - room_a.grid_position

			# Check if rooms are adjacent on X axis (left/right)
			if diff == Vector3i(1, 0, 0):  # room_b is to the right of room_a
				room_a.has_right_wall = false
				room_b.has_left_wall = false
			elif diff == Vector3i(-1, 0, 0):  # room_b is to the left of room_a
				room_a.has_left_wall = false
				room_b.has_right_wall = false
			# Check if rooms are adjacent on Z axis (front/back)
			elif diff == Vector3i(0, 0, 1):  # room_b is in front of room_a
				room_a.has_front_wall = false
				room_b.has_back_wall = false
			elif diff == Vector3i(0, 0, -1):  # room_b is behind room_a
				room_a.has_back_wall = false
				room_b.has_front_wall = false
			# Check if rooms are adjacent on Y axis (floor/ceiling)
			elif diff == Vector3i(0, 1, 0):  # room_b is above room_a
				room_a.has_ceiling = false
				room_b.has_floor = false
			elif diff == Vector3i(0, -1, 0):  # room_b is below room_a
				room_a.has_floor = false
				room_b.has_ceiling = false

## Create a simple single-room layout (backwards compatible with original system)
static func create_single_room(size_scale: float = 3.0) -> InteriorLayout:
	var layout = InteriorLayout.new(size_scale)
	var room = RoomDefinition.new(
		Vector3i.ZERO,
		Vector3(6.0 * size_scale, 3.0 * size_scale, 10.0 * size_scale),
		false,  # No front wall (entrance)
		true    # Has back wall
	)
	layout.add_room(room)
	return layout

## Create a two-room layout (main room + back room)
static func create_two_room_layout(size_scale: float = 3.0) -> InteriorLayout:
	var layout = InteriorLayout.new(size_scale)

	# Front room (main entrance)
	var front_room = RoomDefinition.new(
		Vector3i(0, 0, 0),
		Vector3(6.0 * size_scale, 3.0 * size_scale, 10.0 * size_scale),
		false,  # No front wall (entrance)
		true    # Has back wall initially (will be removed by auto_connect)
	)
	layout.add_room(front_room)

	# Back room (connected to front)
	var back_room = RoomDefinition.new(
		Vector3i(0, 0, -1),  # One room back on Z axis
		Vector3(6.0 * size_scale, 3.0 * size_scale, 10.0 * size_scale),
		true,   # Has front wall initially (will be removed by auto_connect)
		true    # Has back wall
	)
	layout.add_room(back_room)

	# Auto-connect the rooms (removes walls between them)
	layout.auto_connect_rooms()

	return layout

## Create a corridor-style layout (3 rooms in a line)
static func create_corridor_layout(size_scale: float = 3.0) -> InteriorLayout:
	var layout = InteriorLayout.new(size_scale)

	# Front room (entrance)
	layout.add_room(RoomDefinition.new(
		Vector3i(0, 0, 0),
		Vector3(6.0 * size_scale, 3.0 * size_scale, 8.0 * size_scale),
		false, true
	))

	# Middle room
	layout.add_room(RoomDefinition.new(
		Vector3i(0, 0, -1),
		Vector3(6.0 * size_scale, 3.0 * size_scale, 8.0 * size_scale),
		true, true
	))

	# Back room
	layout.add_room(RoomDefinition.new(
		Vector3i(0, 0, -2),
		Vector3(6.0 * size_scale, 3.0 * size_scale, 8.0 * size_scale),
		true, true
	))

	layout.auto_connect_rooms()
	return layout

## Dispatch to the right factory based on an integer type index.
## type: 0=Single Room, 1=Two Rooms, 2=Corridor, 3=L-Shaped
static func create_from_type(type: int, size_scale: float = 3.0) -> InteriorLayout:
	match type:
		1: return create_two_room_layout(size_scale)
		2: return create_corridor_layout(size_scale)
		3: return create_l_shaped_layout(size_scale)
		_: return create_single_room(size_scale)

## Create an L-shaped layout (2 rooms at right angle)
static func create_l_shaped_layout(size_scale: float = 3.0) -> InteriorLayout:
	var layout = InteriorLayout.new(size_scale)

	# Main room (entrance)
	layout.add_room(RoomDefinition.new(
		Vector3i(0, 0, 0),
		Vector3(6.0 * size_scale, 3.0 * size_scale, 10.0 * size_scale),
		false, true
	))

	# Side room (connected to right wall of main room)
	layout.add_room(RoomDefinition.new(
		Vector3i(1, 0, 0),
		Vector3(6.0 * size_scale, 3.0 * size_scale, 10.0 * size_scale),
		true, true
	))

	layout.auto_connect_rooms()
	return layout
