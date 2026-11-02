@tool
## Buildings from the package's buildings.bin (OpenStreetMap / Overture footprints, see tools/buildings.py),
## extruded from the lowest ground under each footprint, with simple roofs: flat (with the roof triangulation from
## the package), hipped, gabled and pyramidal on four-corner footprints, domes and onion domes as half spheres.
## Facades get windows from a shader (3 m floors); colours come from the package (tags, else a palette).
##
## One mesh per package tile (500 m), built nearest first within `build_budget_ms` per frame and shown up to
## `max_distance` (Godot visibility ranges with a dither fade); tiles farther away are freed. Buildings are also
## obstacles for GeoTerrain.line_of_sight / raycast / viewshed (see GeoBuildingData.segment_hit).
class_name GeoBuildingLayer
extends GeoTerrainLayer

@export var max_distance := 4000.0
@export var cast_shadows := true
@export var build_budget_ms := 6.0
## How far walls reach below the lowest ground point, so slopes show no gap under a building.
@export var foundation := 2.0

const WALL_SHADER := preload("res://addons/geo/layers/geo_building_wall.gdshader")
const ROOF_SHADER := preload("res://addons/geo/layers/geo_building_roof.gdshader")

var data: GeoBuildingData
var buildings_drawn := 0
var tiles_built := 0

var _tiles := {}  # Vector2i -> MeshInstance3D (null for empty tiles)
var _wall_mat: ShaderMaterial
var _roof_mat: ShaderMaterial


func has_data() -> bool:
	return package != null and package.meta.has("buildings")


func _rebuild() -> void:
	for mi in _tiles.values():
		if mi:
			mi.queue_free()
	_tiles.clear()
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


func update_view(camera: Vector3) -> void:
	if data == null:
		return
	var cam := Vector2(camera.x, camera.z)
	var reach := max_distance + data.tile_m
	for key: Vector2i in _tiles.keys():
		if data.tile_center(key.x, key.y).distance_to(cam) > reach + data.tile_m:
			var mi: MeshInstance3D = _tiles[key]
			if mi:
				buildings_drawn -= mi.get_meta(&"count", 0)
				mi.queue_free()
			_tiles.erase(key)
	var todo: Array[Vector2i] = []
	var r := ceili(reach / data.tile_m)
	var c := data.tile_of(cam.x, cam.y)
	for j in range(c.y - r, c.y + r + 1):
		for i in range(c.x - r, c.x + r + 1):
			var key := Vector2i(i, j)
			if not _tiles.has(key) and data.tile_count(i, j) > 0 \
					and data.tile_center(i, j).distance_to(cam) < reach:
				todo.append(key)
	if todo.is_empty():
		return
	todo.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return data.tile_center(a.x, a.y).distance_squared_to(cam) < data.tile_center(b.x, b.y).distance_squared_to(cam))
	var t0 := Time.get_ticks_usec()
	for key in todo:
		_build_tile(key)
		if (Time.get_ticks_usec() - t0) / 1000.0 > build_budget_ms:
			break


## Builds every tile around `camera` now (tests, screenshots, --check).
func build_all_around(camera: Vector3) -> void:
	var budget := build_budget_ms
	build_budget_ms = INF
	update_view(camera)
	build_budget_ms = budget


func _build_tile(key: Vector2i) -> void:
	var list := data.tile(key.x, key.y)
	var center := data.tile_center(key.x, key.y)
	var mesh := tile_mesh(list, center, foundation)
	tiles_built += 1
	if mesh == null:
		_tiles[key] = null
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.set_surface_override_material(0, _wall_mat)
	mi.set_surface_override_material(1, _roof_mat)
	mi.position = Vector3(center.x, 0.0, center.y)
	mi.visibility_range_end = max_distance
	mi.visibility_range_end_margin = max_distance * 0.1
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_meta(&"count", list.size())
	add_child(mi)
	_tiles[key] = mi
	buildings_drawn += list.size()


## Mesh of a list of buildings relative to `center` (x, z): surface 0 walls (UV = metres along the wall, metres
## above the base; colour = facade), surface 1 roofs (colour = roof). Null if there is nothing to draw.
static func tile_mesh(list: Array, center: Vector2, foundation := 2.0) -> ArrayMesh:
	var w := _Surface.new()
	var r := _Surface.new()
	for b: Dictionary in list:
		_add_building(b, center, foundation, w, r)
	if w.verts.is_empty() and r.verts.is_empty():
		return null
	var mesh := ArrayMesh.new()
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
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


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


static func _add_building(b: Dictionary, center: Vector2, foundation: float, w: _Surface, r: _Surface) -> void:
	var facade: Color = b.facade.srgb_to_linear()
	var roof_col: Color = b.roof_color.srgb_to_linear()
	var y0: float = b.base + b.min_height if b.min_height > 0.0 else b.base - foundation
	var shape: int = b.roof
	var rings: Array = b.rings
	var outline: PackedVector2Array = rings[0]
	var pitched := shape in [GeoBuildingData.Roof.GABLED, GeoBuildingData.Roof.HIPPED,
			GeoBuildingData.Roof.PYRAMIDAL] and outline.size() == 4 and rings.size() == 1
	var dome := shape in [GeoBuildingData.Roof.DOME, GeoBuildingData.Roof.ONION]
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
