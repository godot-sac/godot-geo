@tool
@icon("res://addons/geo/icons/geo_terrain.svg")
## Real-world terrain from a godot-geo package (tools/build_terrain.py): draws it, answers height queries and keeps a
## collision patch under a target. Positions are in the package frame: the local ENU plane at the package origin,
## +X east, +Y up, -Z north, the same frame as godot-dis DisGeoOrigin. Keep this node unrotated and unscaled.
##
## If the scene has a DisGeoOrigin (group "dis_geo_origin") at the same latitude / longitude but another height, the
## terrain is shifted vertically to match; a different latitude / longitude only raises a warning.
class_name GeoTerrain
extends Node3D

signal loaded

enum Backend { CDLOD }

## Layer types `auto_layers` may add, in drawing order.
const LAYER_TYPES: Array[Script] = [preload("res://addons/geo/layers/geo_building_layer.gd"),
		preload("res://addons/geo/layers/geo_road_layer.gd"), preload("res://addons/geo/layers/geo_tree_layer.gd")]

## Package directory (contains terrain.json).
@export_dir var package_path := "":
	set(value):
		package_path = value
		if is_inside_tree():
			load_package()
@export var backend := Backend.CDLOD
## Level 0 detail range in patch sizes (CDLOD); larger is sharper and slower. Minimum 3.5.
@export_range(3.5, 16.0, 0.5) var lod_distance := 4.0
@export var cast_shadows := true:
	set(value):
		cast_shadows = value
		if _backend:
			_backend.set_cast_shadows(_shadow_setting())
## Procedural detail on the ground near the camera (0 = off). Not data: it only breaks up the blur of 10 m
## imagery seen from a few metres; leave it off where the picture must show the data alone.
@export_range(0.0, 1.0, 0.05) var ground_detail := 0.0:
	set(value):
		ground_detail = value
		if _backend:
			_backend.set_ground_detail(value)
## Draw the package's water layer (sea, lakes, rivers) as a water surface. The surface is the terrain itself: the
## DEM is at water level there, so height_at() gives the water surface.
@export var water := true:
	set(value):
		water = value
		if _backend:
			_backend.set_water(value)
## Add the layers the package has data for (GeoTreeLayer, ...) unless a child of that type already exists.
@export var auto_layers := true
@export_group("Collision")
@export var collision_enabled := true
## Edge length of the square collision patch kept around the target, in metres.
@export var collision_size := 2000.0
## Node the collision patch follows; the active camera if empty.
@export var collision_target: NodePath
@export_flags_3d_physics var collision_layer := 1
@export_group("")
## Check SHA-256 of the package files on load (slow for large packages).
@export var verify_package := false

var package: GeoTerrainPackage
## Vertical shift applied to the package so its heights match the scene origin's height (see class docs).
var origin_offset := 0.0
## Empty when the scene origin matches the package origin (or there is none); otherwise why not.
var origin_warning := ""
## Milliseconds each layer's update took in the last frame (layer name -> ms), for profiling.
var layer_ms := {}

var _backend: GeoTerrainBackend
var _body: StaticBody3D
var _shape: HeightMapShape3D
var _collision_center := Vector2(INF, INF)


func _ready() -> void:
	if not package_path.is_empty() and package == null:
		load_package()


## Loads `package_path` and builds the terrain. Returns OK or an error (also pushed as an engine error).
func load_package() -> Error:
	_clear()
	if package_path.is_empty():
		return ERR_INVALID_PARAMETER
	var pkg := GeoTerrainPackage.open(package_path, verify_package)
	if not pkg.ok():
		push_error("GeoTerrain: " + pkg.error)
		return ERR_FILE_NOT_FOUND if pkg.error.begins_with("no terrain package") else ERR_INVALID_DATA
	package = pkg
	_align_to_scene_origin()
	match backend:
		_:
			var b := GeoCdlodBackend.new()
			b.lod_distance = lod_distance
			_backend = b
	_backend.name = "Backend"
	_backend.position.y = origin_offset
	add_child(_backend, false, INTERNAL_MODE_FRONT)
	_backend.build(package)
	_backend.set_cast_shadows(_shadow_setting())
	_backend.set_ground_detail(ground_detail)
	_backend.set_water(water)
	if collision_enabled and not Engine.is_editor_hint():
		_body = StaticBody3D.new()
		_body.name = "Collision"
		_body.collision_layer = collision_layer
		var cs := CollisionShape3D.new()
		_shape = HeightMapShape3D.new()
		cs.shape = _shape
		_body.add_child(cs)
		add_child(_body, false, INTERNAL_MODE_FRONT)
	_setup_layers()
	loaded.emit()
	_update(true)
	return OK


## The GeoTerrainLayer children (trees, buildings, roads).
func layers() -> Array[GeoTerrainLayer]:
	var out: Array[GeoTerrainLayer] = []
	for c in get_children():
		if c is GeoTerrainLayer:
			out.append(c)
	return out


func _setup_layers() -> void:
	if auto_layers:
		for script: Script in LAYER_TYPES:
			var have := layers().any(func(l: GeoTerrainLayer) -> bool: return l.get_script() == script)
			if have:
				continue
			var l: GeoTerrainLayer = script.new()
			l.package = package
			if l.has_data():
				l.name = script.get_global_name().trim_prefix("Geo")
				add_child(l)
			else:
				l.free()
	for l in layers():
		l.setup(self)


func is_loaded() -> bool:
	return package != null


func _clear() -> void:
	# Freed at once: a node waiting in queue_free outside the tree counts as an orphan (and leaks if the tree goes).
	# Leaving the tree does not clear anything; the internal children are freed with this node.
	for n: Node in [_backend, _body]:
		if n:
			remove_child(n)
			n.free()
	for l in layers():
		l.setup(null)
	_backend = null
	_body = null
	_shape = null
	package = null
	origin_offset = 0.0
	origin_warning = ""
	_collision_center = Vector2(INF, INF)


func _process(_delta: float) -> void:
	_update(false)


func _update(force: bool) -> void:
	if _backend == null:
		return
	var cam := _camera()
	if cam:
		_backend.update_view(_backend.to_local(cam.global_position))
		var local := to_package_local(cam.global_position)
		for l in layers():
			var t0 := Time.get_ticks_usec()
			l.update_view(local)
			layer_ms[l.name] = (Time.get_ticks_usec() - t0) / 1000.0
	if _body:
		var target := get_node_or_null(collision_target) as Node3D if not collision_target.is_empty() else cam
		if target:
			_update_collision(to_local(target.global_position), force)


func _camera() -> Camera3D:
	if Engine.is_editor_hint():
		var ei := Engine.get_singleton(&"EditorInterface")
		if ei:
			var vp: SubViewport = ei.call(&"get_editor_viewport_3d", 0)
			return vp.get_camera_3d() if vp else null
		return null
	return get_viewport().get_camera_3d() if get_viewport() else null


## Terrain surface height at global x, z (the surface drawn at full detail). NAN outside the package.
func height_at(x: float, z: float) -> float:
	if package == null:
		return NAN
	var p := to_local(Vector3(x, 0.0, z))
	if not package.contains(p.x, p.z):
		return NAN
	return global_position.y + origin_offset + _backend.surface_height(p.x, p.z)


## Road texture painted around the camera by a GeoRoadLayer (ring 0 near, 1 far; rect in the package frame).
func set_road_ring(k: int, texture: Texture2D, rect: Rect2) -> void:
	if _backend:
		_backend.set_road_ring(k, texture, rect)


## Surface height in the package frame (x, z, result relative to the package origin); NAN outside the package.
func surface_height_local(x: float, z: float) -> float:
	if package == null or not package.contains(x, z):
		return NAN
	return _backend.surface_height(x, z)


## Share of the ground around global x, z that is water (0..1, from the package's water layer); 0 without one,
## NAN outside the package. Over water height_at() is the water surface.
func water_at(x: float, z: float) -> float:
	if package == null:
		return NAN
	var p := to_local(Vector3(x, 0.0, z))
	if not package.contains(p.x, p.z):
		return NAN
	return package.water_at(p.x, p.z)


## Global position of a geodetic point (degrees, metres above the WGS84 ellipsoid) in this terrain's frame.
func geodetic_to_global(lat: float, lon: float, h: float) -> Vector3:
	var p := GeoMath.geodetic_to_local(lat, lon, h, package.latitude, package.longitude, package.origin_height)
	return to_global(p + Vector3(0.0, origin_offset, 0.0))


## [lat, lon, h] of a global position.
func global_to_geodetic(p: Vector3) -> PackedFloat64Array:
	var l := to_local(p) - Vector3(0.0, origin_offset, 0.0)
	return GeoMath.local_to_geodetic(l, package.latitude, package.longitude, package.origin_height)


## Ellipsoidal height (WGS84, metres) of the terrain surface at a latitude / longitude; NAN outside the package.
func geodetic_height(lat: float, lon: float) -> float:
	if package == null:
		return NAN
	var lat0 := package.latitude
	var lon0 := package.longitude
	var h0 := package.origin_height
	var h := h0
	# The local up axis is within a fraction of a degree of the ellipsoid normal here, so the vertical gap to the
	# surface is almost exactly the height correction; a few rounds settle it to well under a millimetre.
	for i in 8:
		var enu := GeoMath.ecef_to_enu(GeoMath.geodetic_to_ecef(lat, lon, h), lat0, lon0, h0)
		if not package.contains(enu[0], -enu[1]):
			return NAN
		var dy := _backend.surface_height(enu[0], -enu[1]) - enu[2]
		h += dy
		if absf(dy) < 1e-5:
			break
	return h


## First point where the ray from global `from` along `direction` meets the terrain surface (the drawn and
## collision surface, no physics involved). Returns {hit: bool, position: Vector3, distance: float,
## normal: Vector3}; hit is false if the ray leaves the package or max_distance first.
func raycast(from: Vector3, direction: Vector3, max_distance := 1.0e7, mask := GeoVisibility.ALL) -> Dictionary:
	if package == null:
		return {"hit": false, "position": from, "distance": INF, "normal": Vector3.UP}
	var r := GeoVisibility.raycast(package, to_package_local(from), direction, max_distance, mask)
	r.position = from_package_local(r.position)
	return r


## Line of sight between global points `a` and `b` (eye and target positions; lift points on the ground by the
## eye / antenna height). Returns:
##   visible: bool; point: first obstruction (where the line enters the terrain), or `b` when visible;
##   distance: from `a` to point; clearance: the line's lowest height above the surface in metres (negative when
##   blocked); clearance_point: where that is; partial: true if part of the line lies outside the package (that
##   part is not tested).
## `refraction` is the coefficient k of a ray bending towards the ground (0 = straight; 0.13 optical, 0.25 radio).
## Earth curvature is always included (it is part of the heights).
## `mask` (GeoVisibility.TERRAIN | BUILDINGS | TREES) picks what blocks; by default everything the package has.
## `obstacle` says what blocked ("terrain", "building", "tree"; "" when visible) and `building_id` which building.
## `clearance` is measured against the terrain surface only.
func line_of_sight(a: Vector3, b: Vector3, refraction := 0.0, mask := GeoVisibility.ALL) -> Dictionary:
	if package == null:
		return {"visible": true, "point": b, "distance": a.distance_to(b), "clearance": INF,
				"clearance_point": a, "partial": true, "obstacle": ""}
	var r := GeoVisibility.line_of_sight(package, to_package_local(a), to_package_local(b), refraction, 0.001, mask)
	r.point = from_package_local(r.point)
	r.clearance_point = from_package_local(r.clearance_point)
	return r


## Visibility of the ground around the global eye position `observer`, out to `radius` metres: which points
## `target_height` above the surface it can see. Returns an Image (FORMAT_LA8, resolution x resolution) covering
## viewshed_rect(observer, radius): luminance 255 visible, 0 hidden; alpha 0 outside the radius or the package.
## GDScript, about 2 * resolution^2 surface samples (more when pixels are larger than the package spacing). On a
## worker thread call GeoVisibility.viewshed(package, to_package_local(observer), ...) instead: node transforms may
## only be read on the main thread.
func viewshed(observer: Vector3, radius: float, target_height := 0.0, resolution := 256,
		refraction := 0.0, mask := GeoVisibility.ALL) -> Image:
	if package == null:
		return null
	return GeoVisibility.viewshed(package, to_package_local(observer), radius, target_height, resolution, refraction,
			mask)


## Global x / z rectangle (position = north-west corner, x east, y = z south) covered by viewshed().
func viewshed_rect(observer: Vector3, radius: float) -> Rect2:
	return Rect2(observer.x - radius, observer.z - radius, 2.0 * radius, 2.0 * radius)


## Draws `image` (any format; converted to RGBA8, blended by its alpha) over the terrain colour inside `rect`
## (global x / z, as viewshed_rect). For analysis results such as GeoVisibility.viewshed_colors(viewshed(...)).
func set_overlay(image: Image, rect: Rect2) -> void:
	if _backend == null:
		return
	var img := image.duplicate() as Image
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var p := to_local(Vector3(rect.position.x, 0.0, rect.position.y))
	_backend.set_overlay(ImageTexture.create_from_image(img), Rect2(p.x, p.z, rect.size.x, rect.size.y))


func clear_overlay() -> void:
	if _backend:
		_backend.set_overlay(null, Rect2())


## Global position -> package-local position (the frame of GeoVisibility and the package grid).
func to_package_local(p: Vector3) -> Vector3:
	return to_local(p) - Vector3(0.0, origin_offset, 0.0)


## Package-local position -> global position.
func from_package_local(p: Vector3) -> Vector3:
	return to_global(p + Vector3(0.0, origin_offset, 0.0))


## Lines that must be shown wherever the terrain is shown (data licences).
func attribution() -> PackedStringArray:
	return package.attribution() if package else PackedStringArray()


func _shadow_setting() -> GeometryInstance3D.ShadowCastingSetting:
	return GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _align_to_scene_origin() -> void:
	if not is_inside_tree():
		return
	var o := get_tree().get_first_node_in_group(&"dis_geo_origin")
	if o == null:
		return
	var lat: float = o.get(&"latitude")
	var lon: float = o.get(&"longitude")
	var h: float = o.get(&"height")
	# 1e-7 degrees is about 1 cm.
	if absf(lat - package.latitude) > 1e-7 or absf(lon - package.longitude) > 1e-7:
		origin_warning = ("scene origin (%.7f, %.7f) differs from the package origin (%.7f, %.7f); terrain and " +
				"DIS entities will not line up. Set DisGeoOrigin to the package origin or rebuild the package.") % [
				lat, lon, package.latitude, package.longitude]
		push_warning("GeoTerrain: " + origin_warning)
		return
	# Same tangent plane, different height along its normal: a pure vertical shift.
	origin_offset = package.origin_height - h


func _update_collision(target: Vector3, force: bool) -> void:
	var pkg := package
	var cells := pkg.samples - 1
	var center := Vector2(target.x, target.z)
	if not force and center.distance_to(_collision_center) < collision_size * 0.25:
		return
	_collision_center = center
	var half := pkg.size_m * 0.5
	var n := clampi(int(collision_size / pkg.spacing), 2, cells)
	var c0 := clampi(roundi((target.x + half) / pkg.spacing) - n / 2, 0, cells - n)
	var r0 := clampi(roundi((target.z + half) / pkg.spacing) - n / 2, 0, cells - n)
	var region := pkg.heights.get_region(Rect2i(c0, r0, n + 1, n + 1))
	# The shape is scaled uniformly by the spacing (one map cell = one unit), so heights are stored divided by it.
	_shape.update_map_data_from_image(region, 0.0, 1.0 / pkg.spacing)
	var cs := _body.get_child(0) as CollisionShape3D
	var mid := pkg.grid_to_local(c0 + n * 0.5, r0 + n * 0.5)
	cs.transform = Transform3D(Basis.from_scale(Vector3.ONE * pkg.spacing), Vector3(mid.x, origin_offset, mid.y))
