@tool
## Buildings from the package's buildings.bin (OpenStreetMap / Overture footprints, see tools/buildings.py),
## extruded from the lowest ground under each footprint, with simple roofs: flat (with the roof triangulation from
## the package), hipped, gabled and pyramidal on four-corner footprints, domes and onion domes as half spheres.
## Facades get windows from a shader (3 m floors); colours come from the package (tags, else a palette).
##
## Two levels of detail per package tile (500 m): up to `max_distance` every building with its roof shape and
## windows, casting shadows; beyond it, up to `far_distance`, only buildings at least `far_min_height` tall as flat
## blocks without shadows (the skyline). Godot visibility ranges fade one into the other. Tile meshes are prepared on
## worker threads, nearest first, and added within `build_budget_ms` per frame; tiles out of range are freed.
## Buildings are also obstacles for GeoTerrain.line_of_sight / raycast / viewshed (GeoBuildingData.segment_hit).
class_name GeoBuildingLayer
extends GeoTerrainLayer

@export var max_distance := 4000.0
@export var far_distance := 12000.0
@export var far_min_height := 20.0
@export var cast_shadows := true
@export var build_budget_ms := 6.0
## How far walls reach below the lowest ground point, so slopes show no gap under a building.
@export var foundation := 2.0

## Masts and towers (much taller than wide, e.g. the 369 m Çamlıca TV tower) are drawn as bare light concrete; with
## windows they read as a dark rod from afar.
const TOWER_COLOR := Color(0.55, 0.55, 0.53, 0.0)
const WALL_SHADER := preload("res://addons/geo/layers/geo_building_wall.gdshader")
const ROOF_SHADER := preload("res://addons/geo/layers/geo_building_roof.gdshader")
## Tile meshes are prepared on this many worker threads at a time.
const MAX_TASKS := 4

var data: GeoBuildingData
## Buildings in the near (full detail) tiles currently built.
var buildings_drawn := 0
var tiles_built := 0

var _tiles := {}  # Vector3i(i, j, lod) -> MeshInstance3D (null when the tile has nothing at that level)
var _counts := {}  # Vector3i(i, j, 0) -> buildings counted in buildings_drawn
var _tasks := {}  # Vector3i -> WorkerThreadPool task preparing the arrays
var _results := {}  # Vector3i -> arrays from a finished task (filled on the worker, read on the main thread)
var _lock := Mutex.new()
var _todo: Array[Vector3i] = []  # missing tiles, nearest first, from the last scan
var _todo_cam := Vector2(INF, INF)
var _wall_mat: ShaderMaterial
var _roof_mat: ShaderMaterial


func has_data() -> bool:
	return package != null and package.meta.has("buildings")


func _rebuild() -> void:
	_wait_tasks()
	_todo.clear()
	_todo_cam = Vector2(INF, INF)
	for mi in _tiles.values():
		if mi:
			mi.queue_free()
	_tiles.clear()
	_counts.clear()
	buildings_drawn = 0
	tiles_built = 0
	data = null
	if not has_data():
		return
	data = package.buildings_data()
	if data == null:
		return
	_wall_mat = ShaderMaterial.new()
	_wall_mat.shader = WALL_SHADER
	_roof_mat = ShaderMaterial.new()
	_roof_mat.shader = ROOF_SHADER


func _range(lod: int) -> float:
	return (max_distance if lod == 0 else far_distance) + data.tile_m


func update_view(camera: Vector3) -> void:
	if data == null:
		return
	var cam := Vector2(camera.x, camera.z)
	var sync := build_budget_ms == INF
	# The scan over all tiles in range (thousands at 12 km) runs only when the camera has moved a little.
	if sync or cam.distance_to(_todo_cam) > 100.0:
		_todo_cam = cam
		_scan(cam)
	if sync:
		for key in _todo:
			if not _tasks.has(key):
				var arrays: Variant = _arrays(key) if can_draw() else null
				var m: ArrayMesh = null
				if arrays != null:
					m = ArrayMesh.new()
					for a: Array in arrays:
						m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
				_add_tile(key, m)
		_todo.clear()
		return
	var t0 := Time.get_ticks_usec()
	for key: Vector3i in _tasks.keys():
		if not WorkerThreadPool.is_task_completed(_tasks[key]):
			continue
		WorkerThreadPool.wait_for_task_completion(_tasks[key])
		_tasks.erase(key)
		_lock.lock()
		var mesh: ArrayMesh = _results.get(key)
		_results.erase(key)
		_lock.unlock()
		# build_all_around() may have built the tile meanwhile.
		if not _tiles.has(key) and data.tile_center(key.x, key.y).distance_to(cam) < _range(key.z) + data.tile_m:
			_add_tile(key, mesh)
		if (Time.get_ticks_usec() - t0) / 1000.0 > build_budget_ms:
			break
	while _tasks.size() < MAX_TASKS and not _todo.is_empty():
		var key: Vector3i = _todo.pop_front()
		if not _tasks.has(key) and not _tiles.has(key):
			_tasks[key] = WorkerThreadPool.add_task(_prepare.bind(key))


## Frees tiles out of range and lists the missing ones, nearest first (the near level before the far one).
func _scan(cam: Vector2) -> void:
	for key: Vector3i in _tiles.keys():
		if data.tile_center(key.x, key.y).distance_to(cam) > _range(key.z) + data.tile_m:
			var mi: MeshInstance3D = _tiles[key]
			if mi:
				mi.queue_free()
			if key.z == 0:
				buildings_drawn -= _counts.get(key, 0)
				_counts.erase(key)
			_tiles.erase(key)
	var todo: Array[Vector3i] = []
	var c := data.tile_of(cam.x, cam.y)
	for lod in 2:
		var reach := _range(lod)
		var r := ceili(reach / data.tile_m)
		for j in range(c.y - r, c.y + r + 1):
			for i in range(c.x - r, c.x + r + 1):
				var key := Vector3i(i, j, lod)
				if not _tiles.has(key) and data.tile_count(i, j) > 0 \
						and data.tile_center(i, j).distance_to(cam) < reach:
					todo.append(key)
	# Nearest first; the near level before the far one at equal distance.
	todo.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return data.tile_center(a.x, a.y).distance_squared_to(cam) + a.z * 1.0e6 \
				< data.tile_center(b.x, b.y).distance_squared_to(cam) + b.z * 1.0e6)
	_todo = todo


func _arrays(key: Vector3i) -> Variant:
	var list := data.tile(key.x, key.y)
	if key.z == 1:
		list = list.filter(func(b: Dictionary) -> bool: return b.height >= far_min_height)
	return tile_arrays(list, data.tile_center(key.x, key.y), foundation, key.z == 1)


func _wait_tasks() -> void:
	for id: int in _tasks.values():
		WorkerThreadPool.wait_for_task_completion(id)
	_tasks.clear()
	_results.clear()


func _exit_tree() -> void:
	_wait_tasks()


func _prepare(key: Vector3i) -> void:
	# The mesh is created here too: RenderingServer calls are thread-safe, and uploading a large tile on the main
	# thread cost up to 13 ms in the 60 km package.
	var arrays: Variant = _arrays(key) if can_draw() else null
	var mesh: ArrayMesh = null
	if arrays != null:
		mesh = ArrayMesh.new()
		for a: Array in arrays:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	_lock.lock()
	_results[key] = mesh
	_lock.unlock()


## Builds every tile around `camera` now (tests, screenshots, --check).
func build_all_around(camera: Vector3) -> void:
	var budget := build_budget_ms
	build_budget_ms = INF
	update_view(camera)
	build_budget_ms = budget


func _count(key: Vector3i) -> void:
	_counts[key] = data.tile_count(key.x, key.y)
	buildings_drawn += _counts[key]


func _add_tile(key: Vector3i, mesh: ArrayMesh) -> void:
	var center := data.tile_center(key.x, key.y)
	tiles_built += 1
	if mesh == null:
		_tiles[key] = null
		if key.z == 0 and not can_draw():
			_count(key)  # nothing drawn headless, but the count stays meaningful
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.set_surface_override_material(0, _wall_mat)
	mi.set_surface_override_material(1, _roof_mat)
	mi.position = Vector3(center.x, 0.0, center.y)
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	if key.z == 0:
		mi.visibility_range_end = max_distance
		mi.visibility_range_end_margin = max_distance * 0.1
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_count(key)
	else:
		mi.visibility_range_begin = max_distance
		mi.visibility_range_begin_margin = max_distance * 0.1
		mi.visibility_range_end = far_distance
		mi.visibility_range_end_margin = far_distance * 0.05
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_tiles[key] = mi


## True for a slender structure: at least 60 m tall and over three times as tall as the footprint is wide.
static func is_tower(b: Dictionary) -> bool:
	var size: Vector2 = b.aabb.size
	return b.height >= 60.0 and b.height > 3.0 * maxf(size.x, size.y)


## Mesh of a list of buildings relative to `center` (x, z): surface 0 walls (UV = metres along the wall, metres
## above the base; colour = facade), surface 1 roofs (colour = roof). Null if there is nothing to draw.
static func tile_mesh(list: Array, center: Vector2, foundation := 2.0, simple := false) -> ArrayMesh:
	var arrays: Variant = tile_arrays(list, center, foundation, simple)
	if arrays == null:
		return null
	var mesh := ArrayMesh.new()
	for a: Array in arrays:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	return mesh


## The surface arrays of tile_mesh (walls, roofs), or null; pure, so it runs on worker threads. `simple`: flat
## roofs only (the far level).
static func tile_arrays(list: Array, center: Vector2, foundation := 2.0, simple := false) -> Variant:
	var w := _Surface.new()
	var r := _Surface.new()
	for b: Dictionary in list:
		_add_building(b, center, foundation, w, r, simple)
	if w.verts.is_empty() and r.verts.is_empty():
		return null
	var out := []
	for s: _Surface in [w, r]:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		if s.verts.is_empty():  # keep the surface index stable: a degenerate triangle
			for k in 3:
				s.add(Vector3.ZERO, Vector3.UP, Vector2.ZERO, Color.WHITE)
		arrays[Mesh.ARRAY_VERTEX] = s.verts
		arrays[Mesh.ARRAY_NORMAL] = s.normals
		arrays[Mesh.ARRAY_TEX_UV] = s.uvs
		arrays[Mesh.ARRAY_COLOR] = s.colors
		out.append(arrays)
	return out


class _Surface:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()

	func add(v: Vector3, n: Vector3, uv: Vector2, c: Color) -> void:
		verts.append(v)
		normals.append(n)
		uvs.append(uv)
		colors.append(c)

	## Triangle facing `out` (Godot: clockwise seen from the front, i.e. the geometric normal points away).
	func tri(a: Vector3, b: Vector3, c: Vector3, out: Vector3, ua: Vector2, ub: Vector2, uc: Vector2,
			col: Color, flat := true) -> void:
		var n := (b - a).cross(c - a)
		if n.dot(out) > 0.0:
			var t := b
			b = c
			c = t
			var tu := ub
			ub = uc
			uc = tu
		var nn := out.normalized() if not flat else -(b - a).cross(c - a).normalized()
		add(a, nn, ua, col)
		add(b, nn, ub, col)
		add(c, nn, uc, col)


static func _add_building(b: Dictionary, center: Vector2, foundation: float, w: _Surface, r: _Surface,
		simple := false) -> void:
	var facade: Color = b.facade.srgb_to_linear()
	if is_tower(b):
		facade = TOWER_COLOR  # alpha 0: the wall shader draws no windows
	var roof_col: Color = b.roof_color.srgb_to_linear()
	var y0: float = b.base + b.min_height if b.min_height > 0.0 else b.base - foundation
	var shape: int = b.roof
	var rings: Array = b.rings
	var outline: PackedVector2Array = rings[0]
	var pitched := shape in [GeoBuildingData.Roof.GABLED, GeoBuildingData.Roof.HIPPED,
			GeoBuildingData.Roof.PYRAMIDAL] and outline.size() == 4 and rings.size() == 1 and not simple
	var dome := shape in [GeoBuildingData.Roof.DOME, GeoBuildingData.Roof.ONION] and not simple
	var roof_h: float = b.roof_height if (pitched or dome) else 0.0
	var y1: float = b.base + b.height - roof_h
	# Walls of every ring; u runs along the ring so windows line up around corners.
	for ring: PackedVector2Array in rings:
		var u := 0.0
		var n := ring.size()
		for k in n:
			var pa := ring[k] - center
			var pb := ring[(k + 1) % n] - center
			var len := pa.distance_to(pb)
			if len < 0.01:
				continue
			var out := Vector3(pb.y - pa.y, 0.0, -(pb.x - pa.x)).normalized()
			var a0 := Vector3(pa.x, y0, pa.y)
			var b0 := Vector3(pb.x, y0, pb.y)
			var a1 := Vector3(pa.x, y1, pa.y)
			var b1 := Vector3(pb.x, y1, pb.y)
			var v0: float = y0 - b.base
			var v1: float = y1 - b.base
			w.tri(a0, b0, b1, out, Vector2(u, v0), Vector2(u + len, v0), Vector2(u + len, v1), facade, false)
			w.tri(a0, b1, a1, out, Vector2(u, v0), Vector2(u + len, v1), Vector2(u, v1), facade, false)
			u += len
	if pitched:
		_pitched_roof(outline, center, y1, roof_h, shape, w, r, facade, roof_col, b.base)
	else:
		var verts := PackedVector2Array()
		for ring: PackedVector2Array in rings:
			verts.append_array(ring)
		var tris: PackedInt32Array = b.tris
		if tris.is_empty():
			tris = Geometry2D.triangulate_polygon(outline)
			verts = outline
		for k in range(0, tris.size(), 3):
			var p := [verts[tris[k]] - center, verts[tris[k + 1]] - center, verts[tris[k + 2]] - center]
			r.tri(Vector3(p[0].x, y1, p[0].y), Vector3(p[1].x, y1, p[1].y), Vector3(p[2].x, y1, p[2].y),
					Vector3.UP, p[0], p[1], p[2], roof_col)
		if dome:
			_dome(outline, center, y1, b.roof_height, shape == GeoBuildingData.Roof.ONION, r, roof_col)


static func _pitched_roof(c4: PackedVector2Array, center: Vector2, y: float, h: float, shape: int, w: _Surface,
		r: _Surface, facade: Color, roof_col: Color, base: float) -> void:
	var p: Array[Vector2] = []
	for v in c4:
		p.append(v - center)
	# Long sides p0-p1 and p2-p3.
	if p[0].distance_to(p[1]) < p[1].distance_to(p[2]):
		p = [p[1], p[2], p[3], p[0]]
	var mid := (p[0] + p[1] + p[2] + p[3]) * 0.25
	var top := y + h
	var m1 := (p[3] + p[0]) * 0.5  # middle of a short side
	var m2 := (p[1] + p[2]) * 0.5
	var r1: Vector2
	var r2: Vector2
	match shape:
		GeoBuildingData.Roof.PYRAMIDAL:
			r1 = mid
			r2 = mid
		GeoBuildingData.Roof.HIPPED:
			var inset := minf(p[1].distance_to(p[2]) * 0.5, m1.distance_to(m2) * 0.5)
			var d := (m2 - m1).normalized()
			r1 = m1 + d * inset
			r2 = m2 - d * inset
		_:
			r1 = m1
			r2 = m2
	var v := func(q: Vector2, yy: float) -> Vector3: return Vector3(q.x, yy, q.y)
	var faces := [[p[0], p[1], r2, r1], [p[2], p[3], r1, r2]]
	for f: Array in faces:
		var o: Vector2 = (f[0] + f[1]) * 0.5 - mid
		var out := Vector3(o.x, 0.0, o.y).normalized() + Vector3.UP
		r.tri(v.call(f[0], y), v.call(f[1], y), v.call(f[2], top), out, f[0], f[1], f[2], roof_col)
		if f[2] != f[3]:
			r.tri(v.call(f[0], y), v.call(f[2], top), v.call(f[3], top), out, f[0], f[2], f[3], roof_col)
	# Ends: sloped hips, or vertical gables (facade colour, so they read as walls).
	for e: Array in [[p[1], p[2], r2], [p[3], p[0], r1]]:
		var o: Vector2 = (e[0] + e[1]) * 0.5 - mid
		if shape == GeoBuildingData.Roof.GABLED:
			var out := Vector3(o.x, 0.0, o.y).normalized()
			w.tri(v.call(e[0], y), v.call(e[1], y), v.call(e[2], top), out, Vector2(0, y - base),
					Vector2(1, y - base), Vector2(0.5, top - base), facade, false)
		else:
			r.tri(v.call(e[0], y), v.call(e[1], y), v.call(e[2], top), Vector3(o.x, 0.0, o.y).normalized() + Vector3.UP,
					e[0], e[1], e[2], roof_col)


static func _dome(outline: PackedVector2Array, center: Vector2, y: float, h: float, onion: bool, r: _Surface,
		col: Color) -> void:
	var c := Vector2.ZERO
	var area := 0.0
	for k in outline.size():
		c += outline[k]
	c = c / outline.size() - center
	var rad := 0.0
	for v in outline:
		rad = maxf(rad, (v - center).distance_to(c))
	rad *= 0.85
	var seg := 16
	var rings := 6
	var prof := func(t: float) -> Vector2:  # (radius factor, height factor) for t in 0..1 from base to top
		if onion:
			return Vector2(sin(t * PI * 0.9) * (1.15 - 0.6 * t * t), t)
		return Vector2(cos(t * PI * 0.5), sin(t * PI * 0.5))
	for j in rings:
		var q0: Vector2 = prof.call(float(j) / rings)
		var q1: Vector2 = prof.call(float(j + 1) / rings)
		for i in seg:
			var a0 := TAU * i / seg
			var a1 := TAU * (i + 1) / seg
			var pts := []
			for q: Vector2 in [q0, q1]:
				for a in [a0, a1]:
					pts.append(Vector3(c.x + cos(a) * rad * q.x, y + h * q.y, c.y + sin(a) * rad * q.x))
			var out: Vector3 = ((pts[0] + pts[3]) * 0.5 - Vector3(c.x, y, c.y)).normalized()
			r.tri(pts[0], pts[1], pts[3], out, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, col)
			r.tri(pts[0], pts[3], pts[2], out, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, col)
