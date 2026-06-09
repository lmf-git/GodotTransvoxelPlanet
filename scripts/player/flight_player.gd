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
@export var eye_height        : float = 1.6     # first-person camera height in WALK
@export var air_accel         : float = 32.0    # 6DOF thruster authority while falling
@export var air_drag          : float = 0.6     # velocity damping while airborne

enum Mode { FLIGHT, WALK }
var mode : Mode = Mode.FLIGHT

var _planet : Planet
var _spring : SpringArm3D
var _camera : Camera3D
var _yaw_input   : float = 0.0
var _pitch_input : float = 0.0
var _cam_pitch   : float = 0.0   # WALK camera pitch (radians) — kept off the body so gravity-align can't fight it
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
	# The body needs an actual collision shape or it falls through everything and
	# is_on_floor() never trips — i.e. you can't walk. A human-sized capsule whose
	# bottom sits at the body origin (so the origin is the feet). The player is on
	# its OWN physics layer (2) and collides with the environment (layer 1: terrain,
	# buildings, roads, rocks); the camera spring (mask 1) then ignores the player.
	collision_layer = 2
	collision_mask = 1
	var body_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	body_shape.shape = capsule
	body_shape.position = Vector3(0.0, 0.9, 0.0)   # capsule centred above origin → feet at origin
	add_child(body_shape)

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
	# near/far ratio matters a lot for projection-matrix stability — at far 2.5M
	# the old 0.1 near made the ratio 25 million, which made Projection::get_endpoints
	# (used by get_frustum() in planet.gd) fail with a singular-matrix error and
	# spam the console. Raising near to 1.0 drops the ratio to 2.5M, which Godot
	# handles cleanly. The spring-arm camera sits 8 m from the player so anything
	# inside 1 m is occluded anyway.
	_camera.near = 1.0
	_camera.far  = 2500000.0  # covers the sun at orbit_radius 1.8M + radius 78k = 1.88M, with margin
	_camera.current = true
	# Camera looks back along its own -Z toward the player, which after the
	# 180° spring rotation aligns with the player's forward direction.
	_spring.add_child(_camera)
	_camera.position = Vector3.ZERO
	# The camera inherits the spring's 180° (it's a child), which makes it look
	# in the player's +Z — i.e. BACKWARD, away from where the player faces (and
	# away from the planet at spawn). Rotate the camera 180° to cancel that so it
	# looks along the player's forward (-Z), the correct third-person view.
	_camera.rotation = Vector3(0, PI, 0)


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
	# Everything here is in WORLD space. gravity_dir() is world-space, but the player
	# is parented under the spinning PlanetSystem, so its LOCAL basis is NOT the world
	# basis — aligning a local basis to a world up tilted the view off gravity. Drive
	# global_transform.basis directly so "up" always = the world radial.
	var gpos := global_position
	var up_world := (-_planet.gravity_dir(gpos)).normalized()
	up_direction = up_world
	var on_floor := is_on_floor()

	if on_floor:
		# ── Grounded: gravity-aligned walk ──────────────────────────────────────
		# Yaw around world-up; rebuild an upright WORLD basis directly (no slerp to
		# fight). Pitch lives on the camera so the up-alignment can't undo it.
		var gb := global_transform.basis
		var fwd := -gb.z
		fwd = fwd - up_world * fwd.dot(up_world)
		if fwd.length_squared() < 1e-6:
			fwd = gb.x - up_world * gb.x.dot(up_world)
		fwd = fwd.normalized().rotated(up_world, _yaw_input)
		var back := -fwd
		var right := up_world.cross(back).normalized()
		global_transform = Transform3D(Basis(right, up_world, back).orthonormalized(), gpos)

		_cam_pitch = clampf(_cam_pitch + _pitch_input, -1.45, 1.45)
		if _spring:
			_spring.rotation = Vector3(_cam_pitch, 0.0, 0.0)

		var f := Input.get_axis("move_backward", "move_forward")
		var s := Input.get_axis("move_left", "move_right")
		var gb2 := global_transform.basis
		var move_dir := (-gb2.z * f + gb2.x * s)
		move_dir = move_dir - up_world * move_dir.dot(up_world)
		if move_dir.length_squared() > 0.0:
			move_dir = move_dir.normalized()
		var jump := walk_jump if Input.is_action_just_pressed("move_up") else 0.0
		velocity = move_dir * walk_speed + up_world * jump
	else:
		# ── Falling: free QUATERNION 6DOF ───────────────────────────────────────
		# No up-alignment while airborne — integrate the body's attitude as a
		# quaternion (mouse = pitch/yaw about the body's own axes, Q/E = roll), which
		# is gimbal-lock-free and composes cleanly. Camera-relative thrust on
		# WASD/Space/Shift; gravity still pulls; light drag. The camera looks straight
		# down the body's forward here (the body carries the attitude).
		if _spring:
			_spring.rotation = Vector3.ZERO
		var gb := global_transform.basis
		var roll := Input.get_axis("roll_right", "roll_left")
		var dq := Quaternion(gb.x, _pitch_input) \
				* Quaternion(gb.y, _yaw_input) \
				* Quaternion(-gb.z, roll * fly_roll_speed * delta)
		var q := (dq * gb.get_rotation_quaternion()).normalized()
		global_transform = Transform3D(Basis(q), gpos)

		var gb2 := global_transform.basis
		var f := Input.get_axis("move_backward", "move_forward")
		var s := Input.get_axis("move_left", "move_right")
		var u := Input.get_axis("move_down", "move_up")
		var thrust := (-gb2.z * f + gb2.x * s + gb2.y * u)
		if thrust.length_squared() > 0.0:
			thrust = thrust.normalized()
		velocity += thrust * air_accel * delta
		velocity -= up_world * (walk_gravity * delta)
		velocity -= velocity * clampf(air_drag * delta, 0.0, 1.0)
	move_and_slide()


func _toggle_mode() -> void:
	mode = Mode.WALK if mode == Mode.FLIGHT else Mode.FLIGHT
	mode_changed.emit("WALK" if mode == Mode.WALK else "FLIGHT")
	velocity = Vector3.ZERO
	if _spring == null:
		return
	if mode == Mode.WALK:
		# First-person, pitch-only rig: camera at eye height looking straight along
		# the body's forward (-Z), pitch applied on the spring's X each frame. No
		# 180° yaw flips here (those are for the third-person follow), so the pitch
		# sign is unambiguous.
		_spring.spring_length = 0.05
		_spring.position = Vector3(0.0, eye_height, 0.0)
		_spring.rotation = Vector3(0.0, 0.0, 0.0)
		_cam_pitch = 0.0
		if _camera:
			_camera.rotation = Vector3(0.0, 0.0, 0.0)
	else:
		# Third-person follow for flight; pitch goes back onto the body. Restore the
		# behind-the-player rig (spring + camera both flipped 180° about Y).
		_spring.spring_length = camera_distance
		_spring.position = Vector3(0.0, camera_height, 0.0)
		_spring.rotation = Vector3(0.0, PI, 0.0)
		if _camera:
			_camera.rotation = Vector3(0.0, PI, 0.0)
