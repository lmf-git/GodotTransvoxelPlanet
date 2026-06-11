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

# Character rig (3-rig physx animation) + IK weapon aiming. The rig is only
# visible in WALK mode; the model faces +Z so it's flipped 180° to match the
# player's -Z forward.
var rig : CharacterRig
var aim : AimController
var _pending_recoil_yaw : float = 0.0
var _loco_state : String = ""
# Vehicle (Aircraft / Car) the player is piloting; null when on foot.
var mounted_vehicle : RigidBody3D = null
# WALK camera: third-person over-the-shoulder by default, [O] toggles
# first-person (camera nudged forward of the head, IKaim-style).
var walk_third_person : bool = true
# Free-look (hold Alt in WALK third person): orbits the camera around the
# player without turning the body; recenters smoothly on release.
var _free_look_yaw : float = 0.0


func _ready() -> void:
	if planet_path != NodePath():
		_planet = get_node_or_null(planet_path) as Planet
	_build_camera_rig()
	_build_character()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _build_character() -> void:
	rig = CharacterRig.new()
	rig.name = "CharacterRig"
	rig.rotation = Vector3(0.0, PI, 0.0)   # Mixamo +Z forward → player -Z forward
	rig.visible = mode == Mode.WALK
	add_child(rig)
	aim = AimController.new()
	aim.name = "AimController"
	add_child(aim)
	aim.setup(self, rig)


# ── Accessors used by AimController ────────────────────────────────────────
func camera() -> Camera3D:
	return _camera


## WALK camera pitch in radians; positive = looking up.
func cam_pitch() -> float:
	return _cam_pitch


## Recoil: pitch kicks the view up, yaw nudges it sideways (consumed next step).
func add_recoil(pitch_up: float, yaw: float) -> void:
	_cam_pitch = clampf(_cam_pitch + pitch_up, -1.45, 1.45)
	_pending_recoil_yaw += yaw


# ── Vehicle mounting ────────────────────────────────────────────────────────
var _pre_mount_parent : Node = null

## The player is REPARENTED under the vehicle at the seat — following the seat
## by writing global_transform each tick lagged one physics step behind a fast
## vehicle (the character visibly trailed the cockpit).
func set_mounted(vehicle: RigidBody3D, seat: Node3D) -> void:
	mounted_vehicle = vehicle
	# Stay VISIBLE: the character sits inside the vehicle (sitting pose + IK
	# hands on the controls, driven by the vehicle via update_seated). Only
	# the physics body and self-driven motion are disabled.
	visible = true
	if rig:
		rig.visible = true
	collision_layer = 0
	collision_mask = 0
	velocity = Vector3.ZERO
	set_physics_process(false)
	_pre_mount_parent = get_parent()
	reparent(vehicle, false)
	transform = seat.transform   # seat is a direct child of the vehicle
	if _camera:
		_camera.current = false
	if aim:
		aim.set_hud_visible(false)
		aim.unequip_weapon()   # no rifle across the lap while flying


## Driven by the mounted vehicle every physics tick: sitting pose + hand IK.
func update_seated(rh_grip: Node3D, lh_grip: Node3D, delta: float) -> void:
	if rig and rig.is_rig_ready() and _loco_state != "sit":
		_loco_state = "sit"
		rig.play_state("sit")
		rig.set_speed_scale(1.0)
	if aim:
		aim.update_seat_ik(rh_grip, lh_grip, delta)


func set_unmounted(exit_pos: Vector3, _vehicle_basis: Basis) -> void:
	mounted_vehicle = null
	if _pre_mount_parent:
		reparent(_pre_mount_parent, false)
		_pre_mount_parent = null
	global_position = exit_pos
	visible = true
	collision_layer = 2
	collision_mask = 1
	velocity = Vector3.ZERO
	set_physics_process(true)
	mode = Mode.WALK
	_apply_mode_rig()
	if _camera:
		_camera.current = true


# Nearest mountable vehicle (aircraft or car) within interaction range.
func _nearby_vehicle() -> Node3D:
	var best : Node3D = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group("vehicles"):
		var v := node as Node3D
		if v and v.has_method("can_mount") and v.can_mount(self):
			var d := v.global_position.distance_to(global_position)
			if d < best_d:
				best_d = d
				best = v
	return best


# Lets the scene owner inject the planet after _ready (planet may not yet
# exist when the player is constructed, e.g. when both are built in code).
func set_planet(p: Planet) -> void:
	_planet = p


## The planet node — the co-rotating frame for bullets/effects.
func planet_node() -> Planet:
	return _planet


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
	# SpringArm3D places its children at +Z * spring_length (verified
	# empirically), which IS the player's behind — no rotation needed. The old
	# 180° Y-flips actually parked the camera in FRONT of the player, which went
	# unnoticed until the character became visible in WALK mode.
	_spring = SpringArm3D.new()
	_spring.spring_length = camera_distance
	_spring.position = Vector3(0, camera_height, 0)
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
	# The spring puts the camera at +Z (behind the player); the camera's own
	# -Z then already points along the player's forward. No flips.
	_spring.add_child(_camera)
	_camera.position = Vector3.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		var m := event as InputEventMouseMotion
		# ADS slows the look (IKaim parity): half speed, further scaled by zoom.
		var sens := mouse_sensitivity
		if mode == Mode.WALK and aim and aim.is_aiming:
			sens *= 0.5 * (10.0 / aim.current_zoom)
		# Hold Alt in WALK third person = free-look: orbit the camera only,
		# body yaw untouched (IKaim parity; macOS Option also sets alt_pressed).
		if mode == Mode.WALK and walk_third_person \
				and (Input.is_key_pressed(KEY_ALT) or m.alt_pressed):
			_free_look_yaw -= m.relative.x * sens
			_pitch_input = -m.relative.y * sens
			_yaw_input = 0.0
		else:
			_yaw_input   = -m.relative.x * sens
			_pitch_input = -m.relative.y * sens
	elif event.is_action_pressed("ui_cancel"):
		_mouse_captured = not _mouse_captured
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("toggle_mode"):
		_toggle_mode()
	elif mode == Mode.WALK and event is InputEventKey and event.pressed \
			and not event.echo and (event as InputEventKey).keycode == KEY_E:
		var vehicle := _nearby_vehicle()
		if vehicle:
			get_viewport().set_input_as_handled()
			vehicle.mount(self)
	elif mode == Mode.WALK and event is InputEventKey and event.pressed \
			and not event.echo and (event as InputEventKey).keycode == KEY_O:
		# First-person ↔ third-person toggle (IKaim-style).
		walk_third_person = not walk_third_person
		_apply_walk_camera()


func _physics_process(delta: float) -> void:
	match mode:
		Mode.FLIGHT: _flight_step(delta)
		Mode.WALK:   _walk_step(delta)
	if mode == Mode.WALK and aim:
		aim.update_aim(delta)
	_yaw_input = 0.0
	_pitch_input = 0.0


# Feed the character rig's locomotion state machine. `grounded` false = midair.
func _update_locomotion(f: float, s: float, grounded: bool) -> void:
	if rig == null or not rig.is_rig_ready():
		return
	var state : String
	if not grounded or not is_on_floor():
		state = "midair"
	elif f > 0.1 or absf(s) > 0.1:
		state = "walk_fwd"
	elif f < -0.1:
		state = "walk_bwd"
	else:
		state = "idle"
	if aim and aim.is_armed():
		state += "_armed"
	if state != _loco_state:
		_loco_state = state
		rig.play_state(state)
	# Sync clip pace to ground speed (Mixamo walks are ~1.5 m/s) to kill footskate.
	if state.begins_with("walk"):
		var ground_speed := (velocity - up_direction * velocity.dot(up_direction)).length()
		rig.set_speed_scale(clampf(ground_speed / 1.5, 0.5, 2.5) if ground_speed > 0.1 else 1.0)
	else:
		rig.set_speed_scale(1.0)


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
		fwd = fwd.normalized().rotated(up_world, _yaw_input + _pending_recoil_yaw)
		_pending_recoil_yaw = 0.0
		var back := -fwd
		var right := up_world.cross(back).normalized()
		global_transform = Transform3D(Basis(right, up_world, back).orthonormalized(), gpos)

		_cam_pitch = clampf(_cam_pitch + _pitch_input, -1.45, 1.45)
		# Free-look recenters when Alt is released.
		if not Input.is_key_pressed(KEY_ALT) or not walk_third_person:
			_free_look_yaw = move_toward(_free_look_yaw, 0.0, 3.0 * delta)
		if _spring:
			# Unflipped rig: positive spring X-rotation orbits the camera down
			# behind the player and tilts the view UP — matches positive pitch.
			# Spring Y-rotation orbits the camera around the player (free-look).
			_spring.rotation = Vector3(_cam_pitch, _free_look_yaw, 0.0)

		var f := Input.get_axis("move_backward", "move_forward")
		var s := Input.get_axis("move_left", "move_right")
		var gb2 := global_transform.basis
		var move_dir := (-gb2.z * f + gb2.x * s)
		move_dir = move_dir - up_world * move_dir.dot(up_world)
		if move_dir.length_squared() > 0.0:
			move_dir = move_dir.normalized()
		var jump := walk_jump if Input.is_action_just_pressed("move_up") else 0.0
		velocity = move_dir * walk_speed + up_world * jump
		_update_locomotion(f, s, true)
	else:
		# ── Falling: free QUATERNION 6DOF ───────────────────────────────────────
		# No up-alignment while airborne — integrate the body's attitude as a
		# quaternion (mouse = pitch/yaw about the body's own axes, Q/E = roll), which
		# is gimbal-lock-free and composes cleanly. Camera-relative thrust on
		# WASD/Space/Shift; gravity still pulls; light drag. The camera looks straight
		# down the body's forward here (the body carries the attitude).
		if _spring:
			_spring.rotation = Vector3.ZERO
		_update_locomotion(0.0, 0.0, false)
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
	_apply_mode_rig()


func _apply_mode_rig() -> void:
	if _spring == null:
		return
	if aim:
		aim.set_hud_visible(mode == Mode.WALK)
	if mode == Mode.WALK:
		_cam_pitch = 0.0
		_apply_walk_camera()
	else:
		# Third-person follow for flight; pitch goes back onto the body.
		if rig:
			rig.visible = false
		_spring.spring_length = camera_distance
		_spring.position = Vector3(0.0, camera_height, 0.0)
		_spring.rotation = Vector3.ZERO
		if _camera:
			_camera.rotation = Vector3.ZERO
			_camera.position = Vector3.ZERO
			_camera.near = 1.0   # restore the long-range-friendly near plane


# WALK camera: third-person over-the-shoulder, or after [O] first-person at
# eye height. The rig stays visible in BOTH (IKaim-style: in FPP the camera is
# nudged forward of the head so you see the arms/weapon, not the head interior).
# Near plane drops to 0.05 in WALK so the held weapon (~0.4 m away) renders —
# the old near=1.0 constraint (Projection.get_endpoints instability) no longer
# applies, planet.gd computes its view cone from the FOV directly now.
func _apply_walk_camera() -> void:
	if _spring == null or mode != Mode.WALK:
		return
	if rig:
		rig.visible = true
	# The near/far RATIO must stay <= ~2.5M or the engine's shadow-frustum
	# Projection.get_endpoints fails (error spam every frame, costs fps).
	# Third person: near 1.0 / far 2.5M (sun + moon visible).
	# First person: near 0.2 so the held weapon (~0.4 m) renders, far scaled
	# down to 500k to hold the ratio — moon (450k) still visible, only the
	# sun DISC (1.88M) is beyond the far plane in FPP.
	if walk_third_person:
		_spring.spring_length = 3.5
		_spring.position = Vector3(0.0, eye_height + 0.4, 0.0)
		if _camera:
			_camera.position = Vector3.ZERO
			_camera.near = 1.0
			_camera.far = 2500000.0
	else:
		_spring.spring_length = 0.0
		_spring.position = Vector3(0.0, eye_height + 0.05, 0.0)
		if _camera:
			_camera.position = Vector3(0.0, 0.0, -0.22)   # forward of the head
			_camera.near = 0.2
			_camera.far = 500000.0
		_free_look_yaw = 0.0
	_spring.rotation = Vector3(_cam_pitch, _free_look_yaw, 0.0)
	if _camera:
		_camera.rotation = Vector3.ZERO
