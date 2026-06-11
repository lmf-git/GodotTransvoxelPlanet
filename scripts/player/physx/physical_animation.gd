## physical_animation.gd
## Drives a set of RigidBody3D nodes toward the pose of an animated reference
## skeleton using Hooke's-law springs.
##
## Set target_skeleton and phys_body_map BEFORE add_child so that _ready()
## fires with valid references already in place.
extends Node3D

## The animated skeleton this system tries to match.
@export var target_skeleton: Skeleton3D

## When false, springs are disabled — bodies are free to fall under gravity.
@export var spring_enabled: bool = true

@export_group("Linear Spring")
@export var linear_stiffness:  float = 600.0
## Low damping so the spring doesn't immediately fight an external impulse.
## The physics body's own linear_damp (0.8) handles long-term velocity decay.
@export var linear_damping:    float = 12.0
## Hard cap on the velocity impulse added per physics step (m/s).
@export var max_linear_force:  float = 30.0
## If a body drifts further than this (metres) teleport it instead of springing.
@export var teleport_threshold: float = 2.0

@export_group("Angular Spring")
@export var angular_stiffness: float = 800.0
## Low damping lets the spring oscillate after an impact (bouncy feel) rather
## than absorbing the impulse in one step.
@export var angular_damping:   float = 20.0
## Hard cap on angular velocity impulse per step (rad/s).
## 300 is needed so the spring can track fast animation arm swings (~5 rad/s peak).
## Per-bone impact response is handled by disable_bone_spring(), not by lowering this.
@export var max_angular_force: float = 300.0

## bone_id (int) → RigidBody3D — populated by main.gd before add_child.
var phys_body_map: Dictionary = {}

## bone_id → seconds remaining for which the spring is disabled on that bone.
## Set via disable_bone_spring() when an external impulse (ball hit) is applied.
var bone_spring_override: Dictionary = {}

## bone_id → previous target origin, for estimating the moving frame velocity.
var _target_prev_origin: Dictionary = {}


func _ready() -> void:
	print("[phys_driver] _ready() — target=%s  bodies=%d" % [
		is_instance_valid(target_skeleton), phys_body_map.size()])


## Temporarily suspend the spring on a single bone so an external impulse
## (ball hit, ragdoll transition) can register without being immediately
## countered.  After duration seconds the spring re-engages at full strength.
func disable_bone_spring(bone_id: int, duration: float) -> void:
	bone_spring_override[bone_id] = duration


func _physics_process(_delta: float) -> void:
	if not spring_enabled:
		return
	if not is_instance_valid(target_skeleton):
		return
	var dt := get_physics_process_delta_time()
	for bone_id: int in phys_body_map:
		var rb: PhysicalBone3D = phys_body_map[bone_id]
		if not is_instance_valid(rb):
			continue
		# Per-bone impact override: let the body react freely for the duration.
		if bone_spring_override.has(bone_id):
			bone_spring_override[bone_id] -= dt
			if bone_spring_override[bone_id] <= 0.0:
				bone_spring_override.erase(bone_id)
			continue
		_apply_spring(bone_id, rb, dt)


func _apply_spring(bone_id: int, rb: PhysicalBone3D, dt: float) -> void:
	var target_xform: Transform3D = (
		target_skeleton.global_transform * target_skeleton.get_bone_global_pose(bone_id))
	var current_xform: Transform3D = rb.global_transform

	# Recover a body whose state went non-finite (joint blow-up): hard reset
	# onto the target pose instead of feeding NaN back into the physics server.
	if not (current_xform.origin.is_finite() and rb.linear_velocity.is_finite()
			and rb.angular_velocity.is_finite()):
		rb.global_transform = target_xform.orthonormalized()
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
		return

	# Target velocity: on this project's SPINNING planet the target skeleton
	# moves metres per physics tick in world space. The spring must work
	# relative to that moving frame or the bones teleport every frame, spin up
	# to the force caps and can blow up into non-finite transforms.
	var tgt_vel := Vector3.ZERO
	if _target_prev_origin.has(bone_id) and dt > 0.0:
		tgt_vel = (target_xform.origin - _target_prev_origin[bone_id]) / dt
	_target_prev_origin[bone_id] = target_xform.origin

	# --- Linear spring (in the target's moving frame) ---
	var pos_diff := target_xform.origin - current_xform.origin
	if pos_diff.length_squared() > teleport_threshold * teleport_threshold:
		rb.global_position = target_xform.origin
		rb.linear_velocity  = tgt_vel
	else:
		var force := _hookes_law(pos_diff, rb.linear_velocity - tgt_vel, linear_stiffness, linear_damping)
		rb.linear_velocity += force.limit_length(max_linear_force) * dt

	# --- Angular spring (quaternion, shortest-path) ---
	# Euler-based rot_diff.get_euler() gives wrong correction directions for large
	# errors (gimbal lock / Euler decomposition artifacts → bone over-rotates then snaps).
	# Quaternion Im-part * 2 gives the correct axis-angle displacement for ANY size error.
	var q_target  := Quaternion(target_xform.basis.orthonormalized())
	var q_current := Quaternion(current_xform.basis.orthonormalized())
	var q_err     := q_target * q_current.inverse()
	# Shortest-path: flip if the scalar part is negative (rotation > 180°).
	if q_err.w < 0.0:
		q_err = -q_err
	var ang_disp  := Vector3(q_err.x, q_err.y, q_err.z) * 2.0
	var torque    := _hookes_law(ang_disp, rb.angular_velocity, angular_stiffness, angular_damping)
	rb.angular_velocity += torque.limit_length(max_angular_force) * dt


func _hookes_law(displacement: Vector3, velocity: Vector3, stiffness: float, damping: float) -> Vector3:
	return (stiffness * displacement) - (damping * velocity)
