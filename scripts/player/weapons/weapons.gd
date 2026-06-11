class_name Weapons
extends RefCounted

# Weapon model factory. Each weapon's local origin is at the right-hand grip
# (trigger). +Z is the barrel direction, +Y is up (sights), +X is the gun's
# right side. Children: RGrip (always 0,0,0), LGrip (foregrip), Muzzle (barrel
# tip), EjectionPort (where shells come out).

const STEEL := Color(0.12, 0.12, 0.13)
const STEEL_DARK := Color(0.06, 0.06, 0.07)
const POLYMER := Color(0.05, 0.05, 0.05)
const WOOD := Color(0.32, 0.20, 0.10)
const WOOD_DARK := Color(0.18, 0.10, 0.05)


static func create(type: String, scope_tex: Texture2D = null) -> Node3D:
	if type == "pistol":
		return _create_pistol()
	return _create_rifle(scope_tex)


static func _make_mat(color: Color, metallic: float = 0.6, roughness: float = 0.4) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.metallic_specular = 0.5
	m.roughness = roughness
	return m


static func _part(parent: Node3D, mesh: Mesh, pos: Vector3, rot_deg: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.material_override = mat
	parent.add_child(mi)
	return mi


static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new(); b.size = size; return b


static func _cyl(radius: float, height: float, top: float = -1.0) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = radius if top < 0.0 else top
	c.bottom_radius = radius
	c.height = height
	return c


# ─── Pistol ──────────────────────────────────────────────────────────────
static func _create_pistol() -> Node3D:
	var w := Node3D.new()
	w.name = "Pistol"

	var steel := _make_mat(STEEL, 0.85, 0.25)
	var steel_dark := _make_mat(STEEL_DARK, 0.7, 0.35)
	var polymer := _make_mat(POLYMER, 0.05, 0.7)

	# Origin (RGrip) = trigger position. Grip extends DOWN from trigger.
	var r_grip := Node3D.new(); r_grip.name = "RGrip"; w.add_child(r_grip)

	# Grip (polymer, tilted back)
	_part(w, _box(Vector3(0.034, 0.13, 0.05)), Vector3(0, -0.075, -0.005), Vector3(8, 0, 0), polymer)
	# Grip texture stripes
	for i in 5:
		var y := -0.04 - i * 0.018
		_part(w, _box(Vector3(0.036, 0.004, 0.052)), Vector3(0, y, -0.005), Vector3(8, 0, 0), steel_dark)
	# Magazine base
	_part(w, _box(Vector3(0.038, 0.012, 0.05)), Vector3(0, -0.145, -0.012), Vector3(8, 0, 0), steel_dark)

	# Trigger guard
	_part(w, _box(Vector3(0.028, 0.012, 0.06)), Vector3(0, -0.012, 0.04), Vector3.ZERO, steel_dark)
	_part(w, _box(Vector3(0.028, 0.024, 0.008)), Vector3(0, -0.022, 0.07), Vector3.ZERO, steel_dark)
	# Trigger
	_part(w, _box(Vector3(0.008, 0.018, 0.005)), Vector3(0, -0.015, 0.035), Vector3.ZERO, steel)

	# Frame (lower receiver) above trigger
	_part(w, _box(Vector3(0.032, 0.030, 0.16)), Vector3(0, 0.018, 0.04), Vector3.ZERO, steel_dark)

	# Slide (upper) — distinctive top of pistol
	_part(w, _box(Vector3(0.032, 0.032, 0.20)), Vector3(0, 0.045, 0.05), Vector3.ZERO, steel)
	# Slide serrations (rear)
	for i in 6:
		_part(w, _box(Vector3(0.034, 0.030, 0.004)), Vector3(0, 0.045, -0.025 + i * 0.006), Vector3.ZERO, steel_dark)
	# Slide serrations (front)
	for i in 4:
		_part(w, _box(Vector3(0.034, 0.030, 0.004)), Vector3(0, 0.045, 0.115 + i * 0.006), Vector3.ZERO, steel_dark)

	# Barrel mouth
	_part(w, _cyl(0.009, 0.012), Vector3(0, 0.045, 0.16), Vector3(90, 0, 0), steel_dark)
	# Barrel inner (gives muzzle a darker hole look)
	_part(w, _cyl(0.005, 0.013), Vector3(0, 0.045, 0.161), Vector3(90, 0, 0), _make_mat(Color(0.02, 0.02, 0.02), 0, 1))

	# Front sight
	_part(w, _box(Vector3(0.006, 0.008, 0.008)), Vector3(0, 0.066, 0.14), Vector3.ZERO, steel_dark)
	# Rear sight
	_part(w, _box(Vector3(0.024, 0.006, 0.012)), Vector3(0, 0.064, -0.03), Vector3.ZERO, steel_dark)
	_part(w, _box(Vector3(0.006, 0.012, 0.012)), Vector3(-0.008, 0.066, -0.03), Vector3.ZERO, steel_dark)
	_part(w, _box(Vector3(0.006, 0.012, 0.012)), Vector3(0.008, 0.066, -0.03), Vector3.ZERO, steel_dark)

	# Hammer (back)
	_part(w, _box(Vector3(0.014, 0.020, 0.012)), Vector3(0, 0.040, -0.085), Vector3(20, 0, 0), steel_dark)

	# Muzzle / EjectionPort / LGrip
	var muzzle := Node3D.new(); muzzle.name = "Muzzle"; muzzle.position = Vector3(0, 0.045, 0.175); w.add_child(muzzle)
	var eject := Node3D.new(); eject.name = "EjectionPort"
	eject.position = Vector3(0.020, 0.055, 0.04); w.add_child(eject)
	var l_grip := Node3D.new(); l_grip.name = "LGrip"
	# Support hand wraps around shooting hand from the left
	l_grip.position = Vector3(-0.030, -0.025, 0.005); w.add_child(l_grip)
	return w


# ─── Rifle (AK-style) ────────────────────────────────────────────────────
static func _create_rifle(scope_tex: Texture2D = null) -> Node3D:
	var w := Node3D.new()
	w.name = "Rifle"

	var steel := _make_mat(STEEL, 0.85, 0.3)
	var steel_dark := _make_mat(STEEL_DARK, 0.75, 0.4)
	var polymer := _make_mat(POLYMER, 0.05, 0.65)
	var wood := _make_mat(WOOD, 0.15, 0.55)
	var wood_dark := _make_mat(WOOD_DARK, 0.15, 0.6)

	# Origin (RGrip) = pistol grip position.
	var r_grip := Node3D.new(); r_grip.name = "RGrip"; w.add_child(r_grip)

	# Pistol grip
	_part(w, _box(Vector3(0.036, 0.13, 0.05)), Vector3(0, -0.08, 0), Vector3(-12, 0, 0), polymer)
	for i in 4:
		_part(w, _box(Vector3(0.038, 0.005, 0.052)), Vector3(0, -0.05 - i * 0.020, 0.0), Vector3(-12, 0, 0), steel_dark)

	# Trigger guard
	_part(w, _box(Vector3(0.028, 0.012, 0.08)), Vector3(0, -0.012, 0.03), Vector3.ZERO, steel_dark)
	_part(w, _box(Vector3(0.028, 0.024, 0.008)), Vector3(0, -0.024, 0.07), Vector3.ZERO, steel_dark)
	# Trigger
	_part(w, _box(Vector3(0.008, 0.018, 0.005)), Vector3(0, -0.015, 0.035), Vector3.ZERO, steel)

	# Lower receiver
	_part(w, _box(Vector3(0.040, 0.045, 0.28)), Vector3(0, 0.015, 0.04), Vector3.ZERO, steel_dark)

	# Upper receiver / dust cover (forward & back)
	_part(w, _box(Vector3(0.038, 0.025, 0.32)), Vector3(0, 0.050, 0.04), Vector3.ZERO, steel)
	# Top cover detail
	for i in 4:
		_part(w, _box(Vector3(0.040, 0.024, 0.004)), Vector3(0, 0.052, -0.08 + i * 0.05), Vector3.ZERO, steel_dark)

	# Magazine (banana, curving down/forward)
	var mag := Node3D.new(); w.add_child(mag)
	mag.position = Vector3(0, -0.025, 0.08)
	mag.rotation_degrees = Vector3(15, 0, 0)
	_part(mag, _box(Vector3(0.034, 0.16, 0.045)), Vector3(0, -0.075, 0.005), Vector3.ZERO, steel_dark)
	_part(mag, _box(Vector3(0.036, 0.020, 0.045)), Vector3(0, -0.16, 0.012), Vector3(8, 0, 0), steel_dark)
	# Mag ribs
	for i in 3:
		_part(mag, _box(Vector3(0.038, 0.004, 0.046)), Vector3(0, -0.04 - i * 0.04, 0.005), Vector3.ZERO, steel)

	# Handguard (wood)
	_part(w, _box(Vector3(0.044, 0.035, 0.20)), Vector3(0, 0.025, 0.22), Vector3.ZERO, wood)
	# Handguard grooves
	for i in 4:
		_part(w, _box(Vector3(0.045, 0.004, 0.20)), Vector3(0.018 - i * 0.012, 0.045, 0.22), Vector3.ZERO, wood_dark)
	# Gas tube above handguard
	_part(w, _cyl(0.012, 0.22), Vector3(0, 0.075, 0.22), Vector3(90, 0, 0), steel_dark)

	# (Front sight removed — was blocking the scope lens.)
	# Rear sight
	_part(w, _box(Vector3(0.030, 0.014, 0.030)), Vector3(0, 0.072, 0.10), Vector3.ZERO, steel_dark)
	_part(w, _box(Vector3(0.024, 0.020, 0.012)), Vector3(0, 0.080, 0.105), Vector3(-20, 0, 0), steel_dark)

	# Barrel
	_part(w, _cyl(0.011, 0.42), Vector3(0, 0.072, 0.42), Vector3(90, 0, 0), steel_dark)
	# Muzzle device (slant brake / flash hider)
	_part(w, _cyl(0.014, 0.055, 0.012), Vector3(0, 0.072, 0.640), Vector3(90, 0, 0), steel)
	# Muzzle inner hole
	_part(w, _cyl(0.007, 0.058), Vector3(0, 0.072, 0.640), Vector3(90, 0, 0), _make_mat(Color(0.02, 0.02, 0.02), 0, 1))

	# Buttstock (wood)
	_part(w, _box(Vector3(0.038, 0.060, 0.26)), Vector3(0, 0.035, -0.20), Vector3(0, 0, 0), wood)
	# Stock taper / cheek piece
	_part(w, _box(Vector3(0.036, 0.020, 0.22)), Vector3(0, 0.068, -0.18), Vector3(-3, 0, 0), wood)
	# Recoil pad
	_part(w, _box(Vector3(0.040, 0.080, 0.014)), Vector3(0, 0.040, -0.335), Vector3.ZERO, _make_mat(Color(0.05, 0.05, 0.05), 0, 0.9))
	# Sling loop on stock
	_part(w, _cyl(0.004, 0.025), Vector3(-0.020, 0.055, -0.06), Vector3(0, 0, 90), steel_dark)

	# Charging handle
	_part(w, _box(Vector3(0.050, 0.012, 0.020)), Vector3(0.025, 0.062, 0.00), Vector3.ZERO, steel_dark)

	# Optional scope (with PIP texture)
	if scope_tex:
		# Mount
		_part(w, _box(Vector3(0.044, 0.026, 0.12)), Vector3(0, 0.082, 0.05), Vector3.ZERO, steel_dark)
		# Scope tube
		_part(w, _cyl(0.020, 0.18), Vector3(0, 0.115, 0.05), Vector3(90, 0, 0), steel_dark)
		# Objective lens
		_part(w, _cyl(0.024, 0.020), Vector3(0, 0.115, 0.145), Vector3(90, 0, 0), steel_dark)
		# Eyepiece (slightly shorter so the lens face isn't coplanar with the tube end)
		_part(w, _cyl(0.024, 0.022), Vector3(0, 0.115, -0.052), Vector3(90, 0, 0), steel_dark)
		# Lens with PIP — face it toward the shooter (-Z) and tuck it 2mm beyond
		# the back face of the eyepiece tube to eliminate z-fighting.
		var lens := MeshInstance3D.new()
		var qm := QuadMesh.new(); qm.size = Vector2(0.038, 0.038)
		lens.mesh = qm
		var lmat := ShaderMaterial.new()
		lmat.shader = Shader.new()
		lmat.shader.code = """shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D tex;
void fragment() {
	vec2 uv = UV - vec2(0.5);
	float r = length(uv);
	if (r > 0.5) { discard; }
	ALBEDO = texture(tex, UV).rgb;
}"""
		lmat.set_shader_parameter("tex", scope_tex)
		lens.material_override = lmat
		# Eyepiece center Z=-0.052, length 0.022 along Z (after rotation) → back face at Z=-0.063.
		# Place lens at Z=-0.066 so it sits 3mm behind the rear face, facing the player.
		lens.position = Vector3(0, 0.115, -0.066)
		# Face the lens quad toward the player (-Z) without flipping UVs
		# vertically — rotating around Y preserves texture orientation,
		# rotating around X (the old value) made the scope appear upside-down.
		lens.rotation_degrees = Vector3(0, 180, 0)
		lens.layers = 2
		w.add_child(lens)

	# Muzzle / EjectionPort / LGrip nodes
	var muzzle := Node3D.new(); muzzle.name = "Muzzle"; muzzle.position = Vector3(0, 0.072, 0.665); w.add_child(muzzle)
	var eject := Node3D.new(); eject.name = "EjectionPort"
	eject.position = Vector3(0.025, 0.060, 0.04); w.add_child(eject)
	var l_grip := Node3D.new(); l_grip.name = "LGrip"
	# Left hand on the wood handguard
	l_grip.position = Vector3(0, 0.005, 0.22); w.add_child(l_grip)
	return w
