class_name RoomDefinition
extends RefCounted

## Defines a single rectangular room in a modular interior layout
## Rooms are placed on a 3D grid and can have walls selectively enabled/disabled

## Grid position of this room (in grid units, not world units)
var grid_position: Vector3i = Vector3i.ZERO

## Room dimensions in world units (width, height, length)
## Default dimensions match the original single-room vehicle interior
var dimensions: Vector3 = Vector3(18.0, 9.0, 30.0)  # 3x scale ship size

## Wall configuration - which walls should be generated
## Set to false to create doorways/openings to adjacent rooms
var has_floor: bool = true
var has_ceiling: bool = true
var has_left_wall: bool = true
var has_right_wall: bool = true
var has_front_wall: bool = false  # Default: open front for vehicle entrance
var has_back_wall: bool = true

## Wall thickness for collision detection
var wall_thickness: float = 0.2

## Optional: Custom material colors for this room
var floor_color: Color = Color(0.6, 0.6, 0.6)
var wall_color: Color = Color(0.8, 0.8, 0.8)

func _init(
	p_grid_position: Vector3i = Vector3i.ZERO,
	p_dimensions: Vector3 = Vector3(18.0, 9.0, 30.0),
	p_has_front_wall: bool = false,
	p_has_back_wall: bool = true
) -> void:
	grid_position = p_grid_position
	dimensions = p_dimensions
	has_front_wall = p_has_front_wall
	has_back_wall = p_has_back_wall

## Get world position of room center based on grid position
func get_world_position() -> Vector3:
	# Each grid unit equals the room's dimensions
	return Vector3(
		grid_position.x * dimensions.x,
		grid_position.y * dimensions.y,
		grid_position.z * dimensions.z
	)

## Get half-extents for physics shapes (PhysicsServer3D uses half-extents)
func get_half_extents() -> Vector3:
	return dimensions * 0.5
