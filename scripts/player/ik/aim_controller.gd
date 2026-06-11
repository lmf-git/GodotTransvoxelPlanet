class_name AimController
extends Node
## IK weapon-aiming system (ported from the IKaim reference project).
##
## Two SkeletonIK3D chains pull the trigger/support hands toward targets along
## the aim direction; HandRotationOverride (a SkeletonModifier3D running after
## the IK) forces deterministic wrist orientation; the weapon model is placed
## at the post-IK hand bone each frame, oriented along the aim.
##
## The reference assumed a flat Y-up world. Here every computation runs in the
## player's gravity frame: up = body +Y (FlightPlayer aligns it to the planet
## radial in WALK mode), forward = body -Z, right = body +X. Aim pitch reuses
## the player's camera pitch (positive = up).
##
## Controls (WALK mode): [1] rifle  [2] pistol (same key unequips)
##                       RMB aim (ADS)  LMB fire  wheel = scope zoom

const WEAPON_CFG := {
	"762_AK": {
		"rpm": 600.0, "auto": true,
		"recoil_pitch": 0.028, "recoil_yaw": 0.012, "recoil_kick": 1.0,
		"damage": 38.0,
	},
	"9mm_Pistol": {
		"rpm": 360.0, "auto": false,
		"recoil_pitch": 0.018, "recoil_yaw": 0.006, "recoil_kick": 0.5,
		"damage": 22.0,
	},
}

var player: FlightPlayer
var rig: CharacterRig
var skeleton: Skeleton3D

var aim_ik: SkeletonIK3D
var lhand_ik: SkeletonIK3D
var grip_override: HandRotationOverride
var rshoulder_idx: int = -1
var rhand_idx: int = -1
var lshoulder_idx: int = -1
var lhand_idx: int = -1

# Grip tuning (degrees) — see IKaim Player.gd for the conventions.
var support_tilt_deg: float = -25.0
var trigger_tilt_deg: float = -55.0
var support_pitch_deg: float = 40.0

var weapon_holder: Node3D
var weapon_pivot: Node3D
var current_weapon: Node3D = null
var current_weapon_type: String = ""
var lhand_target: Node3D            # left-hand grip marker, child of weapon
var aim_target_node: Node3D         # world-space IK targets (top_level)
var lhand_target_world: Node3D

var is_aiming := false
var fire_held := false
var current_cartridge := "762_AK"
var current_ads_weight := 0.0
var weapon_kick := 0.0
var weapon_kick_vel := 0.0
var time_since_shot := 999.0
@export var ads_speed: float = 12.0

# Scope picture-in-picture
var scope_vp: SubViewport
var scope_cam: Camera3D
var scope_reticle: Control
var zoom_levels := [4.0, 8.0, 16.0, 32.0]
var zoom_index := 1
var current_zoom: float:
	get:
		return zoom_levels[zoom_index]

var hud_crosshair: Control
var _ik_ready := false


func setup(p_player: FlightPlayer, p_rig: CharacterRig) -> void:
	player = p_player
	rig = p_rig
	if rig.is_rig_ready():
		_on_rig_ready()
	else:
		rig.rig_ready.connect(_on_rig_ready)


func _on_rig_ready() -> void:
	skeleton = rig.anim_skeleton
	_setup_scope_pip()
	_setup_weapon_holder()
	_setup_aim_ik()
	_setup_ui()
	skeleton.skeleton_updated.connect(_on_skeleton_updated)
	_ik_ready = true


func is_armed() -> bool:
	return current_weapon != null


## Seated IK: pull the hands onto vehicle control grips while mounted. Called
## by the vehicle every physics tick (the player's own loop is disabled then).
## Position-only IK; the wrist keeps the sitting-pose orientation.
func update_seat_ik(rh_grip: Node3D, lh_grip: Node3D, delta: float) -> void:
	if not _ik_ready or aim_ik == null or lhand_ik == null:
		return
	if grip_override:
		grip_override.enabled = false
		grip_override.weight = 0.0
	var want_r := 1.0 if rh_grip else 0.0
	var want_l := 1.0 if lh_grip else 0.0
	aim_ik.influence = move_toward(aim_ik.influence, want_r, 4.0 * delta)
	lhand_ik.influence = move_toward(lhand_ik.influence, want_l, 4.0 * delta)
	if rh_grip:
		aim_target_node.global_position = rh_grip.global_position
	if lh_grip:
		lhand_target_world.global_position = lh_grip.global_position


# ── Frame helpers (player gravity frame) ─────────────────────────────────────

func _up() -> Vector3:
	return player.global_transform.basis.y

func _fwd() -> Vector3:
	return -player.global_transform.basis.z

func _right() -> Vector3:
	return player.global_transform.basis.x

## Aim direction from body yaw + camera pitch only (never the camera basis),
## so the IK points where the character faces. Positive pitch = up.
func _aim_dir() -> Vector3:
	return _fwd().rotated(_right(), player.cam_pitch())

func _body_point(height: float) -> Vector3:
	return player.global_transform * Vector3(0.0, height, 0.0)


# ── Setup ────────────────────────────────────────────────────────────────────

func _setup_weapon_holder() -> void:
	# The reference made these nodes top_level (world-pinned). Here the player
	# rides a SPINNING planet that moves metres per frame in world space, so a
	# world-pinned target always lags behind the body toward the spin direction
	# and the IK aims there instead of where the player faces. As plain children
	# of the player they co-move with the body between updates; writing their
	# global_transform each frame still works (Godot converts to local).
	weapon_holder = Node3D.new()
	weapon_holder.name = "WeaponHolder"
	weapon_holder.visible = false
	player.add_child(weapon_holder)
	weapon_pivot = Node3D.new()
	weapon_pivot.name = "WeaponPivot"
	weapon_holder.add_child(weapon_pivot)
	aim_target_node = Node3D.new()
	aim_target_node.name = "AimTarget"
	player.add_child(aim_target_node)
	lhand_target_world = Node3D.new()
	lhand_target_world.name = "LHandTargetWorld"
	player.add_child(lhand_target_world)


func _setup_scope_pip() -> void:
	scope_vp = SubViewport.new()
	scope_vp.size = Vector2i(1024, 1024)
	scope_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(scope_vp)
	scope_cam = Camera3D.new()
	scope_cam.far = 3000.0
	scope_cam.cull_mask = scope_cam.cull_mask & ~2
	scope_vp.add_child(scope_cam)
	scope_reticle = Control.new()
	scope_reticle.size = Vector2(1024, 1024)
	scope_reticle.draw.connect(_draw_reticle)
	scope_vp.add_child(scope_reticle)


func _draw_reticle() -> void:
	var center := Vector2(512, 512)
	var col := Color.RED
	scope_reticle.draw_line(center + Vector2(-40, 0), center + Vector2(40, 0), col, 2.0)
	scope_reticle.draw_line(center + Vector2(0, -40), center + Vector2(0, 40), col, 2.0)
	scope_reticle.draw_circle(center, 4.0, col)


func _setup_ui() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)
	var center := Control.new()
	center.set_anchors_preset(Control.PRESET_CENTER)
	# CRITICAL: the crosshair sits at the exact screen centre — where the
	# CAPTURED mouse lives. With the default MOUSE_FILTER_STOP these controls
	# eat every mouse-motion event as GUI input, and the player (which listens
	# in _unhandled_input, i.e. AFTER the GUI) can no longer look around while
	# a weapon is equipped. The whole HUD must ignore the mouse.
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cl.add_child(center)
	hud_crosshair = center
	for v in [Vector2(-8, 0), Vector2(8, 0), Vector2(0, -8), Vector2(0, 8)]:
		var tick := ColorRect.new()
		tick.custom_minimum_size = Vector2(2, 6) if v.x == 0 else Vector2(6, 2)
		tick.color = Color(1, 1, 1, 0.85)
		tick.position = v - tick.custom_minimum_size * 0.5
		tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
		center.add_child(tick)
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(2, 2)
	dot.color = Color(1, 0.2, 0.2)
	dot.position = Vector2(-1, -1)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(dot)
	hud_crosshair.visible = false


func _setup_aim_ik() -> void:
	rshoulder_idx = skeleton.find_bone("mixamorig_RightShoulder")
	rhand_idx = skeleton.find_bone("mixamorig_RightHand")
	lshoulder_idx = skeleton.find_bone("mixamorig_LeftShoulder")
	lhand_idx = skeleton.find_bone("mixamorig_LeftHand")

	# Pre-position the IK targets in front of the player so start() converges
	# (FABRIK locks to a degenerate state if the target is unreachable then).
	aim_target_node.global_position = _body_point(1.3) + _fwd() * 0.5 + _right() * 0.1
	lhand_target_world.global_position = _body_point(1.3) + _fwd() * 0.5 - _right() * 0.1

	aim_ik = SkeletonIK3D.new()
	aim_ik.name = "AimIK"
	aim_ik.influence = 0.0
	# Position-only IK; HandRotationOverride handles wrist orientation.
	aim_ik.override_tip_basis = false
	aim_ik.use_magnet = true
	aim_ik.root_bone = "mixamorig_RightShoulder"
	aim_ik.tip_bone = "mixamorig_RightHand"
	skeleton.add_child(aim_ik)
	aim_ik.target_node = aim_ik.get_path_to(aim_target_node)
	aim_ik.start()

	grip_override = HandRotationOverride.new()
	grip_override.name = "GripOverride"
	grip_override.bone_name = "mixamorig_RightHand"
	grip_override.second_bone_name = "mixamorig_LeftHand"

	lhand_ik = SkeletonIK3D.new()
	lhand_ik.name = "LHandIK"
	lhand_ik.influence = 0.0
	lhand_ik.override_tip_basis = false
	lhand_ik.use_magnet = true
	lhand_ik.root_bone = "mixamorig_LeftShoulder"
	lhand_ik.tip_bone = "mixamorig_LeftHand"
	skeleton.add_child(lhand_ik)
	lhand_ik.target_node = lhand_ik.get_path_to(lhand_target_world)
	lhand_ik.start()
	skeleton.add_child(grip_override)   # added AFTER the IK so it runs later


# ── Input ────────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not _ik_ready or player.mode != FlightPlayer.Mode.WALK:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			is_aiming = mb.pressed and current_weapon != null
			scope_vp.render_target_update_mode = \
				SubViewport.UPDATE_ALWAYS if is_aiming else SubViewport.UPDATE_DISABLED
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			fire_held = mb.pressed
			if mb.pressed:
				_try_fire()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed and is_aiming:
			zoom_index = mini(zoom_index + 1, zoom_levels.size() - 1)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed and is_aiming:
			zoom_index = maxi(zoom_index - 1, 0)
	elif event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		if key == KEY_1:
			_toggle_weapon("rifle")
		elif key == KEY_2:
			_toggle_weapon("pistol")


func _toggle_weapon(type: String) -> void:
	if current_weapon_type == type:
		unequip_weapon()
	else:
		equip_weapon(type)
		current_cartridge = "762_AK" if type == "rifle" else "9mm_Pistol"


func equip_weapon(type: String) -> void:
	if current_weapon:
		current_weapon.queue_free()
	current_weapon = Weapons.create(type, scope_vp.get_texture())
	current_weapon_type = type
	weapon_pivot.add_child(current_weapon)
	# Wrist sits just above/behind the grip on the gun's right side; both
	# weapons put their pistol grip at the origin, so one offset fits both.
	current_weapon.position = Vector3(0.03, 0.02, 0.065)
	current_weapon.rotation = Vector3.ZERO

	lhand_target = Node3D.new()
	lhand_target.name = "LHandGrip"
	current_weapon.add_child(lhand_target)
	if type == "pistol":
		lhand_target.position = Vector3(0.05, -0.03, 0.0)
		support_tilt_deg = 15.0
		support_pitch_deg = 65.0
	else:
		lhand_target.position = Vector3(0.05, -0.01, 0.16)
		support_tilt_deg = -50.0
		support_pitch_deg = 0.0


func unequip_weapon() -> void:
	if current_weapon:
		current_weapon.queue_free()
		current_weapon = null
	current_weapon_type = ""
	is_aiming = false
	fire_held = false


# ── Per-frame update (driven by FlightPlayer in WALK mode) ───────────────────

func update_aim(delta: float) -> void:
	if not _ik_ready:
		return

	# Recoil spring (weapon kick)
	var k := 90.0
	var d := 14.0
	var accel := -k * weapon_kick - d * weapon_kick_vel
	weapon_kick_vel += accel * delta
	weapon_kick += weapon_kick_vel * delta
	weapon_kick = clampf(weapon_kick, 0.0, 2.0)

	time_since_shot += delta
	if fire_held and current_weapon:
		if WEAPON_CFG.get(current_cartridge, {}).get("auto", false):
			_try_fire()

	current_ads_weight = lerpf(current_ads_weight, 1.0 if is_aiming else 0.0, delta * ads_speed)
	if player.camera():
		player.camera().fov = lerpf(70.0, 50.0, current_ads_weight)
	if hud_crosshair:
		hud_crosshair.visible = current_weapon != null

	_update_aim_ik(delta)
	_update_scope()


func set_hud_visible(v: bool) -> void:
	if hud_crosshair:
		hud_crosshair.visible = v and current_weapon != null
	if not v:
		is_aiming = false
		fire_held = false
		if player.camera():
			player.camera().fov = 70.0


# Position a NEAR (~0.42 m) IK target along the aim direction at shoulder
# height — FABRIK only solves correctly to reachable targets.
func _update_aim_ik(delta: float) -> void:
	if not aim_ik or not lhand_ik:
		return
	if rshoulder_idx < 0 or rhand_idx < 0:
		return

	var want: float = 1.0 if current_weapon else 0.0
	aim_ik.influence = move_toward(aim_ik.influence, want, 4.0 * delta)
	lhand_ik.influence = move_toward(lhand_ik.influence, want, 4.0 * delta)
	if grip_override:
		grip_override.weight = aim_ik.influence
		grip_override.enabled = aim_ik.influence > 0.001
	if not current_weapon:
		return

	var up := _up()
	var aim_dir := _aim_dir()
	var char_right := _right()
	var aim_origin: Vector3
	if is_aiming:
		aim_origin = _body_point(1.55)
	else:
		aim_origin = _body_point(1.30)
	if not is_aiming:
		# Carry pose: muzzle dips slightly.
		aim_dir = aim_dir.rotated(char_right, deg_to_rad(8.0))
	if weapon_kick > 0.0:
		var recoil_axis := aim_dir.cross(up).normalized()
		if recoil_axis.length_squared() > 0.0001:
			aim_dir = aim_dir.rotated(recoil_axis, weapon_kick * 0.06)

	var side_offset := 0.03 if is_aiming else 0.10
	var ik_pos_world := aim_origin + aim_dir * 0.42 + char_right * side_offset

	var up_for_basis := up
	if absf(aim_dir.dot(up_for_basis)) > 0.95:
		up_for_basis = char_right
	aim_target_node.global_transform = Transform3D(
			Basis.looking_at(aim_dir, up_for_basis), ik_pos_world)

	# Predicted weapon frame for this aim — the support-hand IK target derives
	# from THIS, not the weapon node (which holds last frame's pose).
	var gun_basis := Basis.looking_at(-aim_dir, up_for_basis)
	if lhand_target:
		lhand_target_world.global_position = Transform3D(gun_basis, ik_pos_world) \
				* (current_weapon.position + lhand_target.position)

	# Grip orientations for the modifier (runs after the IK this frame).
	# Hand bone conventions: fingers along local +Y, palm out of +Z;
	# thumb side +X on the right hand, -X on the left.
	var skel_b_inv := skeleton.global_transform.basis.inverse()
	var palm_r: Vector3 = up_for_basis.cross(aim_dir).normalized()
	var trigger_basis := Basis(aim_dir, palm_r.cross(aim_dir), palm_r) \
			.rotated(palm_r, deg_to_rad(trigger_tilt_deg))
	grip_override.target_basis = skel_b_inv * trigger_basis
	var palm_l: Vector3 = aim_dir.cross(up_for_basis).normalized() \
			.rotated(aim_dir, deg_to_rad(support_tilt_deg))
	var support_basis := Basis(-aim_dir, palm_l.cross(-aim_dir), palm_l) \
			.rotated(palm_l, deg_to_rad(support_pitch_deg))
	grip_override.second_target_basis = skel_b_inv * support_basis

	# Elbow magnets in skeleton-local space (FABRIK reads `magnet` directly).
	var fwd := _fwd()
	var skel_inv := skeleton.global_transform.affine_inverse()
	var shoulder_world: Vector3 = (skeleton.global_transform \
			* skeleton.get_bone_global_pose(rshoulder_idx)).origin
	var elbow_world := shoulder_world + char_right * 0.45 - up * 0.25 + fwd * 0.15
	aim_ik.magnet = skel_inv * elbow_world

	if lshoulder_idx >= 0:
		var lshoulder_world: Vector3 = (skeleton.global_transform \
				* skeleton.get_bone_global_pose(lshoulder_idx)).origin
		var lelbow_world := lshoulder_world - char_right * 0.40 - up * 0.25 + fwd * 0.20
		lhand_ik.magnet = skel_inv * lelbow_world


# Fires after AnimationPlayer + SkeletonIK3D ran: place the gun at the ACTUAL
# post-IK hand-bone position, oriented along the aim direction.
func _on_skeleton_updated() -> void:
	if not weapon_holder:
		return
	weapon_holder.visible = current_weapon != null \
			and player.mode == FlightPlayer.Mode.WALK
	if not current_weapon or rhand_idx < 0:
		return

	var up := _up()
	var aim_dir := _aim_dir()
	if not is_aiming:
		aim_dir = aim_dir.rotated(_right(), deg_to_rad(8.0))
	if weapon_kick > 0.0:
		var right_axis := aim_dir.cross(up).normalized()
		if right_axis.length_squared() > 0.0001:
			aim_dir = aim_dir.rotated(right_axis, weapon_kick * 0.06)

	var hand_pos: Vector3 = (skeleton.global_transform \
			* skeleton.get_bone_global_pose(rhand_idx)).origin
	var up_for_basis := up
	if absf(aim_dir.dot(up_for_basis)) > 0.95:
		up_for_basis = _right()
	# Basis.looking_at orients -Z toward dir; weapon barrel is +Z, so -aim_dir.
	weapon_holder.global_transform = Transform3D(
			Basis.looking_at(-aim_dir, up_for_basis), hand_pos)


func _update_scope() -> void:
	if not current_weapon:
		return
	var aim := _aim_dir()
	var muzzle: Node3D = current_weapon.get_node_or_null("Muzzle")
	var scope_origin: Vector3
	if muzzle and muzzle.is_inside_tree():
		scope_origin = muzzle.global_position
	else:
		scope_origin = _body_point(1.55) + aim * 1.0
	scope_cam.global_position = scope_origin
	var up_ref := _up()
	if absf(aim.dot(up_ref)) > 0.95:
		up_ref = _right()
	scope_cam.look_at(scope_origin + aim * 10.0, up_ref)
	scope_cam.fov = 60.0 / current_zoom
	scope_reticle.queue_redraw()


# ── Firing ───────────────────────────────────────────────────────────────────

func _try_fire() -> void:
	if not current_weapon or player.mode != FlightPlayer.Mode.WALK:
		return
	var cfg: Dictionary = WEAPON_CFG.get(current_cartridge, {})
	var interval: float = 60.0 / float(cfg.get("rpm", 200.0))
	if time_since_shot < interval:
		return
	time_since_shot = 0.0
	_fire()


func _fire() -> void:
	if not player.is_inside_tree() or not current_weapon:
		return
	var muzzle: Node3D = current_weapon.get_node_or_null("Muzzle")
	# Fire ORIGIN is the eye line so the bullet travels through the crosshair;
	# the muzzle flash stays at the muzzle for the visual.
	var fire_dir := _aim_dir()
	var fire_pos := _body_point(1.65)
	var flash_pos: Vector3 = muzzle.global_position \
			if (muzzle and muzzle.is_inside_tree()) else fire_pos

	# Spawn bullets + effects in the PLANET's co-rotating frame: parented to
	# the scene root they'd be left behind by the planet spin (the ground moves
	# 100+ m/s in world space — smoke streaks away, bullets miss the terrain).
	var frame : Node3D = player.planet_node()
	if frame == null:
		frame = player.get_parent() as Node3D
	if frame == null:
		return

	Effects.spawn_muzzle_flash(frame, flash_pos, fire_dir,
			1.2 if current_cartridge == "762_AK" else 0.85)
	var eject_node: Node3D = current_weapon.get_node_or_null("EjectionPort")
	if eject_node:
		Effects.spawn_shell(frame, eject_node.global_position,
				current_weapon.global_transform.basis.x,
				current_cartridge == "762_AK")

	# Bullet simulates in parent-local axes (see bullet.gd) — convert the
	# world-space muzzle velocity and radial gravity into the frame's basis.
	var fb_inv := frame.global_transform.basis.inverse()
	var cart: Dictionary = Ballistics.CARTRIDGES[current_cartridge]
	var bullet := Node3D.new()
	bullet.set_script(load("res://scripts/player/weapons/bullet.gd"))
	bullet.bc_g7 = cart.bc_g7
	bullet.mass_gr = cart.mass_gr
	bullet.velocity = fb_inv * (fire_dir * cart.mv_mps)
	bullet.damage = WEAPON_CFG.get(current_cartridge, {}).get("damage", 30.0)
	bullet.ignore_body = player
	bullet.gravity = fb_inv * (-_up() * Ballistics.G)
	frame.add_child(bullet)
	bullet.position = frame.to_local(fire_pos)

	_apply_recoil()


func _apply_recoil() -> void:
	var cfg: Dictionary = WEAPON_CFG.get(current_cartridge, {})
	var aim_scale := 0.4 if is_aiming else 1.0
	player.add_recoil(cfg.get("recoil_pitch", 0.02) * aim_scale,
			randf_range(-1.0, 1.0) * cfg.get("recoil_yaw", 0.01) * aim_scale)
	weapon_kick = maxf(weapon_kick, cfg.get("recoil_kick", 0.5))
	weapon_kick_vel = 6.0 * cfg.get("recoil_kick", 0.5)
