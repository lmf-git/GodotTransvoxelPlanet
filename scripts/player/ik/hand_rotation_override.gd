class_name HandRotationOverride
extends SkeletonModifier3D

# Runs AFTER SkeletonIK3D. The IK only matches the hand POSITION reliably in
# Godot 4 — this modifier forces the hand bone's global orientation to a
# specified basis so the weapon orientation is deterministic.

@export var enabled: bool = false
@export var weight: float = 0.0
@export var bone_name: String = "mixamorig_RightHand"
@export var target_basis: Basis = Basis.IDENTITY
@export var second_bone_name: String = ""
@export var second_target_basis: Basis = Basis.IDENTITY

var _bone: int = -1
var _bone2: int = -1

func _ready():
	_cache()

func _cache():
	var sk := get_skeleton()
	if not sk: return
	_bone = sk.find_bone(bone_name)
	_bone2 = -1 if second_bone_name.is_empty() else sk.find_bone(second_bone_name)

func _process_modification():
	if not enabled or weight <= 0.001: return
	var sk := get_skeleton()
	if not sk: return
	if _bone == -1:
		_cache()
		if _bone == -1: return

	_apply(sk, _bone, target_basis)
	if _bone2 != -1:
		_apply(sk, _bone2, second_target_basis)

func _apply(sk: Skeleton3D, bone: int, target_b: Basis):
	# Compose target global pose: keep IK-set origin, override basis.
	var current := sk.get_bone_global_pose(bone)
	var desired_global := Transform3D(target_b, current.origin)

	# Convert desired global → bone local pose (relative to parent's global pose)
	var parent := sk.get_bone_parent(bone)
	var parent_global := Transform3D.IDENTITY if parent == -1 else sk.get_bone_global_pose(parent)
	var local := parent_global.affine_inverse() * desired_global

	if weight >= 0.999:
		sk.set_bone_pose_position(bone, local.origin)
		sk.set_bone_pose_rotation(bone, local.basis.get_rotation_quaternion())
	else:
		# Blend with current pose for smooth transitions
		var current_local_pos := sk.get_bone_pose_position(bone)
		var current_local_rot := sk.get_bone_pose_rotation(bone)
		var target_rot := local.basis.get_rotation_quaternion()
		sk.set_bone_pose_position(bone, current_local_pos.lerp(local.origin, weight))
		sk.set_bone_pose_rotation(bone, current_local_rot.slerp(target_rot, weight))
