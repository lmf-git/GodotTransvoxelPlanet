extends Node3D

## Entry point. Builds the solar system (sun + orbiting planet system), spawns
## the player as a child of the planet system so they travel with the orbit,
## and wires the planet's chunk streamer to the player's camera.

const PLANET_RADIUS    : float = 24000.0   # ~3× previous; reads as a proper planet from orbit and gives the atmosphere shell real visual thickness
const SPAWN_ALTITUDE   : float = 2500.0   # safely above the highest possible terrain (max surface ≈ radius +2130 m with the Earth-scale height budget)

var world  : PlanetaryWorld
var player : FlightPlayer
var hud_label : Label
var fps_label : Label
var time_label: Label

var _wireframe : bool = false
# Which body the player is parented to / focused on. false = Earth-like planet
# (the spawn default), true = moon. Toggled with [M].
var _focus_moon : bool = false
# Index of the settlement the camera last jumped to ([G] cycles through them).
var _settlement_index : int = -1


func _ready() -> void:
	# TEMP: confirm the native (Rust) GDExtension loaded in this Godot build.
	# Safe even if it didn't load (no hard class reference). Remove once verified.
	if ClassDB.class_exists("NativeTerrain"):
		var nt : Object = ClassDB.instantiate("NativeTerrain")
		print("[native] transvoxel_native LOADED — ping = ", nt.call("ping"))
		var st : Vector3 = nt.call("surface_radius_stats", 1337, PLANET_RADIUS)
		print("[terrain] surface radius  min=%.1f  mean=%.1f  max=%.1f   sea=%.1f  (ocean where surface < sea)" % [
			st.x, st.y, st.z, PLANET_RADIUS - 80.0])
	else:
		print("[native] transvoxel_native NOT loaded (extension didn't register)")

	world = PlanetaryWorld.new()
	# planet_radius is the single size knob: world derives the atmosphere/cloud
	# shell radii from it (planet_radius + fixed absolute offsets) in _ready.
	world.planet_radius = PLANET_RADIUS
	world.name = "World"
	add_child(world)

	player = FlightPlayer.new()
	player.name = "Player"
	# Parent to the PlanetSystem so the player travels with the orbit.
	world.planet_system.add_child(player)
	# Spawn over the equator on the SUNLIT side. The star is at the world
	# origin and the planet orbits out toward +X, so the planet's lit hemisphere
	# faces -X (back toward the sun); the +X face is night. Spawning at -X puts
	# the player over daylit, varied-biome terrain instead of a dark hemisphere
	# that reads as empty void. Expressed in the PlanetSystem local frame.
	player.position = Vector3(-(PLANET_RADIUS + SPAWN_ALTITUDE), 0, 0)
	# look_at uses GLOBAL coordinates and aims the node's -Z at the target.
	# Target = planet center. Up = world up (perpendicular to the +X view dir).
	player.look_at(world.planet_system.global_position, Vector3.UP)

	# Hand the planet reference to the player for gravity/altitude queries.
	player.set_planet(world.planet)
	# Hand the player's camera to the planet for LOD streaming.
	world.planet.set_camera(player.get_viewport().get_camera_3d())

	_build_hud()
	world.planet.stats_changed.connect(_on_planet_stats)
	player.mode_changed.connect(_on_mode_changed)


func _build_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	add_child(canvas)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.position = Vector2(14, 12)
	canvas.add_child(vbox)

	hud_label  = _make_label("")
	fps_label  = _make_label("")
	time_label = _make_label("")
	vbox.add_child(hud_label)
	vbox.add_child(fps_label)
	vbox.add_child(time_label)

	var help := _make_label("")
	help.text = "[WASD] move  [Space/Shift] up-down  [Q/E] roll  [LAlt] boost  [F] flight/walk  [M] planet/moon  [G] next town  [C] clouds  [`] wireframe  [Esc] release mouse"
	help.modulate = Color(1, 1, 1, 0.75)
	vbox.add_child(help)


func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.add_theme_constant_override("shadow_outline_size", 2)
	return l


func _process(_dt: float) -> void:
	fps_label.text = "FPS  %d" % Engine.get_frames_per_second()
	# Time of day / year readouts (phases in [0, 1]).
	var day_t := fposmod(world._spin_phase / TAU, 1.0)
	var year_t := fposmod(world._orbit_phase / TAU, 1.0)
	time_label.text = "Day  %d%% (length %.0fs)   Year  %d%% (length %.0fs)   Tilt %.1f°" % [
		int(day_t * 100.0), world.day_length_sec,
		int(year_t * 100.0), world.orbit_period_sec,
		world.axial_tilt_deg
	]


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_wireframe"):
		_wireframe = not _wireframe
		var debug := Viewport.DEBUG_DRAW_WIREFRAME if _wireframe else Viewport.DEBUG_DRAW_DISABLED
		get_viewport().debug_draw = debug
	# [C] toggles the volumetric cloud deck.
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_C:
		world.toggle_clouds()
	# [M] toggles focus between the planet and the moon: reparents the player to
	# the chosen body so it travels with that body's orbit, drops it above the
	# surface and aims at the body, and repoints gravity/altitude queries there.
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_M:
		_set_focus_to_moon(not _focus_moon)
	# [G] cycles the camera to the next settlement so you don't have to hunt for
	# them. Only meaningful on the planet (the moon has no towns).
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_G:
		_jump_to_next_settlement()


# Reparent + reposition the player onto the planet (false) or the moon (true).
func _set_focus_to_moon(to_moon: bool) -> void:
	_focus_moon = to_moon
	var target_system : Node3D = world.moon_system if to_moon else world.planet_system
	var target_planet : Planet = world.moon if to_moon else world.planet
	# Clear the tallest terrain on whichever body we're dropping onto.
	var surf_max : float = target_planet.density.max_surface_radius()
	# reparent() so the player rides the chosen body's orbit. _ready runs only on
	# first tree entry, so the camera rig isn't rebuilt; pass keep_global=false
	# since we set a fresh local position right after.
	player.reparent(target_system, false)
	# Drop in over the sunlit hemisphere (toward -X, back toward the star), clear
	# of terrain — same convention as the initial spawn in _ready().
	player.position = Vector3(-(surf_max + 500.0), 0.0, 0.0)
	player.look_at(target_system.global_position, Vector3.UP)
	player.set_planet(target_planet)
	player.velocity = Vector3.ZERO


# Fly the camera to an oblique overhead view of the next settlement. Cycles
# through every town on repeated presses. Placed BELOW the cloud deck bottom so
# the town isn't hidden behind cloud, looking down at a slight angle so the
# buildings read with height (a pure top-down shot flattens them).
func _jump_to_next_settlement() -> void:
	if _focus_moon:
		return   # the moon has no settlements
	var n := world.settlement_count()
	if n == 0:
		return
	_settlement_index = (_settlement_index + 1) % n
	var ground := world.settlement_world_pos(_settlement_index)
	var ps := world.planet_system
	var up := (ground - ps.global_position).normalized()
	# A horizontal direction for the oblique offset (any tangent to the surface).
	var tangent := up.cross(Vector3.FORWARD)
	if tangent.length() < 0.01:
		tangent = up.cross(Vector3.RIGHT)
	tangent = tangent.normalized()
	# Vantage: 280 m up + 360 m back along the surface — clear of the +400 m cloud
	# base, ~450 m from the pad, a comfortable establishing shot of the town.
	var cam_world := ground + up * 280.0 + tangent * 360.0
	if mode_is_walk():
		player.mode = FlightPlayer.Mode.FLIGHT
	player.position = ps.to_local(cam_world)
	player.velocity = Vector3.ZERO
	player.look_at(ground, up)


func mode_is_walk() -> bool:
	return player.mode == FlightPlayer.Mode.WALK


func _on_planet_stats(active: int, pending: int, tris: int, lod_violations: int) -> void:
	var focused_planet : Planet = world.moon if _focus_moon else world.planet
	var alt := focused_planet.altitude_above_surface(player.global_position)
	hud_label.text = "Chunks %d (+%d pending)   Tris %s   2:1 violations %d   Altitude %.0f m   Mode %s" % [
		active, pending, _comma(tris), lod_violations, alt,
		"FLIGHT" if player.mode == FlightPlayer.Mode.FLIGHT else "WALK"
	]


func _on_mode_changed(_m: String) -> void:
	pass


func _comma(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c == 3 and i > 0 and s[i - 1].is_valid_int():
			out = "," + out
			c = 0
	return out
