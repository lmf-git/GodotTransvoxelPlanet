## interpolated_animation.gd
## A plain Node3D driver that reads poses from two skeletons and writes
## the blended result into visual_skeleton via set_bone_global_pose_override().
##
## Create this node, set all @export properties, THEN add_child it so that
## _ready() fires with valid references already in place.
extends Node3D

## 0.0 = fully animated, 1.0 = fully physics-driven.
@export_range(0.0, 1.0) var physics_blend: float = 0.0

@export var visual_skeleton:   Skeleton3D
@export var physics_skeleton:  Skeleton3D
@export var animated_skeleton: Skeleton3D

## Map bone_id (int) → PhysicalBone3D so we can read the physics body's
## actual world transform directly, bypassing the PhysicalBoneSimulator3D
## modifier write-back (which may or may not have run this frame).
var phys_bone_map: Dictionary = {}

var _skip_first := true


func _ready() -> void:
	print("[vis_driver] _ready() — vis=%s  anim=%s  phys=%s" % [
		is_instance_valid(visual_skeleton),
		is_instance_valid(animated_skeleton),
		is_instance_valid(physics_skeleton)])
	# In Godot 4.3+, SkeletonIK3D is a SkeletonModifier3D.  Modifiers run AFTER
	# _process() callbacks, so reading get_bone_global_pose() inside _process()
	# gives the PRE-IK pose.  The skeleton_updated signal fires after ALL modifiers
	# have finished — connecting here ensures we always copy the post-IK result.
	if is_instance_valid(animated_skeleton):
		animated_skeleton.skeleton_updated.connect(_on_skeleton_updated)


func _on_skeleton_updated() -> void:
	if _skip_first:
		_skip_first = false
		return
	if not is_inside_tree():
		return
	_apply_blend()


func _apply_blend() -> void:
	if not (is_instance_valid(visual_skeleton)
			and is_instance_valid(animated_skeleton)):
		return
	if not animated_skeleton.is_inside_tree() or not visual_skeleton.is_inside_tree():
		return

	var inv_skel := visual_skeleton.global_transform.affine_inverse()

	for i in visual_skeleton.get_bone_count():
		var anim_xform: Transform3D = (
			animated_skeleton.global_transform * animated_skeleton.get_bone_global_pose(i))

		var blended_local: Transform3D
		if physics_blend < 0.001:
			blended_local = inv_skel * anim_xform
		else:
			var phys_xform: Transform3D
			if phys_bone_map.has(i):
				var pb: PhysicalBone3D = phys_bone_map[i]
				if is_instance_valid(pb):
					# Read directly from the physics body — always the current
					# physics-server state with no per-frame modifier lag.
					phys_xform = pb.global_transform
				else:
					phys_xform = anim_xform
			else:
				# Walk up parent chain to the nearest physics ancestor so fingers/toes
				# move with their physics parent rather than snapping to animated pose.
				var par := visual_skeleton.get_bone_parent(i)
				while par >= 0 and not phys_bone_map.has(par):
					par = visual_skeleton.get_bone_parent(par)
				if par >= 0:
					var phys_par: PhysicalBone3D = phys_bone_map[par]
					if is_instance_valid(phys_par):
						var anim_par_xform: Transform3D = (
							animated_skeleton.global_transform
							* animated_skeleton.get_bone_global_pose(par))
						var local_to_par := anim_par_xform.affine_inverse() * anim_xform
						phys_xform = phys_par.global_transform * local_to_par
					else:
						phys_xform = anim_xform
				else:
					phys_xform = anim_xform
			blended_local = inv_skel * anim_xform.interpolate_with(phys_xform, physics_blend)

		visual_skeleton.set_bone_global_pose_override(i, blended_local, 1.0, true)


# ---------------------------------------------------------------------------
# Blend helpers called from main.gd
# ---------------------------------------------------------------------------

func blend_to_ragdoll(duration: float = 0.3) -> void:
	var tw := create_tween()
	tw.tween_property(self, "physics_blend", 1.0, duration).set_ease(Tween.EASE_IN)


func blend_to_animation(duration: float = 0.3) -> void:
	var tw := create_tween()
	tw.tween_property(self, "physics_blend", 0.0, duration).set_ease(Tween.EASE_OUT)
