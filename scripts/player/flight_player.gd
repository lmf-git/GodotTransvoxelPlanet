class_name FlightPlayer
extends CharacterBody3D

## 6-DOF spaceflight controller with surface-attracted "land" mode.
##
## Default — FLIGHT mode:
##   * Mouse pitch / yaw, Q/E roll
##   * WASD = forward / back / strafe along local axes
##   * Space / Shift = up / down along local axes
##   * Hold boost (LeftAlt) for 6× speed
##   * Movement is integrated directly into `velocity`; no gravity.
##
## Press F to toggle WALK mode:
##   * Player up-vector tracks the planet's outward radial direction.
##   * Constant gravity pulls toward planet center; jump on Space.
##   * Move with WASD in the surface tangent plane.
##
## The camera is mounted on a SpringArm3D for clean third-person follow with
## auto-collision avoidance.

signal mode_changed(new_mode: String)

@export var planet_path : NodePath
@export var fly_speed         : float = 80.0
@export var fly_boost         : float = 6.0
@export var fly_strafe        : float = 60.0
@export var fly_pitch_speed   : float = 1.2     # rad/s at full mouse delta
@export var fly_yaw_speed     : float = 1.2
@export var fly_roll_speed    : float = 1.6
@export var fly_damping       : float = 1.6
@export var mouse_sensitivity : float = 0.0024
@export var walk_speed        : float = 8.0
@export var walk_jump         : float = 6.0
@export var walk_gravity      : float = 18.0
@export var camera_distance   : float = 8.0
@export var camera_height     : float = 2.5

enum Mode { FLIGHT, WALK }
var mode : Mode = Mode.FLIGHT

var _planet : Planet
var _spring : SpringArm3D
var _camera : Camera3D
var _yaw_input   : float = 0.0
var _pitch_input : float = 0.0
var _mouse_captured : bool = true


func _ready() -> void:
	if planet_path != NodePath():
		_planet = get_node_or_null(planet_path) as Planet
	_build_camera_rig()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# Lets the scene owner inject the planet after _ready (planet may not yet
# exist when the player is constructed, e.g. when both are built in code).
func set_planet(p: Planet) -> void:
	_planet = p


func _build_camera_rig() -> void:
	# The player looks in its local -Z direction. A proper third-person camera
	# sits BEHIND the player (positive Z in local space) and slightly above.
	# SpringArm3D extends in the -Z direction by default, so we rotate it 180°
	# around Y so its arm extends in the player's +Z direction = behind.
	_spring = SpringArm3D.new()
	_spring.spring_length = camera_distance
	_spring.position = Vector3(0, camera_height, 0)
	_spring.rotation = Vector3(0, PI, 0)   # flip so -Z spring extends in +Z player
	_spring.collision_mask = 1
	add_child(_spring)
	_camera = Camera3D.new()
	_camera.fov = 70.0
	_camera.near = 0.1
	_camera.far  = 200000.0   # planet + atmosphere visible
	_camera.current = true
	# Camera looks back along its own -Z toward the player, which after the
	# 180° spring rotation aligns with the player's forward direction.
	_spring.add_child(_camera)
	_camera.position = Vector3.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		var m := event as InputEventMouseMotion
		_yaw_input   = -m.relative.x * mouse_sensitivity
		_pitch_input = -m.relative.y * mouse_sensitivity
	elif event.is_action_pressed("ui_cancel"):
		_mouse_captured = not _mouse_captured
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("toggle_mode"):
		_toggle_mode()


func _physics_process(delta: float) -> void:
	match mode:
		Mode.FLIGHT: _flight_step(delta)
		Mode.WALK:   _walk_step(delta)
	_yaw_input = 0.0
	_pitch_input = 0.0


func _flight_step(delta: float) -> void:
	# Apply mouse-driven yaw/pitch around the *local* axes (so roll feels right).
	rotate_object_local(Vector3.UP,    _yaw_input)
	rotate_object_local(Vector3.RIGHT, _pitch_input)

	var roll := Input.get_axis("roll_right", "roll_left")
	if absf(roll) > 0.0:
		rotate_object_local(Vector3.FORWARD, roll * fly_roll_speed * delta)

	var fwd  := Input.get_axis("move_backward", "move_forward")
	var side := Input.get_axis("move_left",     "move_right")
	var up   := Input.get_axis("move_down",     "move_up")
	var boost := 1.0
	if Input.is_action_pressed("boost"):
		boost = fly_boost

	# Local-axis direction in world space.
	var dir := Vector3.ZERO
	dir += -transform.basis.z * fwd
	dir +=  transform.basis.x * side
	dir +=  transform.basis.y * up
	if dir.length_squared() > 0.0:
		dir = dir.normalized()

	# Integrate toward target velocity (smooths input).
	var target := dir * fly_speed * boost
	velocity = velocity.lerp(target, clampf(fly_damping * delta, 0.0, 1.0))

	# move_and_slide uses Vector3.UP for floor detection; in flight we don't
	# care about floors, but collisions are still detected.
	up_direction = transform.basis.y
	move_and_slide()


func _walk_step(delta: float) -> void:
	if _planet == null:
		return
	var grav_dir := _planet.gravity_dir(global_position)
	var up_world := -grav_dir
	up_direction = up_world

	# Align the player's up axis to up_world, preserving forward direction.
	var fwd := -transform.basis.z
	# Project forward onto the tangent plane.
	var tangent_fwd := (fwd - up_world * fwd.dot(up_world)).normalized()
	if tangent_fwd.length_squared() < 0.0001:
		tangent_fwd = (transform.basis.x - up_world * transform.basis.x.dot(up_world)).normalized()
	var new_basis := Basis()
	new_basis.z = -tangent_fwd
	new_basis.x = up_world.cross(new_basis.z).normalized()
	new_basis.y = up_world
	# Smooth the orientation change.
	transform.basis = transform.basis.slerp(new_basis.orthonormalized(), clampf(8.0 * delta, 0.0, 1.0))

	# Apply mouse look in local frame.
	rotate_object_local(Vector3.UP,    _yaw_input)
	rotate_object_local(Vector3.RIGHT, _pitch_input)

	# Movement: WASD in tangent plane.
	var fwd_in  := Input.get_axis("move_backward", "move_forward")
	var side_in := Input.get_axis("move_left",     "move_right")
	var move_dir := (-transform.basis.z * fwd_in + transform.basis.x * side_in)
	# Project onto tangent plane.
	move_dir = move_dir - up_world * move_dir.dot(up_world)
	if move_dir.length_squared() > 0.0:
		move_dir = move_dir.normalized()

	var planar_vel := move_dir * walk_speed
	var vertical_vel := velocity.dot(up_world)

	# Gravity & jump.
	if is_on_floor():
		vertical_vel = 0.0
		if Input.is_action_just_pressed("move_up"):
			vertical_vel = walk_jump
	else:
		vertical_vel -= walk_gravity * delta

	velocity = planar_vel + up_world * vertical_vel
	move_and_slide()


func _toggle_mode() -> void:
	mode = Mode.WALK if mode == Mode.FLIGHT else Mode.FLIGHT
	mode_changed.emit("WALK" if mode == Mode.WALK else "FLIGHT")
	# Zero velocity to avoid carrying speed across mode switches.
	velocity = Vector3.ZERO
