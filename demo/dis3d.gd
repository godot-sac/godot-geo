## 3D DIS demo: one side of the godot-dis two-sided exercise around Üsküdar (Istanbul), on real terrain with its
## buildings, trees, roads and the Bosphorus.
## Needs the sibling repositories linked once: python tools/link_siblings.py (see docs/demo-3d.md).
##   <godot> --path . res://demo/dis3d.tscn -- --side blue
## Other participants: the godot-dis 2D demo (--side red) and godot-dis tools/demo_traffic.py (civilian traffic).
## Own units drive on the terrain (DemoUnitMover with ground); remote land units are put on it by
## DisEntityManager (ground_path), because the sender's terrain is not ours.
##
## Keys (F1 shows them): Tab / Shift+Tab unit, left drag orbit, wheel zoom, C free camera (right mouse + WASD / Q E),
## [ ] own units slower / faster, P pause own units, PgUp / PgDn move the selected own unit 1 km along its route,
## F3 debug overlay, F9 log to CSV, F12 screenshot.
## Options after --: --side blue|red, --port N, --seconds N (quit), --log file.csv, --check N (test run, report, exit
## code 1 on problems), --shots dir [--warmup s] (documentation views).
extends Node3D

## The exercise spans about ±14 km (aircraft) and the red land units are 4-8 km east of the origin, so the 60 km
## package comes first; the 10 km one shows the blue side only.
const PACKAGES := ["res://terrain/uskudar", "res://terrain/uskudar_10km", "res://tests/data/uskudar_small"]
const SUN_ELEVATION := 24.0
const SUN_AZIMUTH := 235.0
const SAMPLE_INTERVAL := 0.1  # log and check rate, seconds
const HELP := """Tab / Shift+Tab   next / previous unit
Left drag         orbit around the unit      Wheel   zoom
C                 free camera (right mouse + WASD, Q / E down / up, Shift fast)
[  ]              own units slower / faster  P       pause own units
PgUp / PgDn       move the selected own unit 1 km along its route
F3                debug overlay              F9      start / stop CSV log
F12               screenshot                 F1      this help"""

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
var show_help := false
var show_debug := false
var _units: Array = []
var _map: DemoTacticalMap
var _type_cache := {}
var _speed := 300.0
var _time_scale := 1.0
var _paused := false
var _message := ""
var _message_until := 0.0
var _shots_dir := ""
var _log: FileAccess
var _log_path := ""
var _sample_clock := 0.0
var _quit_at := 0.0
var _check: Dis3DCheck
var _check_path := ""
var _started := 0.0
var _last_pos := {}  # unit key -> [position, speed] of the previous frame, for the debug overlay
var _frame_jump := {}  # unit key -> largest unexplained movement in one frame (m) since selection
var _last_frame := 0.0  # wall clock of the previous frame (delta is scaled by the own units' time scale)
var _frame_times := PackedFloat32Array()  # wall-clock frame times during --check, ms


func _ready() -> void:
	side = _argument("--side", "blue")
	if not DemoScenario.SIDES.has(side):
		side = "blue"
	var side_info: Dictionary = DemoScenario.SIDES[side]
	network.site_id = side_info.site
	var port := int(_argument("--port", str(network.port)))
	if port != network.port:  # the network started in its own _ready (children are ready first)
		network.stop()
		network.port = port
		network.start()
	get_window().title = "godot-geo 3D DIS demo — %s" % side_info.title
	_place_sun()
	for p: String in PACKAGES:
		if FileAccess.file_exists(p.path_join("terrain.json")):
			terrain.package_path = p
			break
	if not terrain.is_loaded():
		push_error("No terrain package; build one with tools/build_terrain.py (see docs/demo-3d.md).")
		return
	if terrain.package.size_m < 30000.0:
		push_warning("terrain %s covers ±%d km; the exercise spans ±14 km, units beyond it keep their reported height "
				% [terrain.package_path, terrain.package.size_m / 2000.0] + "(build terrain/uskudar, see docs/demo-3d.md)")
	camera.far = terrain.package.size_m * 3.0
	$HUD/Attribution.text = "\n".join(terrain.attribution()) + \
			"\nEnumerations: SISO-REF-010, reprinted with permission from SISO Inc.  Symbols: MIL-STD-2525D (approx.)"
	manager.ground_path = manager.get_path_to(terrain)
	manager.entity_appeared.connect(_on_entity_appeared)
	_spawn_units(side_info)
	_build_map()
	_started = _now()
	if _argument("--log", "") != "":
		_start_log(_argument("--log", ""))
	if float(_argument("--seconds", "0")) > 0.0:
		_quit_at = _started + float(_argument("--seconds", "0"))
	if float(_argument("--check", "0")) > 0.0:
		_check = Dis3DCheck.new()
		_check_path = _argument("--report", "user://dis3d_check.json")
		_quit_at = _started + float(_argument("--check", "0"))
		print("checking for %s s" % _argument("--check", "0"))
	_shots_dir = _argument("--shots", "")
	if not _shots_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(_shots_dir)
		_take_shots.call_deferred(float(_argument("--warmup", "8")))


func _argument(name: String, default: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else default


static func _now() -> float:
	return Time.get_ticks_usec() / 1.0e6


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
		mover.surface = unit.get("surface", false)  # ships: on the water surface that height_at gives
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
	_map.meters_per_pixel = 60.0  # the exercise: about ±10 km of Üsküdar and the Bosphorus
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
				mover.speed * Engine.time_scale, "own"))
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
	var now := _now()
	var real_delta := now - _last_frame if _last_frame > 0.0 else 0.0
	_last_frame = now
	_track_frame_jumps(real_delta)
	if _check and now - _started > Dis3DCheck.WARMUP:
		_frame_times.append(real_delta * 1000.0)
	_sample_clock += delta
	if _sample_clock >= SAMPLE_INTERVAL:
		_sample_clock = 0.0
		_write_log()
		if _check:
			_check.add(_units, _now() - _started, terrain)
	if _quit_at > 0.0 and _now() >= _quit_at:
		_finish()
		return
	if _units.is_empty():
		info.text = "waiting for units..."
		return
	selected = posmod(selected, _units.size())
	var unit: Dictionary = _units[selected]
	var node: Node3D = unit.node
	if free_camera:
		_fly(delta)
	else:
		_orbit(node.global_position)
	_map.center = Vector2(node.global_position.x, node.global_position.z)
	_update_hud(unit)


func _update_hud(unit: Dictionary) -> void:
	var node: Node3D = unit.node
	var g := origin.local_to_geodetic(node.global_position)
	var stats := network.get_statistics()
	var lines := PackedStringArray()
	lines.append("%s   own %d  remote %d   sent %d  received %d   %d fps%s" % [DemoScenario.SIDES[side].title,
			own_forces.get_child_count(), manager.get_entity_count(), stats.sent, stats.received,
			Engine.get_frames_per_second(), _time_text()])
	lines.append("")
	lines.append("%s  %s" % [unit.marking, unit.name])
	lines.append("%s · %s" % [DisEnums.get_enum_name("force_id", unit.force), unit.source])
	lines.append("%.5f° N  %.5f° E   h %.0f m (WGS84)   %d m above ground   %d km/h" % [g[0], g[1], g[2],
			roundi(unit.agl), roundi(unit.speed * 3.6)])
	if show_debug:
		lines.append("")
		lines.append_array(_debug_lines(unit))
	lines.append("")
	lines.append(HELP if show_help else "F1: keys")
	if _now() < _message_until:
		lines.append("")
		lines.append(_message)
	info.text = "\n".join(lines)


func _time_text() -> String:
	if _paused:
		return "   own units PAUSED"
	return "   own units x%s" % _time_scale if _time_scale != 1.0 else ""


func _debug_lines(unit: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var node: Node3D = unit.node
	var backend := terrain.get_child(0, true) as GeoCdlodBackend
	out.append("frame %.2f ms   triangles %d   draw calls %d   terrain nodes %d" % [
			1000.0 / maxf(Engine.get_frames_per_second(), 1.0),
			Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			backend.selected.size() if backend else 0])
	var stats := network.get_statistics()
	out.append("network %s:%d   ignored %d   rejected %d   terrain %s (offset %.0f m)" % [network.multicast_group,
			network.port, stats.ignored, stats.rejected, terrain.package_path.get_file(), terrain.origin_offset])
	var p := node.global_position
	out.append("local x %.1f  y %.1f  z %.1f   heading %.1f°   largest frame jump %.2f m" % [p.x, p.y, p.z,
			fposmod(rad_to_deg(unit.heading), 360.0), _frame_jump.get(unit.key, 0.0)])
	if node is DisRemoteEntity:
		var remote := node as DisRemoteEntity
		out.append("entity %s   DR algorithm %d   last PDU %.2f s ago   ground clamp %s" % [remote.entity_id,
				remote.get_dr_algorithm(), _now() - remote.get_last_update_time(),
				"yes" if manager.is_ground_clamped(remote) else "no"])
	else:
		var entity: DisEntity = node.get_child(0)
		var mover := node as DemoUnitMover
		out.append("entity %s   DR algorithm %d   published %d PDUs   route %.1f km" % [
				entity.get_effective_entity_id(), entity.dr_algorithm, entity.get_published_count(),
				mover.distance / 1000.0])
	return out


## Largest gap per unit between where it is shown and where its speed says it could be, frame to frame
## (`delta`: wall-clock seconds; unit speeds are real-time speeds).
func _track_frame_jumps(delta: float) -> void:
	for u: Dictionary in _units:
		var p: Vector3 = u.node.global_position
		if _last_pos.has(u.key):
			var last: Array = _last_pos[u.key]
			var moved := Vector2(p.x - last[0].x, p.z - last[0].z).length()
			var excess := absf(moved - u.speed * delta)
			_frame_jump[u.key] = maxf(_frame_jump.get(u.key, 0.0), excess)
		_last_pos[u.key] = [p, u.speed]


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
	# Camera speed is real time, independent of the own units' time scale.
	var real_delta := delta / maxf(Engine.time_scale, 0.001) if Engine.time_scale > 0.0 else 1.0 / 60.0
	camera.translate(dir * _speed * (5.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0) * real_delta)


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
		match event.keycode:
			KEY_TAB:
				selected += -1 if event.shift_pressed else 1
				_frame_jump.clear()
			KEY_C:
				free_camera = not free_camera
			KEY_F1:
				show_help = not show_help
			KEY_F3:
				show_debug = not show_debug
			KEY_BRACKETLEFT:
				_set_time_scale(_time_scale / 2.0)
			KEY_BRACKETRIGHT:
				_set_time_scale(_time_scale * 2.0)
			KEY_P:
				_paused = not _paused
				_set_time_scale(_time_scale)
			KEY_PAGEUP, KEY_PAGEDOWN:
				_move_selected(1000.0 if event.keycode == KEY_PAGEUP else -1000.0)
			KEY_F9:
				if _log:
					_stop_log()
				else:
					_start_log("user://logs/dis3d_%s.csv" % Time.get_datetime_string_from_system().replace(":", "-"))
			KEY_F12:
				_screenshot()


## Own units only: remote units follow their senders' clocks (DIS has no shared pause).
func _set_time_scale(value: float) -> void:
	_time_scale = clampf(value, 0.125, 16.0)
	Engine.time_scale = 0.0 if _paused else _time_scale
	_toast("own units %s" % ("paused" if _paused else "x%s" % _time_scale))


func _move_selected(metres: float) -> void:
	if _units.is_empty():
		return
	var mover := _units[posmod(selected, _units.size())].node as DemoUnitMover
	if mover == null:
		_toast("only own units can be moved (remote units belong to their simulation)")
		return
	mover.distance = fposmod(mover.distance + metres, maxf(mover._total, 1.0))
	mover._place()
	_toast("%s moved %+.0f m along its route" % [mover.name, metres])


func _toast(text: String) -> void:
	_message = text
	_message_until = _now() + 3.0
	print(text)


func _screenshot() -> void:
	DirAccess.make_dir_recursive_absolute("user://screenshots")
	var path := "user://screenshots/dis3d_%s.png" % Time.get_datetime_string_from_system().replace(":", "-")
	get_viewport().get_texture().get_image().save_png(path)
	_toast("screenshot " + path)  # user:// path: no local folder names on screen or in recordings


## CSV of every unit every SAMPLE_INTERVAL: time, marking, source, position, height above ground, speed, heading
## and, for remote units, the age of the last PDU.
func _start_log(path: String) -> void:
	if path.begins_with("user://"):
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	_log = FileAccess.open(path, FileAccess.WRITE)
	if _log == null:
		push_error("cannot write log %s" % path)
		return
	_log_path = path
	_log.store_line("t,marking,source,x,y,z,agl,speed,heading_deg,pdu_age")
	_toast("logging to " + _log_path)


func _stop_log() -> void:
	_log.close()
	_log = null
	_toast("log saved: " + _log_path)


func _write_log() -> void:
	if _log == null:
		return
	var now := _now()
	for u: Dictionary in _units:
		var node: Node3D = u.node
		var age := now - (node as DisRemoteEntity).get_last_update_time() if node is DisRemoteEntity else 0.0
		var p := node.global_position
		_log.store_line("%.3f,%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.1f,%.3f" % [now - _started, u.marking,
				u.source.split(" ")[0], p.x, p.y, p.z, u.agl, u.speed, rad_to_deg(u.heading), age])


func _finish() -> void:
	_quit_at = 0.0
	if _log:
		_stop_log()
	var code := 0
	if _check:
		print(_check.report())
		var sorted := _frame_times.duplicate()
		sorted.sort()
		if not sorted.is_empty():
			var mean := 0.0
			for f in sorted:
				mean += f
			print("frames: %d, mean %.2f ms, 99th percentile %.2f ms, worst %.2f ms" % [sorted.size(),
					mean / sorted.size(), sorted[int(sorted.size() * 0.99)], sorted[-1]])
		var f := FileAccess.open(_check_path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(_check.to_dict(), "  "))
			print("report: ", _check_path)
		code = 1 if _check.problem_count() > 0 else 0
	get_tree().quit(code)


## Screenshots for docs: (marking or "", yaw, pitch, distance, file).
func _take_shots(warmup: float) -> void:
	await get_tree().create_timer(warmup).timeout
	var shots := [
		["T-1", 2.4, -0.3, 45.0, "tank_close"],
		["HEL-1", 0.9, -0.15, 70.0, "helicopter"],
		["R-T1", -0.8, -0.3, 50.0, "remote_tank"],
		["T-1", 2.0, -0.55, 6000.0, "exercise"],
		["CAR-1", 1.2, -0.3, 40.0, "civilian"],
		["P-1", 0.6, -0.25, 60.0, "patrol_boat"],
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
			camera.global_position = Vector3(3000, 9000, 15000)
			camera.look_at(Vector3(1500, 0, -1000))
		for i in 30:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png(_shots_dir.path_join(s[4] + ".png"))
		free_camera = false
	print("units: ", _units.map(func(u): return u.marking))
	get_tree().quit()
