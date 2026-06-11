class_name Effects
extends RefCounted

# Lightweight effect spawner. All methods are static; results parent themselves
# to scene root so they survive after the caller is freed.

static func spawn_muzzle_flash(parent: Node, pos: Vector3, dir: Vector3, scale_mul: float = 1.0):
	var flash := Node3D.new()
	parent.add_child(flash)
	flash.global_position = pos
	if dir.length_squared() > 0.0001:
		# Pick an up reference that can't be parallel to dir — on a planet the
		# fire direction can be anything (world Y means nothing there), and a
		# colinear up makes look_at produce a degenerate basis.
		var up_ref := Vector3.UP
		if absf(dir.normalized().dot(up_ref)) > 0.95:
			up_ref = Vector3.RIGHT
		flash.look_at_from_position(pos, pos + dir, up_ref)

	# Star-burst billboard quad — the only visible flash element. Sized for
	# a muzzle, not an explosion. Additive-style emission with alpha falloff.
	var star := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.20, 0.20) * scale_mul
	star.mesh = qm
	var star_mat := StandardMaterial3D.new()
	star_mat.albedo_color = Color(1.0, 0.85, 0.45, 1.0)
	star_mat.albedo_texture = _flash_texture()
	star_mat.emission_enabled = true
	star_mat.emission = Color(1.0, 0.80, 0.35)
	star_mat.emission_texture = _flash_texture()
	star_mat.emission_energy_multiplier = 10.0
	star_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	star_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD     # additive — glows on dark
	star_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	star_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	star_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	star.material_override = star_mat
	star.rotation.z = randf_range(0, TAU)
	flash.add_child(star)

	# Brief omni light pulse so nearby surfaces actually catch the flash.
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.8, 0.4)
	light.light_energy = 3.5 * scale_mul
	light.omni_range = 2.5 * scale_mul
	flash.add_child(light)

	# Tiny smoke puff — a few small wisps drifting forward and fading. Quad
	# size and particle scale are both small so the smoke reads as "puff" not
	# "cloud". Soft-circle texture keeps the edges from looking square.
	var smoke := GPUParticles3D.new()
	smoke.amount = 5
	smoke.lifetime = 0.35
	smoke.one_shot = true
	smoke.emitting = true
	smoke.explosiveness = 0.9
	# Local coords: the effect rides a SPINNING planet — world-space particles
	# get left behind at ~100 m/s and streak sideways.
	smoke.local_coords = true
	var smoke_mat := ParticleProcessMaterial.new()
	smoke_mat.direction = Vector3(0, 0, 1)
	smoke_mat.spread = 10.0
	smoke_mat.initial_velocity_min = 0.4
	smoke_mat.initial_velocity_max = 1.0
	smoke_mat.gravity = Vector3(0, 0.3, 0)
	smoke_mat.damping_min = 3.0
	smoke_mat.damping_max = 5.0
	smoke_mat.scale_min = 0.4
	smoke_mat.scale_max = 0.7
	smoke_mat.color = Color(0.9, 0.9, 0.9, 0.45)
	var smoke_ramp := GradientTexture1D.new()
	smoke_ramp.gradient = _smoke_ramp()
	smoke_mat.color_ramp = smoke_ramp
	smoke.process_material = smoke_mat
	var smoke_quad := QuadMesh.new()
	smoke_quad.size = Vector2(0.06, 0.06) * scale_mul   # tiny base size
	var smoke_qmat := StandardMaterial3D.new()
	smoke_qmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke_qmat.albedo_color = Color(0.95, 0.95, 0.95, 0.5)
	smoke_qmat.albedo_texture = _soft_circle_texture()
	smoke_qmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	smoke_qmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smoke_qmat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	smoke_quad.material = smoke_qmat
	smoke.draw_pass_1 = smoke_quad
	flash.add_child(smoke)

	# Rapid fadeout — muzzle flashes are brief (~50 ms visible).
	var tween := flash.create_tween().set_parallel()
	tween.tween_property(star_mat, "emission_energy_multiplier", 0.0, 0.06)
	tween.tween_property(star_mat, "albedo_color:a", 0.0, 0.06)
	tween.tween_property(light, "light_energy", 0.0, 0.08)
	tween.chain().tween_interval(0.6)
	tween.chain().tween_callback(flash.queue_free)


static func spawn_impact(parent: Node, pos: Vector3, normal: Vector3, hit_obj: Object = null):
	var fx := Node3D.new()
	parent.add_child(fx)
	# Global, not local — the parent is the (rotated) planet frame, not the root.
	fx.global_position = pos

	# Sparks
	var sparks := GPUParticles3D.new()
	sparks.local_coords = true   # co-rotating planet frame (see muzzle smoke)
	sparks.amount = 18
	sparks.lifetime = 0.45
	sparks.one_shot = true
	sparks.emitting = true
	sparks.explosiveness = 0.95
	var spark_mat := ParticleProcessMaterial.new()
	if normal.length_squared() < 0.0001:
		normal = Vector3.UP
	spark_mat.direction = normal
	spark_mat.spread = 50.0
	spark_mat.initial_velocity_min = 2.0
	spark_mat.initial_velocity_max = 6.0
	spark_mat.gravity = Vector3(0, -9.8, 0)
	spark_mat.scale_min = 0.015
	spark_mat.scale_max = 0.035
	spark_mat.color = Color(1.0, 0.7, 0.2)
	var ramp := GradientTexture1D.new()
	ramp.gradient = _spark_ramp()
	spark_mat.color_ramp = ramp
	sparks.process_material = spark_mat
	var spark_quad := QuadMesh.new()
	spark_quad.size = Vector2(0.04, 0.04)
	var spark_qmat := StandardMaterial3D.new()
	spark_qmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_qmat.emission_enabled = true
	spark_qmat.emission = Color(1.0, 0.7, 0.2)
	spark_qmat.emission_energy_multiplier = 4.0
	spark_qmat.albedo_color = Color(1.0, 0.7, 0.2)
	spark_qmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	spark_quad.material = spark_qmat
	sparks.draw_pass_1 = spark_quad
	fx.add_child(sparks)

	# Dust puff
	var dust := GPUParticles3D.new()
	dust.local_coords = true   # co-rotating planet frame
	dust.amount = 10
	dust.lifetime = 0.8
	dust.one_shot = true
	dust.emitting = true
	dust.explosiveness = 0.6
	var dust_mat := ParticleProcessMaterial.new()
	dust_mat.direction = normal
	dust_mat.spread = 40.0
	dust_mat.initial_velocity_min = 0.4
	dust_mat.initial_velocity_max = 1.4
	dust_mat.gravity = Vector3(0, 0.2, 0)
	dust_mat.damping_min = 1.0
	dust_mat.damping_max = 2.5
	dust_mat.scale_min = 0.08
	dust_mat.scale_max = 0.18
	dust_mat.color = Color(0.6, 0.55, 0.5, 0.6)
	dust.process_material = dust_mat
	var dust_quad := QuadMesh.new()
	dust_quad.size = Vector2(0.4, 0.4)
	var dust_qmat := StandardMaterial3D.new()
	dust_qmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dust_qmat.albedo_color = Color(0.7, 0.65, 0.6, 0.7)
	dust_qmat.albedo_texture = _soft_circle_texture()
	dust_qmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dust_qmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dust_qmat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	dust_quad.material = dust_qmat
	dust.draw_pass_1 = dust_quad
	fx.add_child(dust)

	# Bullet hole decal - only on static geometry
	if hit_obj == null or hit_obj is StaticBody3D:
		var decal := Decal.new()
		decal.size = Vector3(0.08, 0.4, 0.08)
		decal.albedo_mix = 1.0
		decal.modulate = Color(0.05, 0.05, 0.05)
		decal.texture_albedo = _hole_texture()
		# Orient decal so its -Y axis aligns with surface normal (decals project down their -Y)
		var t := Transform3D()
		var up := normal.normalized()
		var tangent := Vector3.RIGHT
		if abs(up.dot(Vector3.RIGHT)) > 0.95:
			tangent = Vector3.FORWARD
		var bitangent := up.cross(tangent).normalized()
		tangent = bitangent.cross(up).normalized()
		t.basis = Basis(tangent, up, bitangent)
		t.origin = pos + up * 0.02
		parent.add_child(decal)
		decal.global_transform = t   # world-space placement under the planet frame
		var d_tween := decal.create_tween()
		d_tween.tween_interval(8.0)
		d_tween.tween_property(decal, "albedo_mix", 0.0, 1.0)
		d_tween.tween_callback(decal.queue_free)

	# Cleanup
	var t2 := fx.create_tween()
	t2.tween_interval(1.0)
	t2.tween_callback(fx.queue_free)


static func spawn_shell(parent: Node, pos: Vector3, eject_dir: Vector3, is_rifle: bool):
	var shell := RigidBody3D.new()
	shell.position = pos
	shell.gravity_scale = 1.5
	shell.linear_velocity = eject_dir * randf_range(2.5, 4.0) + Vector3.UP * randf_range(0.5, 1.2)
	shell.angular_velocity = Vector3(randf_range(-10, 10), randf_range(-10, 10), randf_range(-10, 10))
	# Pass through bullets/world cosmetically: only collide with floor
	shell.collision_layer = 0
	shell.collision_mask = 1
	parent.add_child(shell)

	var mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.005 if is_rifle else 0.0045
	cyl.bottom_radius = 0.005 if is_rifle else 0.0045
	cyl.height = 0.025 if is_rifle else 0.018
	mesh.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.65, 0.25)
	mat.metallic = 0.9
	mat.roughness = 0.25
	mesh.material_override = mat
	shell.add_child(mesh)

	var shape := CollisionShape3D.new()
	var c := CapsuleShape3D.new()
	c.radius = cyl.top_radius
	c.height = cyl.height
	shape.shape = c
	shell.add_child(shape)

	var t := shell.create_tween()
	t.tween_interval(4.0)
	t.tween_callback(shell.queue_free)


static func _spark_ramp() -> Gradient:
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.95, 0.6, 1.0))
	g.set_color(1, Color(1.0, 0.3, 0.05, 0.0))
	return g


static func _smoke_ramp() -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	g.colors = PackedColorArray([
		Color(0.95, 0.95, 0.95, 0.0),
		Color(0.85, 0.85, 0.85, 0.7),
		Color(0.55, 0.55, 0.55, 0.0),
	])
	return g


static func _grow_curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.4))
	c.add_point(Vector2(0.5, 1.0))
	c.add_point(Vector2(1.0, 1.6))
	return c


# Procedurally generated radial-falloff alpha texture for smoke/dust quads.
static var _soft_tex_cache: ImageTexture = null
static func _soft_circle_texture() -> ImageTexture:
	if _soft_tex_cache: return _soft_tex_cache
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var center := Vector2(size, size) * 0.5
	for x in size:
		for y in size:
			var d := Vector2(x, y).distance_to(center) / (size * 0.5)
			if d >= 1.0: continue
			var alpha := pow(1.0 - d, 2.2)
			img.set_pixel(x, y, Color(1, 1, 1, alpha))
	_soft_tex_cache = ImageTexture.create_from_image(img)
	return _soft_tex_cache


# Procedurally generated flash texture — 4-pointed star, white core, yellow edges.
static var _flash_tex_cache: ImageTexture = null
static func _flash_texture() -> ImageTexture:
	if _flash_tex_cache: return _flash_tex_cache
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var center := Vector2(size, size) * 0.5
	for x in size:
		for y in size:
			var v := Vector2(x, y) - center
			var r := v.length() / (size * 0.5)
			if r >= 1.0: continue
			# Star arms: brightness peaks along axes and diagonals
			var a := atan2(v.y, v.x)
			var arm := pow(abs(cos(a * 2.0)), 6.0) * 0.5 + pow(abs(cos(a * 2.0 + PI/4.0)), 8.0) * 0.3
			var core := pow(1.0 - r, 2.0)
			var intensity := clampf(core + arm * (1.0 - r * 0.8), 0.0, 1.0)
			var col := Color(1.0, 0.9 - r * 0.4, 0.5 - r * 0.4, intensity)
			img.set_pixel(x, y, col)
	_flash_tex_cache = ImageTexture.create_from_image(img)
	return _flash_tex_cache


# Procedurally generated black-circle texture used as bullet-hole decal albedo.
static var _hole_tex_cache: ImageTexture = null
static func _hole_texture() -> ImageTexture:
	if _hole_tex_cache: return _hole_tex_cache
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var center := Vector2(32, 32)
	for x in 64:
		for y in 64:
			var d := Vector2(x, y).distance_to(center)
			if d < 8:
				img.set_pixel(x, y, Color(0.05, 0.05, 0.05, 1.0))
			elif d < 14:
				var a := (14.0 - d) / 6.0
				img.set_pixel(x, y, Color(0.1, 0.08, 0.06, a))
	_hole_tex_cache = ImageTexture.create_from_image(img)
	return _hole_tex_cache
