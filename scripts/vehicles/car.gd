class_name Car
extends RigidBody3D
## Arcade car — godotflight's car model (raycast spring/damper suspension,
## rear-wheel throttle, Ackermann-style steer torque, lateral tire grip with
## slip falloff) ported onto the planet: radial gravity, all forces computed
## relative to the spinning planet frame, kinematic freeze while parked.
##
## Mount: walk within range and press [E]; [E] again to exit.
## Driving: [W]/[S] throttle / brake-reverse, [A]/[D] steer.

const INTERACT_RANGE := 7.0   # from body origin; covers standing at either bumper

@export_group("Engine")
@export var engine_power: float = 20000.0
@export var brake_power: float = 25000.0
@export var max_speed: float = 35.0

@export_group("Steering")
@export var steering_speed: float = 4.0
@export var max_steer_angle: float = 35.0
@export var steering_return_speed: float = 6.0
@export var wheelbase: float = 2.6

@export_group("Wheels")
@export var wheel_grip: float = 30.0
@export var slip_threshold: float = 4.0

@export_group("Suspension")
@export var spring_stiffness: float = 35000.0
@export var damping_coefficient: float = 4500.0
@export var suspension_travel: float = 0.25
@export var wheel_radius: float = 0.3

var planet : Planet
var pilot : FlightPlayer = null
var throttle_input := 0.0
var brake_input := 0.0
var steer_input := 0.0
var current_steer := 0.0
var planet_up := Vector3.UP

# Co-rotating planet frame (see aircraft.gd — the surface moves ~100+ m/s).
var rel_velocity := Vector3.ZERO
var _frame_vel := Vector3.ZERO
var _prev_parent_xform := Transform3D.IDENTITY
var _have_prev_xform := false
var _mount_ms := 0

var _camera : Camera3D
var _susp_rays : Array[RayCast3D] = []
var _wheel_pivots : Array[Node3D] = []
var _seat : Node3D
var _rh_grip : Node3D
var _lh_grip : Node3D
var _prev_compression : Array[float] = [0.0, 0.0, 0.0, 0.0]
var _altitude_ok := false   # any suspension ray touching ground


func _ready() -> void:
	add_to_group("vehicles")
	mass = 1500.0
	collision_layer = 4
	collision_mask = 1
	gravity_scale = 0.0
	can_sleep = false
	_build_body()
	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 2.6, 7.0)
	_camera.rotation = Vector3(deg_to_rad(-10.0), 0.0, 0.0)
	_camera.near = 1.0   # keep near/far ratio <= ~2.5M (see aircraft.gd)
	_camera.far = 2500000.0
	_camera.current = false
	add_child(_camera)


# ── Mounting ─────────────────────────────────────────────────────────────────

func can_mount(p: FlightPlayer) -> bool:
	return pilot == null and p.global_position.distance_to(global_position) < INTERACT_RANGE


func mount(p: FlightPlayer) -> void:
	pilot = p
	pilot.set_mounted(self, _seat)
	_camera.current = true
	_mount_ms = Time.get_ticks_msec()
	freeze = false
	linear_velocity = _frame_vel
	angular_velocity = Vector3.ZERO


func unmount() -> void:
	if pilot == null:
		return
	var exit_pos := global_transform * Vector3(-1.8, 0.6, 0.0)
	pilot.set_unmounted(exit_pos, global_transform.basis)
	_camera.current = false
	pilot = null


func _unhandled_input(event: InputEvent) -> void:
	if pilot == null:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_E \
			and Time.get_ticks_msec() - _mount_ms > 300:
		unmount()


# ── Physics ──────────────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	_update_frame(delta)
	if freeze:
		return
	# NaN recovery (see aircraft.gd) — reset instead of spreading non-finite state.
	if not (global_transform.origin.is_finite() and linear_velocity.is_finite()
			and angular_velocity.is_finite()):
		push_warning("Car state went non-finite — resetting onto surface.")
		_reset_on_surface()
		return
	apply_central_force(-planet_up * mass * 9.81)
	_apply_suspension(delta)
	if pilot:
		_process_inputs(delta)
		_apply_drive()
	else:
		throttle_input = 0.0
		brake_input = 0.0
		steer_input = 0.0
		current_steer = move_toward(current_steer, 0.0,
				steering_return_speed * max_steer_angle * delta)
		# Hard brake + kill spin, then park frozen so the planet carries us.
		if rel_velocity.length() > 0.2:
			apply_central_force(-rel_velocity.normalized() * brake_power)
		if angular_velocity.length() > 0.05:
			apply_torque(-angular_velocity * mass * 5.0)
		if rel_velocity.length() < 0.5 and _altitude_ok:
			freeze = true
			return
	_apply_passive_physics()
	if pilot:
		pilot.update_seated(_rh_grip, _lh_grip, delta)
	# Front wheel pivots show the steering angle (wheel spin is invisible on a
	# symmetric cylinder, so only steer is animated).
	for i in 2:
		if i < _wheel_pivots.size() and _wheel_pivots[i]:
			_wheel_pivots[i].rotation.y = deg_to_rad(current_steer)


func _reset_on_surface() -> void:
	var anchor : Vector3 = pilot.global_position if pilot else Vector3.ZERO
	var up := Vector3.UP
	if planet:
		up = -planet.gravity_dir(anchor)
		var alt := planet.altitude_above_surface(anchor)
		anchor = anchor - up * (alt - 1.2)
	var fwd := up.cross(Vector3.RIGHT).normalized()
	if fwd.length_squared() < 1e-4:
		fwd = up.cross(Vector3.FORWARD).normalized()
	global_transform = Transform3D(Basis(up.cross(-fwd), up, -fwd).orthonormalized(), anchor)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	if pilot == null:
		freeze = true


func _update_frame(delta: float) -> void:
	var parent := get_parent() as Node3D
	if parent:
		var px := parent.global_transform
		if _have_prev_xform and delta > 0.0:
			var prev_pos := _prev_parent_xform * (px.affine_inverse() * global_position)
			_frame_vel = (global_position - prev_pos) / delta
		_prev_parent_xform = px
		_have_prev_xform = true
	rel_velocity = linear_velocity - _frame_vel
	if planet:
		planet_up = -planet.gravity_dir(global_position)


func _process_inputs(delta: float) -> void:
	throttle_input = 0.0
	brake_input = 0.0
	var forward_speed := (-global_transform.basis.z).dot(rel_velocity)
	if Input.is_action_pressed("move_forward"):
		if forward_speed < -1.0:
			brake_input = 1.0
		else:
			throttle_input = 1.0
	if Input.is_action_pressed("move_backward"):
		if forward_speed > 1.0:
			brake_input = 1.0
		else:
			throttle_input = -1.0

	steer_input = Input.get_axis("move_right", "move_left")
	var target_steer := steer_input * max_steer_angle
	if absf(steer_input) > 0.1:
		current_steer = move_toward(current_steer, target_steer,
				steering_speed * max_steer_angle * delta)
	else:
		current_steer = move_toward(current_steer, 0.0,
				steering_return_speed * max_steer_angle * delta)


func _apply_drive() -> void:
	var forward := -global_transform.basis.z
	var up := global_transform.basis.y
	var forward_speed := forward.dot(rel_velocity)

	# Throttle (rear wheels)
	if throttle_input != 0.0:
		var speed_limit := max_speed if throttle_input > 0.0 else max_speed * 0.4
		if forward_speed * signf(throttle_input) < speed_limit:
			var power := engine_power if throttle_input > 0.0 else engine_power * 0.5
			apply_central_force(forward * power * throttle_input)

	# Braking
	var speed := rel_velocity.length()
	if brake_input > 0.0 and speed > 0.5:
		apply_central_force(-rel_velocity.normalized() * brake_power * brake_input)

	# Steering: drive yaw rate toward the Ackermann turn rate.
	if absf(current_steer) > 0.5 and absf(forward_speed) > 0.5:
		var steer_rad := deg_to_rad(current_steer)
		var target_omega := forward_speed * tan(steer_rad) / wheelbase
		var omega_diff := target_omega - angular_velocity.dot(up)
		apply_torque(up * omega_diff * mass * 1.2)

	# Cornering speed loss
	if absf(current_steer) > 1.0 and speed > 2.0:
		var steer_factor := absf(current_steer) / max_steer_angle
		apply_central_force(-rel_velocity.normalized() * speed * steer_factor * mass * 0.5)


func _apply_passive_physics() -> void:
	var right := global_transform.basis.x
	var speed := rel_velocity.length()

	# Lateral tire grip applied at wheel positions (gives body roll); grip
	# fades past the slip threshold so the car can actually slide.
	var lateral_velocity := right.dot(rel_velocity)
	var grip_per_wheel := wheel_grip / 4.0
	if absf(lateral_velocity) > slip_threshold:
		grip_per_wheel *= slip_threshold / absf(lateral_velocity)
	for ray in _susp_rays:
		if ray.is_colliding():
			apply_force(-right * lateral_velocity * grip_per_wheel * mass,
					ray.global_position - global_position)

	if speed > 0.1:
		apply_central_force(-rel_velocity.normalized() * mass * 1.5)   # rolling resistance
	apply_central_force(-rel_velocity * speed * 0.5)                   # quadratic air drag
	apply_torque(-angular_velocity * mass * 3.0)


func _apply_suspension(delta: float) -> void:
	var ray_length := suspension_travel + wheel_radius
	_altitude_ok = false
	for i in _susp_rays.size():
		var ray := _susp_rays[i]
		if not ray.is_colliding():
			_prev_compression[i] = 0.0
			continue
		_altitude_ok = true
		var hit_distance := ray.global_position.distance_to(ray.get_collision_point())
		var compression := clampf(ray_length - hit_distance, 0.0, suspension_travel)
		var compression_velocity := (compression - _prev_compression[i]) / delta
		_prev_compression[i] = compression
		var force_magnitude := maxf(
				compression * spring_stiffness + compression_velocity * damping_coefficient, 0.0)
		apply_force(ray.get_collision_normal() * force_magnitude,
				ray.global_position - global_position)
		if i < _wheel_pivots.size() and _wheel_pivots[i]:
			_wheel_pivots[i].position.y = ray.position.y - hit_distance + wheel_radius


# ── Procedural body ──────────────────────────────────────────────────────────

func _build_body() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.65, 0.25, 0.12)
	body_mat.metallic = 0.6
	body_mat.roughness = 0.35
	var dark_mat := StandardMaterial3D.new()
	dark_mat.albedo_color = Color(0.1, 0.1, 0.1)
	dark_mat.roughness = 0.8

	# Chassis + cabin (nose toward -Z)
	var chassis := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(1.8, 0.6, 4.0)
	chassis.mesh = cm
	chassis.material_override = body_mat
	chassis.position = Vector3(0, 0.5, 0)
	add_child(chassis)
	# Glass cabin tall enough for the seated driver, transparent so they show.
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.4, 0.55, 0.62, 0.30)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.metallic = 0.3
	glass.roughness = 0.08
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cabin := MeshInstance3D.new()
	var cab := BoxMesh.new()
	cab.size = Vector3(1.6, 1.25, 1.9)
	cabin.mesh = cab
	cabin.material_override = glass
	cabin.position = Vector3(0, 1.4, 0.2)
	add_child(cabin)

	# Driver seat (left side, feet on the chassis floor) + steering grips.
	_seat = Node3D.new()
	_seat.name = "SeatPoint"
	_seat.position = Vector3(-0.4, 0.82, 0.15)
	add_child(_seat)
	_rh_grip = Node3D.new()
	_rh_grip.name = "RHandGrip"
	_rh_grip.position = Vector3(-0.25, 1.55, -0.4)
	add_child(_rh_grip)
	_lh_grip = Node3D.new()
	_lh_grip.name = "LHandGrip"
	_lh_grip.position = Vector3(-0.55, 1.55, -0.4)
	add_child(_lh_grip)

	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(1.8, 0.9, 4.0)
	cs.shape = bs
	cs.position = Vector3(0, 0.65, 0)
	add_child(cs)

	# Suspension rays + wheel visuals (FL, FR, RL, RR)
	var mounts := [
		Vector3(-0.85, 0.3, -1.3), Vector3(0.85, 0.3, -1.3),
		Vector3(-0.85, 0.3, 1.3),  Vector3(0.85, 0.3, 1.3),
	]
	for m in mounts:
		var ray := RayCast3D.new()
		ray.position = m
		ray.target_position = Vector3(0, -(suspension_travel + wheel_radius), 0)
		ray.collision_mask = 1
		ray.enabled = true
		add_child(ray)
		_susp_rays.append(ray)
		var pivot := Node3D.new()
		pivot.position = m + Vector3(0, -suspension_travel, 0)
		add_child(pivot)
		_wheel_pivots.append(pivot)
		var wheel := MeshInstance3D.new()
		var wm := CylinderMesh.new()
		wm.top_radius = wheel_radius
		wm.bottom_radius = wheel_radius
		wm.height = 0.25
		wheel.mesh = wm
		wheel.material_override = dark_mat
		wheel.rotation = Vector3(0, 0, PI * 0.5)   # cylinder axis → car X (axle)
		pivot.add_child(wheel)
