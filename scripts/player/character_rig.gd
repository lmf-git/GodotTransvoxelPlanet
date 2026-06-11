class_name CharacterRig
extends Node3D
## Three-rig physX animation driver (ported from the PhysxAnimationTest /
## interiorplanetary reference projects).
##
##   AnimatedRig (ghost)   — drives the AnimationPlayer; meshes invisible.
##   PhysicsRig (hidden)   — PhysicalBone3D capsules sprung toward the animated
##                           pose every physics tick (physical_animation.gd).
##   VisualRig (visible)   — blends animated ↔ physics pose per bone
##                           (interpolated_animation.gd).
##
## The rig is a plain child of FlightPlayer at the body origin (feet), rotated
## 180° on Y so the Mixamo model's +Z forward matches the player's -Z forward.
## SkeletonIK3D aim modifiers (aim_controller.gd) attach to the ANIMATED
## skeleton; the visual rig copies the post-modifier result, so IK carries
## through the blend automatically.

const MASTER_PATH   := "res://characters/Master.fbx"
const PHYS_SCRIPT   := "res://scripts/player/physx/physical_animation.gd"
const INTERP_SCRIPT := "res://scripts/player/physx/interpolated_animation.gd"

const SKIP_BONE_FRAGMENTS: Array[String] = [
	"ik", "pole", "ctrl", "_end",
	"index", "middle", "ring", "pinky", "thumb", "toe",
	"hand", "foot", "neck", "shoulder",
]

# Locomotion state → preferred animation names (first match wins). Armed
# variants come from the IKaim reference (rifle walk / aim idle clips).
const STATE_SEARCH: Dictionary = {
	"idle":             ["unarmed idle 01", "unarmed idle"],
	"walk_fwd":         ["unarmed walk forward", "unarmed walk"],
	"walk_bwd":         ["run backwards", "unarmed walk forward"],
	"run":              ["unarmed run forward", "run forward"],
	"sprint":           ["standing run forward", "unarmed run forward"],
	"midair":           ["jumping down-2", "jumping down-3", "jumping down"],
	"idle_armed":       ["standing aim idle 01", "unarmed idle 01"],
	"walk_fwd_armed":   ["walk with rifle", "unarmed walk forward"],
	"walk_bwd_armed":   ["backwards rifle walk", "walk with rifle"],
	"run_armed":        ["walk with rifle", "unarmed run forward"],
	"midair_armed":     ["jumping down-2", "jumping down"],
	"sit":              ["male sitting pose", "sitting"],
}

## States during which the springs disengage and the visual rig blends to
## full ragdoll (kept from the reference; none are triggered by the basic
## walk controller yet, but play_state("ragdoll") works out of the box).
const PHYSX_STATES: Array[String] = ["ragdoll"]

# Rig roots / skeletons
var _anim_root: Node3D
var _phys_root: Node3D
var _vis_root:  Node3D
var anim_skeleton: Skeleton3D
var _phys_skeleton: Skeleton3D
var _vis_skeleton:  Skeleton3D

var _simulator:   PhysicalBoneSimulator3D
var anim_player: AnimationPlayer
var _phys_driver: Node3D
var _vis_driver:  Node3D

var _phys_bone_map:  Dictionary = {}   # bone_id (int) → PhysicalBone3D
var _anim_keys:      Array[String] = []
var _state_anim_map: Dictionary = {}
var _current_state:  String = ""
var _ready_complete: bool = false

signal rig_ready


func _ready() -> void:
	# 1. AnimatedRig — invisible ghost, drives animation
	_anim_root = _load_master("AnimatedRig")
	anim_skeleton = _find_skeleton(_anim_root)
	_make_ghost(_anim_root)
	_setup_animation_player(_anim_root)

	# 2. PhysicsRig — invisible, PhysicalBone3D simulation
	_phys_root = _load_master("PhysicsRig")
	_phys_skeleton = _find_skeleton(_phys_root)
	_hide_meshes(_phys_root)
	_build_physics_bones()

	# 3. VisualRig — visible blended output
	_vis_root = _load_master("VisualRig")
	_vis_skeleton = _find_skeleton(_vis_root)

	_build_state_map()
	if not _anim_keys.is_empty():
		_current_state = "idle"
		anim_player.play(_state_anim_map.get("idle", _anim_keys[0]))

	# Wait for PhysicsServer to register the new bodies, then start simulation.
	await get_tree().physics_frame
	if is_instance_valid(_simulator):
		_simulator.active = true
		_fix_joint_frames()
		_simulator.physical_bones_start_simulation()
		await get_tree().process_frame
		await get_tree().physics_frame
		await get_tree().physics_frame
		_apply_collision_exceptions()

	# PhysDriver: Hooke springs push phys bones toward anim skeleton
	_phys_driver = Node3D.new()
	_phys_driver.name = "PhysDriver"
	_phys_driver.set_script(load(PHYS_SCRIPT))
	_phys_driver.set("target_skeleton", anim_skeleton)
	_phys_driver.set("phys_body_map",   _phys_bone_map)
	_phys_driver.set("spring_enabled",  true)
	_phys_root.add_child(_phys_driver)

	# VisDriver: blend anim + phys → visual skeleton
	_vis_driver = Node3D.new()
	_vis_driver.name = "BoneDriver"
	_vis_driver.set_script(load(INTERP_SCRIPT))
	_vis_driver.set("visual_skeleton",   _vis_skeleton)
	_vis_driver.set("animated_skeleton", anim_skeleton)
	_vis_driver.set("physics_skeleton",  _phys_skeleton)
	_vis_driver.set("physics_blend",     0.0)
	_vis_driver.set("phys_bone_map",     _phys_bone_map)
	_vis_root.add_child(_vis_driver)

	_ready_complete = true
	rig_ready.emit()
	print("[CharacterRig] 3-rig physX ready — anims: %d  bones: %d" \
		% [_anim_keys.size(), _phys_bone_map.size()])


# ── Public API ────────────────────────────────────────────────────────────────

func play_state(state_name: String) -> void:
	if not _ready_complete or state_name == _current_state:
		return

	var was_physx := _current_state in PHYSX_STATES
	var now_physx := state_name in PHYSX_STATES
	if now_physx and not was_physx:
		if is_instance_valid(_phys_driver):
			_phys_driver.set("spring_enabled", false)
		if is_instance_valid(_vis_driver):
			_vis_driver.call("blend_to_ragdoll", 0.15)
	elif not now_physx and was_physx:
		if is_instance_valid(_phys_driver):
			_phys_driver.set("spring_enabled", true)
		if is_instance_valid(_vis_driver):
			_vis_driver.call("blend_to_animation", 0.3)

	_current_state = state_name
	if not is_instance_valid(anim_player):
		return
	var key: String = _state_anim_map.get(state_name, "")
	if key.is_empty() or anim_player.current_animation == key:
		return
	anim_player.play(key, 0.2)


## Match locomotion clip pace to actual ground speed (anti-footskate).
func set_speed_scale(s: float) -> void:
	if is_instance_valid(anim_player):
		anim_player.speed_scale = s


func is_rig_ready() -> bool:
	return _ready_complete


# ── Rig construction ──────────────────────────────────────────────────────────

func _load_master(node_name: String) -> Node3D:
	var scene := load(MASTER_PATH) as PackedScene
	if scene == null:
		push_error("CharacterRig: cannot load " + MASTER_PATH)
		var fallback := Node3D.new()
		fallback.name = node_name
		add_child(fallback)
		return fallback
	var inst := scene.instantiate() as Node3D
	inst.name = node_name
	add_child(inst)
	return inst


func _build_physics_bones() -> void:
	_simulator = PhysicalBoneSimulator3D.new()
	_simulator.name = "PhysicalBoneSimulator3D"
	_phys_skeleton.add_child(_simulator)

	for i in _phys_skeleton.get_bone_count():
		var bone_name: String = _phys_skeleton.get_bone_name(i)
		if _skip_bone(bone_name):
			continue

		var pb := PhysicalBone3D.new()
		pb.name          = "Physical_" + bone_name.replace(":", "_").replace(" ", "_")
		pb.joint_type    = PhysicalBone3D.JOINT_TYPE_CONE
		pb.bone_name     = bone_name
		pb.collision_layer = 4
		pb.collision_mask  = 1   # environment only; player capsule excluded via exception
		# World gravity points -Y globally but "down" on the planet is radial,
		# so engine gravity would drag the bones sideways almost everywhere.
		# The Hooke springs supply all the tracking force; ragdoll blends just
		# go limp instead of falling.
		pb.gravity_scale = 0.0
		_apply_bone_profile(pb, bone_name)
		_simulator.add_child(pb)

		var col := CollisionShape3D.new()
		col.name = "CollisionShape3D"
		_apply_collision_shape(pb, bone_name, col)
		pb.add_child(col)

		_set_joint_offset_from_rest(_phys_skeleton, pb, i)
		_apply_joint_limits(pb, bone_name)

		_phys_bone_map[i] = pb


func _fix_joint_frames() -> void:
	# After the simulator is active, recompute CONE joint_offset from actual
	# world transforms so the Z axis points along the bone extension direction.
	for bone_id: int in _phys_bone_map:
		var b: PhysicalBone3D = _phys_bone_map[bone_id]
		if b.joint_type != PhysicalBone3D.JOINT_TYPE_CONE or not b.is_inside_tree():
			continue
		var par := _walk_to_phys_parent(bone_id)
		if par == null or not par.is_inside_tree():
			continue
		var new_origin := par.global_transform.affine_inverse() * b.global_transform.origin
		var world_dir  := b.global_transform.origin - par.global_transform.origin
		var cone_z: Vector3
		if world_dir.length_squared() > 1e-6:
			cone_z = (par.global_transform.basis.inverse() * world_dir.normalized()).normalized()
		else:
			cone_z = Vector3.FORWARD
		var up     := Vector3.UP if abs(cone_z.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
		var cone_x := up.cross(cone_z).normalized()
		var cone_y := cone_z.cross(cone_x).normalized()
		b.joint_offset = Transform3D(Basis(cone_x, cone_y, cone_z), new_origin)


func _apply_collision_exceptions() -> void:
	# Bones must never collide with the player's own capsule body.
	var body := get_parent() as PhysicsBody3D
	if is_instance_valid(body):
		for bone_id: int in _phys_bone_map:
			PhysicsServer3D.body_add_collision_exception(
				(_phys_bone_map[bone_id] as PhysicalBone3D).get_rid(), body.get_rid())

	# Parent–child exceptions: each bone vs its nearest physical ancestor.
	for bone_id: int in _phys_bone_map:
		var bone: PhysicalBone3D = _phys_bone_map[bone_id]
		var par := _walk_to_phys_parent(bone_id)
		if par != null and is_instance_valid(par):
			PhysicsServer3D.body_add_collision_exception(bone.get_rid(), par.get_rid())

	# Sibling exceptions: bones sharing the same physical parent collide on
	# frame 1 without this (e.g. LeftUpLeg / RightUpLeg both from Hips).
	var by_parent: Dictionary = {}
	for bone_id: int in _phys_bone_map:
		var bone: PhysicalBone3D = _phys_bone_map[bone_id]
		var par := _walk_to_phys_parent(bone_id)
		var par_key: int = par.get_bone_id() if par != null else -1
		if not by_parent.has(par_key):
			by_parent[par_key] = []
		by_parent[par_key].append(bone)
	for par_key: int in by_parent:
		var siblings: Array = by_parent[par_key]
		for i in range(siblings.size()):
			for j in range(i + 1, siblings.size()):
				PhysicsServer3D.body_add_collision_exception(
					(siblings[i] as PhysicalBone3D).get_rid(),
					(siblings[j] as PhysicalBone3D).get_rid())


func _walk_to_phys_parent(bone_id: int) -> PhysicalBone3D:
	var idx := _phys_skeleton.get_bone_parent(bone_id)
	while idx >= 0:
		if _phys_bone_map.has(idx):
			return _phys_bone_map[idx]
		idx = _phys_skeleton.get_bone_parent(idx)
	return null


# ── Bone profile helpers (ported from build_physics_skeleton.gd) ──────────────

func _skip_bone(bone_name: String) -> bool:
	var lower := bone_name.to_lower()
	for frag in SKIP_BONE_FRAGMENTS:
		if lower.contains(frag):
			return true
	return bone_name.ends_with("Spine") or bone_name.ends_with("Spine1")


func _set_joint_offset_from_rest(skeleton: Skeleton3D, pb: PhysicalBone3D, bone_idx: int) -> void:
	var parent_idx := skeleton.get_bone_parent(bone_idx)
	var parent_rest: Transform3D
	var found := false
	while parent_idx >= 0:
		if not _skip_bone(skeleton.get_bone_name(parent_idx)):
			parent_rest = skeleton.get_bone_global_rest(parent_idx)
			found = true
			break
		parent_idx = skeleton.get_bone_parent(parent_idx)
	if not found:
		return
	var child_rest := skeleton.get_bone_global_rest(bone_idx)
	var new_origin := parent_rest.affine_inverse() * child_rest.origin
	var world_dir  := child_rest.origin - parent_rest.origin
	var cone_z: Vector3
	if world_dir.length_squared() > 1e-6:
		cone_z = (parent_rest.basis.inverse() * world_dir.normalized()).normalized()
	else:
		cone_z = Vector3.FORWARD
	var up     := Vector3.UP if abs(cone_z.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var cone_x := up.cross(cone_z).normalized()
	var cone_y := cone_z.cross(cone_x).normalized()
	pb.joint_offset = Transform3D(Basis(cone_x, cone_y, cone_z), new_origin)


func _apply_bone_profile(pb: PhysicalBone3D, bone_name: String) -> void:
	pb.mass = 1.0; pb.linear_damp = 1.5; pb.angular_damp = 8.0
	if   bone_name.ends_with("Hips"):
		pb.mass = 20.0; pb.linear_damp = 2.0; pb.angular_damp = 30.0
	elif bone_name.ends_with("Spine") or bone_name.ends_with("Spine1"):
		pb.mass = 5.0;  pb.linear_damp = 2.0; pb.angular_damp = 20.0
	elif bone_name.ends_with("Spine2"):
		pb.mass = 4.0;  pb.linear_damp = 2.0; pb.angular_damp = 20.0
	elif bone_name.ends_with("Neck"):
		pb.mass = 1.5;  pb.angular_damp = 24.0
	elif bone_name.ends_with("Head"):
		pb.mass = 5.0;  pb.angular_damp = 24.0
	elif bone_name.ends_with("LeftShoulder") or bone_name.ends_with("RightShoulder"):
		pb.mass = 1.5
	elif bone_name.ends_with("LeftArm") or bone_name.ends_with("RightArm"):
		pb.mass = 2.0
	elif bone_name.ends_with("LeftForeArm") or bone_name.ends_with("RightForeArm"):
		pb.mass = 1.2;  pb.angular_damp = 10.0
	elif bone_name.ends_with("LeftHand") or bone_name.ends_with("RightHand"):
		pb.mass = 0.4;  pb.linear_damp = 3.0; pb.angular_damp = 12.0
	elif bone_name.ends_with("LeftUpLeg") or bone_name.ends_with("RightUpLeg"):
		pb.mass = 8.0;  pb.angular_damp = 10.0
	elif bone_name.ends_with("LeftLeg") or bone_name.ends_with("RightLeg"):
		pb.mass = 4.0
	elif bone_name.ends_with("LeftFoot") or bone_name.ends_with("RightFoot"):
		pb.mass = 1.2;  pb.linear_damp = 3.0; pb.angular_damp = 12.0
	else:
		pb.mass = 0.5;  pb.linear_damp = 3.0; pb.angular_damp = 15.0


func _apply_collision_shape(_pb: PhysicalBone3D, bone_name: String, col: CollisionShape3D) -> void:
	var cap := CapsuleShape3D.new()
	if   bone_name.ends_with("Hips"):
		cap.radius = 0.12; cap.height = 0.25
	elif bone_name.ends_with("Spine2"):
		cap.radius = 0.10; cap.height = 0.22
	elif bone_name.ends_with("Head"):
		cap.radius = 0.09; cap.height = 0.16
	elif bone_name.ends_with("LeftArm") or bone_name.ends_with("RightArm"):
		cap.radius = 0.045; cap.height = 0.26
	elif bone_name.ends_with("LeftForeArm") or bone_name.ends_with("RightForeArm"):
		cap.radius = 0.035; cap.height = 0.24
	elif bone_name.ends_with("LeftHand") or bone_name.ends_with("RightHand"):
		cap.radius = 0.04;  cap.height = 0.08
	elif bone_name.ends_with("LeftUpLeg") or bone_name.ends_with("RightUpLeg"):
		cap.radius = 0.07;  cap.height = 0.40
	elif bone_name.ends_with("LeftLeg") or bone_name.ends_with("RightLeg"):
		cap.radius = 0.055; cap.height = 0.38
	elif bone_name.ends_with("LeftFoot") or bone_name.ends_with("RightFoot"):
		cap.radius = 0.05;  cap.height = 0.14
	else:
		cap.radius = 0.04;  cap.height = 0.10
	col.shape = cap


func _apply_joint_limits(pb: PhysicalBone3D, bone_name: String) -> void:
	var swing := 30.0; var twist := 20.0
	if   bone_name.ends_with("Hips"):
		swing = 20.0; twist = 15.0
	elif bone_name.ends_with("Spine2"):
		swing = 30.0; twist = 20.0
	elif bone_name.ends_with("Head"):
		swing = 40.0; twist = 30.0
	elif bone_name.ends_with("LeftArm") or bone_name.ends_with("RightArm"):
		swing = 80.0; twist = 90.0
	elif bone_name.ends_with("LeftForeArm") or bone_name.ends_with("RightForeArm"):
		swing = 130.0; twist = 20.0
	elif bone_name.ends_with("LeftUpLeg") or bone_name.ends_with("RightUpLeg"):
		swing = 50.0; twist = 30.0
	elif bone_name.ends_with("LeftLeg") or bone_name.ends_with("RightLeg"):
		swing = 140.0; twist = 10.0
	elif bone_name.ends_with("LeftFoot") or bone_name.ends_with("RightFoot"):
		swing = 35.0; twist = 20.0
	pb.set("joint_constraints/swing_span",  swing)
	pb.set("joint_constraints/twist_span",  twist)
	pb.set("joint_constraints/bias",        0.3)
	pb.set("joint_constraints/softness",    0.8)
	pb.set("joint_constraints/relaxation",  1.0)


# ── Animation loading ─────────────────────────────────────────────────────────

func _setup_animation_player(rig_root: Node) -> void:
	anim_player = _find_animation_player(rig_root)
	if anim_player == null:
		anim_player = AnimationPlayer.new()
		anim_player.name = "AnimationPlayer"
		rig_root.add_child(anim_player)

	var lib: AnimationLibrary
	if anim_player.has_animation_library(&""):
		lib = anim_player.get_animation_library(&"")
	else:
		lib = AnimationLibrary.new()
		anim_player.add_animation_library(&"", lib)

	var loaded := 0
	var dir := DirAccess.open("res://animations/")
	if dir:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(".fbx"):
				var scene := load("res://animations/" + file_name) as PackedScene
				if scene:
					var inst := scene.instantiate()
					var src_ap := _find_animation_player(inst)
					if src_ap:
						for anim_name: StringName in src_ap.get_animation_list():
							var key := StringName(file_name.get_basename())
							if lib.has_animation(key):
								continue
							var anim := src_ap.get_animation(anim_name).duplicate(true) as Animation
							anim.loop_mode = Animation.LOOP_LINEAR
							_strip_root_motion(anim)
							lib.add_animation(key, anim)
							loaded += 1
					inst.free()
			file_name = dir.get_next()
		dir.list_dir_end()

	_anim_keys.clear()
	for lib_name: StringName in anim_player.get_animation_library_list():
		var alib := anim_player.get_animation_library(lib_name)
		for anim_name: StringName in alib.get_animation_list():
			_anim_keys.append(
				str(anim_name) if lib_name == &"" else str(lib_name) + "/" + str(anim_name))

	print("[CharacterRig] Loaded %d animation(s)." % loaded)


func _build_state_map() -> void:
	for state: String in STATE_SEARCH:
		var searches: Array = STATE_SEARCH[state]
		for search: String in searches:
			var low: String = search.to_lower()
			for key: String in _anim_keys:
				if key.to_lower() == low or low in key.to_lower():
					_state_anim_map[state] = key
					break
			if _state_anim_map.has(state):
				break


func _strip_root_motion(anim: Animation) -> void:
	for t in anim.get_track_count():
		if anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		var path  := str(anim.track_get_path(t))
		var colon := path.rfind(":")
		var bone  := path.substr(colon + 1) if colon >= 0 else ""
		if bone.is_empty():
			continue
		var should_strip := "hip" in bone.to_lower()
		if not should_strip and is_instance_valid(anim_skeleton):
			var bi := anim_skeleton.find_bone(bone)
			if bi >= 0 and anim_skeleton.get_bone_parent(bi) < 0:
				should_strip = true
		if not should_strip:
			continue
		for i in anim.track_get_key_count(t):
			var v: Vector3 = anim.track_get_key_value(t, i)
			anim.track_set_key_value(t, i, Vector3(0.0, v.y, 0.0))


# ── Mesh visibility helpers ───────────────────────────────────────────────────

# The reference rendered the ghost with an alpha-0 transparent material, which
# still costs a full skinned character in the transparent pass every frame.
# Skeleton/modifier processing (and the skeleton_updated signal the IK and
# blend drivers rely on) is independent of mesh visibility, so hide it outright.
func _make_ghost(node: Node) -> void:
	_hide_meshes(node)


func _hide_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		node.visible = false
	for child in node.get_children():
		_hide_meshes(child)


# ── Node search helpers ───────────────────────────────────────────────────────

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var r := _find_skeleton(child)
		if r:
			return r
	return null


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var r := _find_animation_player(child)
		if r:
			return r
	return null
