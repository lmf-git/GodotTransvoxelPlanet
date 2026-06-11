class_name Target
extends RigidBody3D

@export var max_hp: float = 100.0

var hp: float = 100.0
var _orig_color: Color
var _mesh: MeshInstance3D

func _ready():
	hp = max_hp
	_mesh = _find_first_mesh(self)
	if _mesh and _mesh.material_override is StandardMaterial3D:
		_orig_color = (_mesh.material_override as StandardMaterial3D).albedo_color

func _find_first_mesh(n: Node) -> MeshInstance3D:
	for c in n.get_children():
		if c is MeshInstance3D: return c
		var sub := _find_first_mesh(c)
		if sub: return sub
	return null

func take_hit(damage: float, point: Vector3, impulse: Vector3):
	hp -= damage
	apply_impulse(impulse, point - global_position)
	_flash()
	if hp <= 0.0:
		_die()

func _flash():
	if not _mesh or not _mesh.material_override is StandardMaterial3D: return
	var mat: StandardMaterial3D = _mesh.material_override
	mat.albedo_color = Color(1, 0.3, 0.2)
	var t := create_tween()
	t.tween_property(mat, "albedo_color", _orig_color, 0.25)

func _die():
	# Disable hit detection; let it fall freely and despawn
	collision_layer = 0
	freeze = false
	var t := create_tween()
	t.tween_interval(5.0)
	t.tween_callback(queue_free)


# ─── Static factory helpers ─────────────────────────────────────────────
static func make_steel_plate(pos: Vector3) -> Target:
	var t := Target.new()
	t.position = pos
	t.mass = 8.0
	t.gravity_scale = 1.0

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.6, 0.8, 0.04)
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.2, 0.18)
	mat.metallic = 0.7
	mat.roughness = 0.4
	mesh.material_override = mat
	t.add_child(mesh)

	# White center disc
	var disc := MeshInstance3D.new()
	var qm := QuadMesh.new(); qm.size = Vector2(0.30, 0.30)
	disc.mesh = qm
	var dmat := StandardMaterial3D.new()
	dmat.albedo_color = Color(0.95, 0.95, 0.95)
	dmat.metallic = 0.0
	dmat.roughness = 0.7
	disc.material_override = dmat
	disc.position = Vector3(0, 0.05, 0.021)
	t.add_child(disc)

	# Bullseye
	var bull := MeshInstance3D.new()
	var bqm := QuadMesh.new(); bqm.size = Vector2(0.10, 0.10)
	bull.mesh = bqm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.1, 0.1, 0.12)
	bull.material_override = bmat
	bull.position = Vector3(0, 0.05, 0.022)
	t.add_child(bull)

	# Post mount
	var post := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.02; cyl.bottom_radius = 0.02; cyl.height = 0.5
	post.mesh = cyl
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.25, 0.22, 0.20)
	pmat.metallic = 0.3
	pmat.roughness = 0.7
	post.material_override = pmat
	post.position = Vector3(0, -0.65, 0)
	t.add_child(post)

	var shape := CollisionShape3D.new()
	var s := BoxShape3D.new()
	s.size = Vector3(0.6, 1.6, 0.04)
	shape.shape = s
	shape.position = Vector3(0, -0.4, 0)
	t.add_child(shape)
	return t


static func make_barrel(pos: Vector3) -> Target:
	var t := Target.new()
	t.position = pos
	t.mass = 25.0
	t.max_hp = 80.0

	var mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.28; cyl.bottom_radius = 0.28; cyl.height = 0.9
	mesh.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.35, 0.18)
	mat.metallic = 0.6
	mat.roughness = 0.45
	mesh.material_override = mat
	mesh.position = Vector3(0, 0.45, 0)
	t.add_child(mesh)

	# Top/bottom rings
	for y in [0.05, 0.85]:
		var ring := MeshInstance3D.new()
		var rc := CylinderMesh.new()
		rc.top_radius = 0.29; rc.bottom_radius = 0.29; rc.height = 0.04
		ring.mesh = rc
		var rmat := StandardMaterial3D.new()
		rmat.albedo_color = Color(0.1, 0.18, 0.08); rmat.metallic = 0.7; rmat.roughness = 0.4
		ring.material_override = rmat
		ring.position = Vector3(0, y, 0)
		t.add_child(ring)

	var shape := CollisionShape3D.new()
	var s := CylinderShape3D.new()
	s.radius = 0.28; s.height = 0.9
	shape.shape = s
	shape.position = Vector3(0, 0.45, 0)
	t.add_child(shape)
	return t


static func make_crate(pos: Vector3) -> Target:
	var t := Target.new()
	t.position = pos
	t.mass = 5.0
	t.max_hp = 50.0

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.5, 0.5)
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.30, 0.15)
	mat.roughness = 0.85
	mat.metallic = 0.0
	mesh.material_override = mat
	mesh.position = Vector3(0, 0.25, 0)
	t.add_child(mesh)

	# Crate planks (slight overlays)
	for axis in [Vector3.RIGHT, Vector3.FORWARD]:
		for offset in [-0.13, 0.13]:
			var plank := MeshInstance3D.new()
			var pb := BoxMesh.new()
			pb.size = Vector3(0.502, 0.08, 0.502) if axis == Vector3.RIGHT else Vector3(0.502, 0.08, 0.502)
			plank.mesh = pb
			var pmat := StandardMaterial3D.new()
			pmat.albedo_color = Color(0.30, 0.18, 0.08)
			pmat.roughness = 0.9
			plank.material_override = pmat
			plank.position = Vector3(0, 0.25 + offset, 0)
			t.add_child(plank)

	var shape := CollisionShape3D.new()
	var s := BoxShape3D.new()
	s.size = Vector3(0.5, 0.5, 0.5)
	shape.shape = s
	shape.position = Vector3(0, 0.25, 0)
	t.add_child(shape)
	return t
