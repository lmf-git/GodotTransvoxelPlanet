class_name Aircraft
extends RigidBody3D
## Fixed-wing aircraft — the godotflight reference flight model (lift/drag
## curves, stall, control surfaces, weathervane/pitch/roll stability, wheel
## friction) ported onto this project's planet: gravity is radial, "up" is the
## local surface normal, and the airframe is built procedurally (box meshes)
## so there are no external assets.
##
## Mount: walk within interact range and press [E]; press [E] again to exit.
## Mounted controls: mouse = pitch/roll, [A]/[D] = rudder (nosewheel on the
## ground), [W]/[S] = throttle up/down, throttle 0 = wheel brakes.

const AIR_DENSITY := 1.225
# Measured from the body ORIGIN (mid-fuselage) — must exceed the wingspan half
# plus a step, or standing beside the plane can't reach it ("E does nothing").
const INTERACT_RANGE := 12.0

@export_group("Wing Configuration")
@export var wing_area: float = 20.0
@export var wing_span: float = 10.0
@export var aspect_ratio: float = 6.25

@export_group("Aerodynamics")
@export var cl_0: float = 0.45
@export var cl_alpha: float = 3.4
@export var cl_max: float = 1.8
@export var stall_angle: float = 15.0
@export var cd_0: float = 0.05
@export var oswald_efficiency: float = 0.75

@export_group("Control Surfaces")
@export var elevator_authority: float = 26000.0
@export var aileron_authority: float = 9000.0
@export var rudder_authority: float = 7000.0

@export_group("Engine")
@export var max_thrust: float = 12000.0
@export var throttle_response: float = 0.8

@export_group("Stability")
@export var pitch_stability: float = 0.3
@export var roll_stability: float = 0.3
@export var yaw_stability: float = 0.6
@export var angular_damping_coef: float = 1.5

@export_group("Ground")
@export var nosewheel_steer_angle: float = 45.0
@export var brake_force: float = 20000.0
@export var ground_effect_height: float = 10.0
@export var ground_effect_max_bonus: float = 0.3

var planet : Planet                       # gravity / altitude source
var throttle := 0.0
var elevator_input := 0.0
var aileron_input := 0.0
var rudder_input := 0.0
var is_stalled := false
var airspeed := 0.0
var altitude_agl := 999.0
var angle_of_attack := 0.0
var planet_up := Vector3.UP
var nosewheel_current_angle := 0.0
var mouse_input := Vector2.ZERO
# The planet SPINS (day cycle), so the ground/atmosphere move ~100+ m/s in
# world space at the equator. All aerodynamics and wheel friction therefore
# use velocity RELATIVE to the rotating planet frame; while parked the body
# freezes kinematic so the scene tree carries it with the spin for free.
var rel_velocity := Vector3.ZERO
var _frame_vel := Vector3.ZERO
var _prev_parent_xform := Transform3D.IDENTITY
var _have_prev_xform := false
const MOUSE_SENSITIVITY := 0.003
const MOUSE_RETURN_SPEED := 5.0

var pilot : FlightPlayer = null
var _camera : Camera3D
var _propeller : Node3D
var _prop_spin := 0.0
var _mount_ms := 0   # guards against the mount [E] event also triggering unmount
# Seat (player-feet transform, facing -Z = nose) and control-grip markers for
# the seated character's hand IK.
var _seat : Node3D
var _rh_grip : Node3D
var _lh_grip : Node3D


func _ready() -> void:
	add_to_group("vehicles")
	mass = 1200.0
	collision_layer = 4
	collision_mask = 1            # terrain / buildings / roads
	gravity_scale = 0.0           # custom spherical gravity below
	can_sleep = false
	_build_airframe()
	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 3.2, 11.0)
	_camera.rotation = Vector3(deg_to_rad(-8.0), 0.0, 0.0)
	# near/far ratio must stay <= ~2.5M or the engine's shadow-frustum
	# Projection.get_endpoints fails and spams errors every frame.
	_camera.near = 1.0
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
	mouse_input = Vector2.ZERO
	_mount_ms = Time.get_ticks_msec()
	# Wake from the parked kinematic freeze, co-moving with the surface.
	freeze = false
	linear_velocity = _frame_vel
	angular_velocity = Vector3.ZERO


func unmount() -> void:
	if pilot == null:
		return
	# Drop the pilot beside the left wing root, matched to the aircraft frame.
	var exit_pos := global_transform * Vector3(-2.4, 0.5, 0.0)
	pilot.set_unmounted(exit_pos, global_transform.basis)
	_camera.current = false
	pilot = null
	throttle = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if pilot == null:
		return
	if event is InputEventMouseMotion:
		mouse_input += (event as InputEventMouseMotion).relative * MOUSE_SENSITIVITY
		mouse_input = mouse_input.clamp(Vector2(-1, -1), Vector2(1, 1))
	elif event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_E \
			and Time.get_ticks_msec() - _mount_ms > 300:
		unmount()


# ── Physics ──────────────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	_update_flight_data(delta)
	if freeze:
		return
	# NaN recovery: if the state blew up (e.g. fell through ungenerated terrain
	# and the v² aero forces diverged), reset onto the surface and park instead
	# of spraying non-finite transforms into the scene.
	if not (global_transform.origin.is_finite() and linear_velocity.is_finite()
			and angular_velocity.is_finite()):
		push_warning("Aircraft state went non-finite — resetting onto surface.")
		_reset_on_surface()
		return
	apply_central_force(-planet_up * mass * 9.81)
	if pilot:
		_process_inputs(delta)
	else:
		throttle = 0.0
		elevator_input = 0.0
		aileron_input = 0.0
		rudder_input = 0.0
		# Park: once slow relative to the ground, freeze kinematic so the
		# spinning planet carries the airframe via the scene tree.
		if rel_velocity.length() < 0.6 and altitude_agl < 3.0:
			freeze = true
			return
	_apply_flight_physics(delta)
	if pilot:
		pilot.update_seated(_rh_grip, _lh_grip, delta)
	if _propeller:
		_prop_spin += (2.0 + throttle * 50.0) * delta
		_propeller.rotation.z = _prop_spin


func _update_flight_data(delta: float) -> void:
	# Velocity of the rotating planet frame at our position: where a point
	# fixed to the parent that is here NOW was one tick ago.
	var parent := get_parent() as Node3D
	if parent:
		var px := parent.global_transform
		if _have_prev_xform and delta > 0.0:
			var prev_pos := _prev_parent_xform * (px.affine_inverse() * global_position)
			_frame_vel = (global_position - prev_pos) / delta
		_prev_parent_xform = px
		_have_prev_xform = true
	rel_velocity = linear_velocity - _frame_vel
	airspeed = rel_velocity.length()
	if planet:
		planet_up = -planet.gravity_dir(global_position)
		altitude_agl = planet.altitude_above_surface(global_position)
	angle_of_attack = _calculate_aoa()


func _calculate_aoa() -> float:
	if airspeed < 2.0:
		return 0.0
	var local_vel := global_transform.basis.inverse() * rel_velocity
	return rad_to_deg(atan2(local_vel.y, -local_vel.z))


func _process_inputs(delta: float) -> void:
	var th := 0.0
	if Input.is_action_pressed("move_forward"):
		th = 1.0
	elif Input.is_action_pressed("move_backward"):
		th = -1.0
	throttle = clampf(throttle + th * throttle_response * delta, 0.0, 1.0)

	# Mouse Y pulls back = pitch up; X rolls. Inputs spring back to centre.
	elevator_input = clampf(-mouse_input.y, -1.0, 1.0)
	aileron_input = clampf(mouse_input.x, -1.0, 1.0)
	mouse_input = mouse_input.move_toward(Vector2.ZERO, MOUSE_RETURN_SPEED * delta * 0.4)

	# Rudder authority shrinks with speed (full deflection = ground steering).
	var raw_rudder := -Input.get_axis("move_left", "move_right")
	var rudder_limit := clampf(lerpf(1.0, 0.15, airspeed / 80.0), 0.15, 1.0)
	rudder_input = raw_rudder * rudder_limit


func _reset_on_surface() -> void:
	var anchor : Vector3 = pilot.global_position if pilot else Vector3.ZERO
	var up := Vector3.UP
	if planet:
		up = -planet.gravity_dir(anchor)
		var alt := planet.altitude_above_surface(anchor)
		anchor = anchor - up * (alt - 2.0)
	var fwd := up.cross(Vector3.RIGHT).normalized()
	if fwd.length_squared() < 1e-4:
		fwd = up.cross(Vector3.FORWARD).normalized()
	global_transform = Transform3D(Basis(up.cross(-fwd), up, -fwd).orthonormalized(), anchor)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	if pilot == null:
		freeze = true


func _apply_flight_physics(delta: float) -> void:
	var forward := -global_transform.basis.z
	var up := global_transform.basis.y
	var right := global_transform.basis.x
	# Cap the airspeed used for force computation: past ~200 m/s the v² terms
	# combined with the fixed timestep overshoot and diverge (seen when falling
	# through ungenerated terrain). Real flight stays far below the cap.
	var airspeed_eff := minf(airspeed, 200.0)
	var dynamic_pressure := 0.5 * AIR_DENSITY * airspeed_eff * airspeed_eff

	# === LIFT ===
	var cl := _calculate_lift_coefficient(angle_of_attack)
	var lift_magnitude := dynamic_pressure * wing_area * cl
	lift_magnitude *= 1.0 + _ground_effect()
	var lift_direction := planet_up
	if airspeed > 1.0:
		lift_direction = rel_velocity.normalized().cross(right).normalized()
		if lift_direction.dot(up) < 0.0:
			lift_direction = -lift_direction
	apply_central_force(lift_direction * lift_magnitude)

	# === DRAG === (parasitic + induced + high-AoA form + post-stall penalty)
	var cd := cd_0 + (cl * cl) / (PI * oswald_efficiency * aspect_ratio)
	cd += 0.12   # fixed gear
	var aoa_rad_abs := deg_to_rad(absf(angle_of_attack))
	var form_drag := sin(aoa_rad_abs)
	cd += 0.25 * form_drag * form_drag
	if is_stalled:
		cd += 0.15 * (absf(angle_of_attack) - stall_angle) / 10.0
	if airspeed > 0.1:
		apply_central_force(-rel_velocity.normalized() * dynamic_pressure * wing_area * cd)

	# === THRUST ===
	apply_central_force(forward * max_thrust * throttle)

	# === STALL PITCH-DOWN MOMENT ===
	var abs_aoa := absf(angle_of_attack)
	if abs_aoa > stall_angle and airspeed > 5.0:
		var stall_excess := clampf((abs_aoa - stall_angle) / 20.0, 0.0, 1.0)
		apply_torque(right * (-signf(angle_of_attack) * stall_excess
				* dynamic_pressure * wing_area * 0.25))

	# === CONTROL SURFACES === (authority scales with dynamic pressure)
	var control_effectiveness := clampf(dynamic_pressure / 2000.0, 0.08, 1.0)
	if abs_aoa > stall_angle:
		control_effectiveness *= 1.0 - clampf((abs_aoa - stall_angle) / 25.0, 0.0, 0.4)
	apply_torque(right * elevator_input * elevator_authority * control_effectiveness)
	apply_torque(forward * aileron_input * aileron_authority * control_effectiveness)
	apply_torque(up * rudder_input * rudder_authority * control_effectiveness)

	# === CROSS-FLOW DRAG === keeps the velocity vector glued to the nose
	if airspeed > 1.0:
		var v_along := rel_velocity.dot(forward)
		var v_cross := rel_velocity - forward * v_along
		var cross_speed := v_cross.length()
		if cross_speed > 0.1:
			var cross_q := 0.5 * AIR_DENSITY * cross_speed * cross_speed
			apply_central_force(-v_cross.normalized() * cross_q * 15.0)

	# === MANEUVERING DRAG ===
	var angular_speed_sq := angular_velocity.length_squared()
	if angular_speed_sq > 0.01 and airspeed > 5.0:
		apply_central_force(-rel_velocity.normalized()
				* angular_speed_sq * dynamic_pressure * wing_area * 0.006)

	# === AERODYNAMIC RATE DAMPING ===
	var aero_damp := clampf(airspeed / 30.0, 0.0, 1.5)
	apply_torque(-up      * angular_velocity.dot(up)      * mass * 4.0 * aero_damp)
	apply_torque(-right   * angular_velocity.dot(right)   * mass * 2.5 * aero_damp)
	apply_torque(-forward * angular_velocity.dot(forward) * mass * 0.8 * aero_damp)

	_apply_ground_forces()
	_apply_stability(delta, up, forward, right)
	apply_torque(-angular_velocity * angular_damping_coef * mass)


func _calculate_lift_coefficient(aoa: float) -> float:
	var aoa_rad := deg_to_rad(aoa)
	if absf(aoa) < stall_angle:
		is_stalled = false
		return clampf(cl_0 + cl_alpha * aoa_rad, -cl_max, cl_max)
	is_stalled = true
	var stall_cl := cl_0 + cl_alpha * deg_to_rad(stall_angle) * signf(aoa)
	var dropoff := clampf(1.0 - (absf(aoa) - stall_angle) / 30.0, 0.3, 1.0)
	return stall_cl * dropoff


func _ground_effect() -> float:
	if altitude_agl > ground_effect_height:
		return 0.0
	var ratio := 1.0 - altitude_agl / ground_effect_height
	return ground_effect_max_bonus * ratio * ratio


func _apply_stability(_delta: float, up: Vector3, forward: Vector3, right: Vector3) -> void:
	var maneuver_scale := clampf(1.0 - angular_velocity.length() / 1.2, 0.0, 1.0)

	# Weathervane: the fin yaws the nose into the relative wind.
	var local_vel := global_transform.basis.inverse() * rel_velocity
	if local_vel.length() > 5.0:
		var sideslip := atan2(local_vel.x, -local_vel.z)
		apply_torque(-up * sideslip * yaw_stability * mass)

	# Pitch-to-level when controls are centred.
	var fwd_horiz := (forward - forward.dot(planet_up) * planet_up).normalized()
	var pitch_angle := forward.angle_to(fwd_horiz) if fwd_horiz.length() > 0.01 else 0.0
	if forward.dot(planet_up) < 0.0:
		pitch_angle = -pitch_angle
	if absf(elevator_input) < 0.1 and absf(angular_velocity.dot(right)) < 0.3:
		var pitch_factor := clampf(1.0 - absf(pitch_angle), 0.0, 1.0)
		apply_torque(right * (-pitch_angle * pitch_stability * mass * 0.05
				* pitch_factor * maneuver_scale))

	# Roll-to-level, backed off while rolling so aerobatics stay possible.
	var roll_damp := clampf(1.0 - absf(angular_velocity.dot(forward)) / 0.8, 0.0, 1.0)
	if absf(aileron_input) < 0.1:
		var roll_angle := up.signed_angle_to(planet_up, forward)
		apply_torque(forward * (-roll_angle * roll_stability * mass * 0.05 * roll_damp))


func _apply_ground_forces() -> void:
	if altitude_agl > 2.5 or rel_velocity.dot(planet_up) > 1.5:
		return
	var fwd := -global_transform.basis.z
	var right := global_transform.basis.x

	# Wheel lateral grip; nosewheel direction follows rudder steering.
	var steer_rad := rudder_input * deg_to_rad(nosewheel_steer_angle) if pilot else 0.0
	nosewheel_current_angle = steer_rad
	var max_grip := mass * 9.81 * 0.8 / 3.0
	var laterals : Array[Vector3] = [right.rotated(planet_up, steer_rad), right, right]
	var offsets : Array[Vector3] = [Vector3(0, -1.0, -2.4), Vector3(-1.6, -1.0, 0.8), Vector3(1.6, -1.0, 0.8)]
	for i in 3:
		var lat_dir := laterals[i]
		var lat_speed := lat_dir.dot(rel_velocity)
		if absf(lat_speed) > 0.05:
			var grip := minf(absf(lat_speed) * mass * 20.0, max_grip)
			apply_force(-lat_dir * signf(lat_speed) * grip, global_transform.basis * offsets[i])

	# Brakes whenever throttle is closed.
	if throttle < 0.01 and airspeed > 0.5:
		var fspeed := rel_velocity.dot(fwd)
		apply_central_force(-fwd * signf(fspeed)
				* brake_force * clampf(absf(fspeed) / 5.0, 0.0, 1.0))


# ── Procedural airframe (box-mesh warbird, no external assets) ───────────────

func _build_airframe() -> void:
	var body_mat := _mat(Color(0.75, 0.76, 0.78), 0.4, 0.5)
	var wing_mat := _mat(Color(0.68, 0.70, 0.74), 0.3, 0.6)
	var dark_mat := _mat(Color(0.15, 0.15, 0.16), 0.2, 0.7)

	# Fuselage (origin ~CG; nose toward -Z)
	_box_part(Vector3(1.1, 1.1, 5.4), Vector3(0, 0.2, -0.4), body_mat)
	_box_part(Vector3(0.8, 0.8, 2.6), Vector3(0, 0.35, 3.2), body_mat)   # tail boom
	# Bubble canopy — transparent glass so the seated pilot is visible inside.
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.45, 0.65, 0.75, 0.28)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.metallic = 0.4
	glass.roughness = 0.05
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	_box_part(Vector3(1.0, 1.0, 1.7), Vector3(0, 1.35, -0.8), glass)

	# Seat (player feet on the fuselage top, facing the nose) + control grips.
	_seat = Node3D.new()
	_seat.name = "SeatPoint"
	_seat.position = Vector3(0, 0.78, -0.7)
	add_child(_seat)
	_rh_grip = Node3D.new()
	_rh_grip.name = "RHandGrip"
	_rh_grip.position = Vector3(0.16, 1.65, -1.45)
	add_child(_rh_grip)
	_lh_grip = Node3D.new()
	_lh_grip.name = "LHandGrip"
	_lh_grip.position = Vector3(-0.16, 1.65, -1.45)
	add_child(_lh_grip)
	# Wings
	_box_part(Vector3(4.6, 0.16, 1.7), Vector3(-3.2, 0.15, 0.2), wing_mat)
	_box_part(Vector3(4.6, 0.16, 1.7), Vector3(3.2, 0.15, 0.2), wing_mat)
	# Tail
	_box_part(Vector3(3.4, 0.12, 1.0), Vector3(0, 0.4, 4.3), wing_mat)   # horizontal stab
	_box_part(Vector3(0.12, 1.5, 1.1), Vector3(0, 1.1, 4.3), wing_mat)   # fin
	# Propeller hub + blades (spins in _physics_process)
	_propeller = Node3D.new()
	_propeller.position = Vector3(0, 0.2, -3.2)
	add_child(_propeller)
	for ang in [0.0, PI * 0.5]:
		var blade := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.18, 2.6, 0.06)
		blade.mesh = bm
		blade.material_override = dark_mat
		blade.rotation = Vector3(0, 0, ang)
		_propeller.add_child(blade)

	# Collision: fuselage + wings (one body, simple boxes)
	_col_box(Vector3(1.1, 1.1, 5.4), Vector3(0, 0.2, -0.4))
	_col_box(Vector3(11.0, 0.2, 1.7), Vector3(0, 0.15, 0.2))
	_col_box(Vector3(3.4, 1.6, 1.1), Vector3(0, 0.7, 4.3))
	# Wheels (spheres, fixed gear): nose + two mains
	for off in [Vector3(0, -1.0, -2.4), Vector3(-1.6, -1.0, 0.8), Vector3(1.6, -1.0, 0.8)]:
		var ws := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 0.35
		ws.shape = sph
		ws.position = off
		add_child(ws)
		var wm := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.35
		sm.height = 0.7
		wm.mesh = sm
		wm.material_override = dark_mat
		wm.position = off
		add_child(wm)
		var strut := MeshInstance3D.new()
		var stm := BoxMesh.new()
		stm.size = Vector3(0.12, 1.0, 0.12)
		strut.mesh = stm
		strut.material_override = dark_mat
		strut.position = off + Vector3(0, 0.55, 0)
		add_child(strut)


func _mat(c: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metallic
	m.roughness = roughness
	return m


func _box_part(size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	add_child(mi)


func _col_box(size: Vector3, pos: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	add_child(cs)
