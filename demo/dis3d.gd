## 3D DIS demo: one side of the godot-dis two-sided exercise around Ankara, on real terrain.
## Needs the sibling repositories linked once: .\tools\link_siblings.ps1 (see docs/demo-3d.md).
##   <godot> --path . res://demo/dis3d.tscn -- --side blue
## Other participants: the godot-dis 2D demo (--side red) and godot-dis tools/demo_traffic.py (civilian traffic).
## Own units drive on the terrain (DemoUnitMover with ground); remote land units are put on it by
## DisEntityManager (ground_path), because the sender's terrain is not ours.
## Controls: Tab / Shift+Tab next / previous unit, drag (left mouse) orbit, wheel zoom, C free camera
## (right mouse + WASD / Q E, Shift fast). --shots <dir> saves a few views after --warmup seconds and quits.
extends Node3D

const PACKAGES := ["res://terrain/ankara_60km", "res://terrain/ankara", "res://tests/data/ankara_small"]
const SUN_ELEVATION := 24.0
const SUN_AZIMUTH := 235.0

@onready var network: DisNetwork = $DisNetwork
@onready var origin: DisGeoOrigin = $DisGeoOrigin
@onready var terrain: GeoTerrain = $GeoTerrain
@onready var manager: DisEntityManager = $DisEntityManager
@onready var own_forces: Node3D = $OwnForces
@onready var camera: Camera3D = $Camera
@onready var info: Label = $HUD/Info

var side := "blue"
var selected := 0
var free_camera := false
var orbit_yaw := 0.6
var orbit_pitch := -0.35
var orbit_distance := 180.0
var _units: Array = []
var _map: DemoTacticalMap
var _type_cache := {}
var _speed := 300.0
var _shots_dir := ""


func _ready() -> void:
	side = _argument("--side", "blue")
	if not DemoScenario.SIDES.has(side):
		side = "blue"
	var side_info: Dictionary = DemoScenario.SIDES[side]
	network.site_id = side_info.site
	get_window().title = "godot-geo 3D DIS demo — %s" % side_info.title
	_place_sun()
	for p: String in PACKAGES:
		if FileAccess.file_exists(p.path_join("terrain.json")):
			terrain.package_path = p
			break
	if not terrain.is_loaded():
		push_error("No terrain package; build one with tools/build_terrain.py (see docs/demo-3d.md).")
		return
	camera.far = terrain.package.size_m * 3.0
	$HUD/Attribution.text = "\n".join(terrain.attribution()) + \
			"\nEnumerations: SISO-REF-010, reprinted with permission from SISO Inc.  Symbols: MIL-STD-2525D (approx.)"
	manager.ground_path = manager.get_path_to(terrain)
	manager.entity_appeared.connect(_on_entity_appeared)
	_spawn_units(side_info)
	_build_map()
	_shots_dir = _argument("--shots", "")
	if not _shots_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(_shots_dir)
		_take_shots.call_deferred(float(_argument("--warmup", "8")))


func _argument(name: String, default: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else default


func _place_sun() -> void:
	var el := deg_to_rad(SUN_ELEVATION)
	var az := deg_to_rad(SUN_AZIMUTH)
	var to_sun := Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))
	$Sun.basis = Basis.looking_at(-to_sun, Vector3.UP)


func _type_info(entity_type: PackedInt32Array, force: int) -> Dictionary:
	var key := "%s/%d" % [entity_type, force]
	if not _type_cache.has(key):
		_type_cache[key] = {"name": DisEnums.get_entity_type_name(entity_type),
				"sidc": DisEnums.entity_type_to_sidc(entity_type, force)}
	return _type_cache[key]


func _spawn_units(side_info: Dictionary) -> void:
	var units := DemoScenario.units(side)
	for i in units.size():
		var unit: Dictionary = units[i]
		var mover := DemoUnitMover.new()
		mover.name = unit.marking
		mover.route = unit.route
		mover.speed = unit.speed
		mover.altitude = unit.altitude
		mover.distance = unit.start
		mover.ground = terrain
		var entity := DisEntity.new()
		entity.entity_id = Vector3i(0, 0, i + 1)
		entity.force_id = side_info.force
		entity.entity_type = unit.entity_type
		entity.marking = unit.marking
		entity.dr_algorithm = unit.dr_algorithm
		mover.add_child(entity)
		_add_visual(mover, entity.entity_type, entity.force_id, entity.marking)
		own_forces.add_child(mover)


func _on_entity_appeared(remote: DisRemoteEntity) -> void:
	_add_visual(remote, remote.entity_type, remote.force_id, remote.marking)


func _add_visual(parent: Node3D, entity_type: PackedInt32Array, force: int, marking: String) -> void:
	var visual := Dis3DUnit.new()
	visual.name = "Visual"
	visual.terrain = terrain
	visual.setup(entity_type, force, marking, _type_info(entity_type, force).sidc)
	parent.add_child(visual)


func _build_map() -> void:
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -400
	panel.offset_top = -330
	panel.offset_right = -12
	panel.offset_bottom = -12
	$HUD.add_child(panel)
	_map = DemoTacticalMap.new()
	_map.origin = origin
	_map.meters_per_pixel = 140.0
	panel.add_child(_map)


static func _heading(basis: Basis) -> float:
	var forward := -basis.z
	return atan2(forward.x, -forward.z)


## Same dictionaries as the godot-dis demo, plus "node"; the map's position.y is the height above ground.
func _collect_units() -> Array:
	var result := []
	for mover: DemoUnitMover in own_forces.get_children():
		var entity: DisEntity = mover.get_child(0)
		result.append(_unit_dict("own/" + entity.marking, mover, entity.entity_type, entity.force_id, entity.marking,
				mover.speed, "own"))
	for remote: DisRemoteEntity in manager.get_entities():
		var velocity := origin.ecef_vector_to_local(remote.get_last_pdu().linear_velocity)
		result.append(_unit_dict("remote/%s" % remote.entity_id, remote, remote.entity_type, remote.force_id,
				remote.marking, Vector2(velocity.x, velocity.z).length(),
				"remote %d:%d:%d" % [remote.entity_id.x, remote.entity_id.y, remote.entity_id.z]))
	result.sort_custom(func(a, b): return [a.force, a.marking] < [b.force, b.marking])
	return result


func _unit_dict(key: String, node: Node3D, entity_type: PackedInt32Array, force: int, marking: String,
		speed: float, source: String) -> Dictionary:
	var t := _type_info(entity_type, force)
	var p := node.global_position
	var ground := terrain.height_at(p.x, p.z)
	var agl := p.y - ground if not is_nan(ground) else p.y
	return {"key": key, "node": node, "marking": marking, "name": t.name, "sidc": t.sidc, "force": force,
			"position": Vector3(p.x, agl, p.z), "agl": agl, "heading": _heading(node.global_basis), "speed": speed,
			"source": source, "air": entity_type.size() > 1 and entity_type[1] == 2}


func _process(delta: float) -> void:
	if not terrain.is_loaded():
		return
	_units = _collect_units()
	_map.set_units(_units, delta)
	if _units.is_empty():
		return
	selected = posmod(selected, _units.size())
	var unit: Dictionary = _units[selected]
	var node: Node3D = unit.node
	if free_camera:
		_fly(delta)
	else:
		_orbit(node.global_position)
	_map.center = Vector2(node.global_position.x, node.global_position.z)
	var g := origin.local_to_geodetic(node.global_position)
	var stats := network.get_statistics()
	info.text = ("%s   own %d  remote %d   sent %d  received %d   %d fps\n\n%s  %s\n%s · %s\n%.5f° N  %.5f° E   "
			+ "h %.0f m (WGS84)   %d m above ground   %d km/h\n\nTab: next unit   drag: orbit   wheel: zoom   "
			+ "C: %s") % [DemoScenario.SIDES[side].title, own_forces.get_child_count(), manager.get_entity_count(),
			stats.sent, stats.received, Engine.get_frames_per_second(), unit.marking, unit.name,
			DisEnums.get_enum_name("force_id", unit.force), unit.source, g[0], g[1], g[2], roundi(unit.agl),
			roundi(unit.speed * 3.6), "orbit camera" if free_camera else "free camera"]


func _orbit(target: Vector3) -> void:
	var dir := Vector3(sin(orbit_yaw) * cos(orbit_pitch), -sin(orbit_pitch), cos(orbit_yaw) * cos(orbit_pitch))
	var pos := target + dir * orbit_distance
	var ground := terrain.height_at(pos.x, pos.z)
	if not is_nan(ground):
		pos.y = maxf(pos.y, ground + 5.0)
	camera.global_position = pos
	camera.look_at(target + Vector3(0, 3, 0))


func _fly(delta: float) -> void:
	var dir := Vector3(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	camera.translate(dir * _speed * (5.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0) * delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if free_camera and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			camera.rotate_y(-event.relative.x * 0.003)
			camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * 0.003)
		elif not free_camera and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			orbit_yaw -= event.relative.x * 0.005
			orbit_pitch = clampf(orbit_pitch - event.relative.y * 0.005, -1.5, 0.3)
	elif event is InputEventMouseButton and event.pressed:
		var zoom := 1.15 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else \
				(1.0 / 1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0)
		orbit_distance = clampf(orbit_distance * zoom, 20.0, 60000.0)
		_speed = clampf(_speed / zoom, 5.0, 20000.0)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			selected += -1 if event.shift_pressed else 1
		elif event.keycode == KEY_C:
			free_camera = not free_camera


## Screenshots for docs: (marking or "", yaw, pitch, distance, file).
func _take_shots(warmup: float) -> void:
	await get_tree().create_timer(warmup).timeout
	var shots := [
		["T-1", 2.4, -0.3, 45.0, "tank_close"],
		["HEL-1", 0.9, -0.15, 70.0, "helicopter"],
		["R-T1", -0.8, -0.3, 50.0, "remote_tank"],
		["T-1", 2.0, -0.55, 6000.0, "exercise"],
		["CAR-1", 1.2, -0.3, 40.0, "civilian"],
		["", 0.0, -1.2, 55000.0, "overview"],
	]
	for s: Array in shots:
		var index := -1
		for i in _units.size():
			if _units[i].marking == s[0]:
				index = i
		if index < 0 and s[0] != "":
			print("shot %s: unit %s not on the network, skipped" % [s[4], s[0]])
			continue
		selected = maxi(index, 0)
		orbit_yaw = s[1]
		orbit_pitch = s[2]
		orbit_distance = s[3]
		if s[0] == "":  # whole exercise, centred on the origin
			free_camera = true
			camera.global_position = Vector3(2000, 19000, 22000)
			camera.look_at(Vector3(0, 0, -2000))
		for i in 30:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png(_shots_dir.path_join(s[4] + ".png"))
		free_camera = false
	print("units: ", _units.map(func(u): return u.marking))
	get_tree().quit()
