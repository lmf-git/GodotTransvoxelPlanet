extends Node3D

var bc_g7: float        = 0.150
var mass_gr: float      = 123.0
var velocity: Vector3   = Vector3.ZERO
var wind: Vector3       = Vector3.ZERO
var rho: float          = 1.225
var temp_c: float       = 15.0
var damage: float       = 35.0
var ignore_body: PhysicsBody3D = null
# Full gravity vector — set by the shooter to point at the planet center.
var gravity: Vector3    = Vector3(0.0, -Ballistics.G, 0.0)

var tof: float      = 0.0
var alive: bool     = true
const SUBSTEPS      := 4

var _trail: MeshInstance3D
var _tracer: bool = true

func _ready() -> void:
	_build_mesh()
	if _tracer:
		_build_trail()

func _build_mesh() -> void:
	var mi  := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.005
	cap.height = 0.03
	mi.mesh   = cap
	var mat  := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.7, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.7, 0.2)
	mat.emission_energy_multiplier = 3.0
	mi.material_override = mat
	add_child(mi)
	mi.rotation_degrees.x = 90.0

func _build_trail() -> void:
	# Short tracer streak that extends BEHIND the bullet (bullet's +Z is the
	# anti-velocity direction because look_at orients -Z toward target).
	# Kept short so on the first frame it doesn't extend back into the muzzle.
	_trail = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.008, 0.008, 0.35)
	_trail.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(1.0, 0.65, 0.2, 0.7)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.15)
	mat.emission_energy_multiplier = 2.5
	_trail.material_override = mat
	_trail.position = Vector3(0, 0, 0.175)  # center half of length back
	add_child(_trail)

# The trajectory is integrated in the PARENT's frame (`position`, with
# `velocity`/`gravity`/`wind` expressed in parent-local axes). Parent the
# bullet to the planet node so the planet's spin carries the trajectory with
# the terrain — simulated in world space the ground would move tens of metres
# during the flight. Ray queries convert to world space at the boundary.
func _physics_process(delta: float) -> void:
	if not alive: return

	var dt := delta / float(SUBSTEPS)
	var parent := get_parent() as Node3D

	for _s in SUBSTEPS:
		var result := Ballistics.rk4(position, velocity, tof, dt, bc_g7, wind, rho, temp_c, gravity)
		var new_pos: Vector3 = result[0]
		var new_vel: Vector3 = result[1]

		var from_w := global_position
		var to_w : Vector3 = parent.to_global(new_pos) if parent else new_pos
		var space := get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(from_w, to_w)
		query.collision_mask = 0x7FFFFFFF
		if ignore_body:
			query.exclude = [ignore_body.get_rid()]
		var hit := space.intersect_ray(query)

		if hit:
			_on_hit(hit, new_vel)
			return

		position = new_pos
		velocity = new_vel
		tof += dt

		if velocity.length_squared() > 1.0:
			# Up reference perpendicular to gravity (radial on a planet); falls
			# back when the trajectory is near-vertical. World-space for look_at.
			var pb : Basis = parent.global_transform.basis if parent else Basis.IDENTITY
			var vel_w := (pb * velocity).normalized()
			var up_ref := -(pb * gravity).normalized() if gravity.length_squared() > 0.0001 else Vector3.UP
			if absf(vel_w.dot(up_ref)) > 0.95:
				up_ref = up_ref.cross(Vector3.RIGHT).normalized() \
						if absf(up_ref.dot(Vector3.RIGHT)) < 0.95 else up_ref.cross(Vector3.FORWARD).normalized()
			look_at(global_position + vel_w, up_ref)

	if tof > 10.0:
		queue_free()

func _on_hit(hit: Dictionary, last_vel: Vector3) -> void:
	alive = false
	var collider = hit.collider
	var hit_pos: Vector3 = hit.position
	var hit_normal: Vector3 = hit.normal
	var parent := get_parent() as Node3D

	# Impact effects — parented to the same co-rotating frame as the bullet so
	# the sparks/smoke don't drift off as the planet spins.
	var fx_parent : Node = parent
	if fx_parent == null:
		fx_parent = get_tree().root
	Effects.spawn_impact(fx_parent, hit_pos, hit_normal, collider)

	# Physics & damage (impulse in world space)
	var last_vel_w : Vector3 = (parent.global_transform.basis * last_vel) if parent else last_vel
	var impulse := last_vel_w.normalized() * mass_gr * 0.0001 * last_vel_w.length()
	if collider is Target:
		(collider as Target).take_hit(damage, hit_pos, impulse)
	elif collider is RigidBody3D:
		(collider as RigidBody3D).apply_impulse(impulse, hit_pos - (collider as RigidBody3D).global_position)

	queue_free()
