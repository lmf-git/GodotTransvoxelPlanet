class_name UpperBodyOverride
extends SkeletonModifier3D

# Applied after AnimationPlayer evaluates, before SkeletonIK3D modifiers.
# Bends spine/neck toward aim pitch, twists toward yaw, raises the shooting
# shoulder, and curls fingers around the grip when armed.

@export var aim_pitch: float = 0.0
@export var aim_yaw: float = 0.0
@export var enabled: bool = false
@export var armed_weight: float = 0.0
@export var two_handed: bool = true  # curl left hand too (rifle); false for pistol

var bone_spine: int = -1
var bone_spine1: int = -1
var bone_spine2: int = -1
var bone_neck: int = -1
var bone_head: int = -1
var bone_right_shoulder: int = -1
var bone_left_shoulder: int = -1

# Cached finger bone IDs to avoid string lookups every frame
var _right_curl_bones: Array[int] = []
var _right_index_bone: int = -1
var _right_thumb_bones: Array[int] = []
var _left_curl_bones: Array[int] = []
var _left_thumb_bones: Array[int] = []

func _ready():
	_cache_bones()

func _cache_bones():
	var sk := get_skeleton()
	if not sk: return
	bone_spine = sk.find_bone("mixamorig_Spine")
	bone_spine1 = sk.find_bone("mixamorig_Spine1")
	bone_spine2 = sk.find_bone("mixamorig_Spine2")
	bone_neck = sk.find_bone("mixamorig_Neck")
	bone_head = sk.find_bone("mixamorig_Head")
	bone_right_shoulder = sk.find_bone("mixamorig_RightShoulder")
	bone_left_shoulder = sk.find_bone("mixamorig_LeftShoulder")

	_right_curl_bones.clear()
	for finger in ["RightHandMiddle", "RightHandRing", "RightHandPinky"]:
		for joint in [1, 2, 3]:
			var b := sk.find_bone("mixamorig_" + finger + str(joint))
			if b != -1: _right_curl_bones.append(b)
	_right_index_bone = sk.find_bone("mixamorig_RightHandIndex1")

	_right_thumb_bones.clear()
	for joint in [1, 2, 3]:
		var b := sk.find_bone("mixamorig_RightHandThumb" + str(joint))
		if b != -1: _right_thumb_bones.append(b)

	_left_curl_bones.clear()
	for finger in ["LeftHandIndex", "LeftHandMiddle", "LeftHandRing", "LeftHandPinky"]:
		for joint in [1, 2, 3]:
			var b := sk.find_bone("mixamorig_" + finger + str(joint))
			if b != -1: _left_curl_bones.append(b)
	_left_thumb_bones.clear()
	for joint in [1, 2, 3]:
		var b := sk.find_bone("mixamorig_LeftHandThumb" + str(joint))
		if b != -1: _left_thumb_bones.append(b)

func _process_modification():
	if not enabled or armed_weight <= 0.001: return
	var sk := get_skeleton()
	if not sk: return
	if bone_spine == -1:
		_cache_bones()
		if bone_spine == -1: return

	var p := aim_pitch * armed_weight
	var y := aim_yaw * armed_weight
	_add_rot(sk, bone_spine,   Quaternion(Vector3.RIGHT, p * 0.20) * Quaternion(Vector3.UP, y * 0.20))
	_add_rot(sk, bone_spine1,  Quaternion(Vector3.RIGHT, p * 0.25) * Quaternion(Vector3.UP, y * 0.25))
	_add_rot(sk, bone_spine2,  Quaternion(Vector3.RIGHT, p * 0.25) * Quaternion(Vector3.UP, y * 0.30))
	_add_rot(sk, bone_neck,    Quaternion(Vector3.RIGHT, p * 0.15) * Quaternion(Vector3.UP, y * 0.10))
	_add_rot(sk, bone_head,    Quaternion(Vector3.RIGHT, p * 0.15) * Quaternion(Vector3.UP, y * 0.15))

	# Raise the shooting shoulder slightly to bring the gun up to the cheek
	_add_rot(sk, bone_right_shoulder, Quaternion(Vector3.FORWARD, deg_to_rad(-12.0) * armed_weight))
	if two_handed:
		_add_rot(sk, bone_left_shoulder, Quaternion(Vector3.FORWARD, deg_to_rad(8.0) * armed_weight))

	# Curl fingers around grip (replace animation pose entirely so the grip is firm).
	# Mixamo finger bones bend around the Z axis at the knuckles.
	var curl1 := deg_to_rad(55.0 * armed_weight)
	var curl2 := deg_to_rad(75.0 * armed_weight)
	for i in _right_curl_bones.size():
		var b := _right_curl_bones[i]
		var joint := i % 3  # 0,1,2 → knuckles 1,2,3
		var amt := curl1 if joint == 0 else curl2
		sk.set_bone_pose_rotation(b, Quaternion(Vector3.UP, amt))
	# Index finger — only slight curl (rests on trigger)
	if _right_index_bone != -1:
		sk.set_bone_pose_rotation(_right_index_bone, Quaternion(Vector3.UP, deg_to_rad(25.0 * armed_weight)))
	# Thumb wraps over the top
	if _right_thumb_bones.size() >= 1:
		sk.set_bone_pose_rotation(_right_thumb_bones[0], Quaternion(Vector3.FORWARD, deg_to_rad(-25.0 * armed_weight)))
	if _right_thumb_bones.size() >= 2:
		sk.set_bone_pose_rotation(_right_thumb_bones[1], Quaternion(Vector3.UP, deg_to_rad(35.0 * armed_weight)))
	if _right_thumb_bones.size() >= 3:
		sk.set_bone_pose_rotation(_right_thumb_bones[2], Quaternion(Vector3.UP, deg_to_rad(35.0 * armed_weight)))

	if two_handed:
		# Left hand: curl all four fingers (including index) — supports the foregrip
		for i in _left_curl_bones.size():
			var b := _left_curl_bones[i]
			var joint := i % 3
			var amt := curl1 if joint == 0 else curl2
			sk.set_bone_pose_rotation(b, Quaternion(Vector3.UP, -amt))
		if _left_thumb_bones.size() >= 1:
			sk.set_bone_pose_rotation(_left_thumb_bones[0], Quaternion(Vector3.FORWARD, deg_to_rad(25.0 * armed_weight)))
		if _left_thumb_bones.size() >= 2:
			sk.set_bone_pose_rotation(_left_thumb_bones[1], Quaternion(Vector3.UP, deg_to_rad(-35.0 * armed_weight)))
		if _left_thumb_bones.size() >= 3:
			sk.set_bone_pose_rotation(_left_thumb_bones[2], Quaternion(Vector3.UP, deg_to_rad(-35.0 * armed_weight)))

func _add_rot(sk: Skeleton3D, bone: int, extra: Quaternion):
	if bone == -1: return
	var current := sk.get_bone_pose_rotation(bone)
	sk.set_bone_pose_rotation(bone, current * extra)
