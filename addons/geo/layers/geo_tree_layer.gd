@tool
## Trees from the package's land cover (ESA WorldCover tree class) and canopy height (ETH Global Canopy Height)
## layers. Placement is computed here, not stored in the package, and is deterministic: every land cover sample
## that is tree cover gets `density` trees, and outside the tree class a sample with a canopy of 3 m or more (street
## and garden trees) gets one; position, species, size and tint come from a hash of the sample and the tree index.
##
## Drawing: square chunks of `chunk_size` metres, each a MultiMesh of 3D trees (own low-poly meshes, three
## species: broadleaf, umbrella pine, cypress) up to `near_distance` and a MultiMesh of camera-facing impostor cards
## up to `far_distance`; Godot's visibility ranges fade one into the other. Chunks are built nearest first, a few
## per frame (`build_budget_ms`), and freed beyond `far_distance`.
class_name GeoTreeLayer
extends GeoTerrainLayer

enum Species { BROADLEAF, PINE, CYPRESS }

## Trees per land cover sample of the tree class (a 10 m sample is 100 m²).
@export_range(0.0, 6.0, 0.5) var density := 2.0
@export var near_distance := 600.0
@export var far_distance := 3000.0
@export var chunk_size := 250.0
@export var cast_shadows := true
@export var build_budget_ms := 4.0
## Default tree height where there is no canopy height, metres.
@export var default_height := 10.0

const IMPOSTOR_SHADER := preload("res://addons/geo/layers/geo_tree_impostor.gdshader")
const TREE_SHADER := preload("res://addons/geo/layers/geo_tree.gdshader")
const SPECIES_SHARE := [0.55, 0.3, 0.15]  # broadleaf, umbrella (stone) pine, cypress
## Crown width / tree height per species.
const WIDTH := [0.62, 0.75, 0.24]

var tree_count := 0  # trees in the built chunks
var chunks_built := 0
## Share of the tree height pushed below the surface: on a surface model (DSM) the ground under a forest already
## sits near the crown tops.
var sink := 0.0

var _chunks := {}  # Vector2i -> {"nodes": MultiMeshInstance3D[], "count": trees}
var _tasks := {}  # Vector2i -> WorkerThreadPool task preparing that chunk
var _results := {}  # Vector2i -> prepared chunk (worker -> main thread)
var _lock := Mutex.new()
const MAX_TASKS := 4
static var _meshes: Array[ArrayMesh] = []
var _tree_material: ShaderMaterial
var _impostor_material: ShaderMaterial
var _impostor_mesh: QuadMesh
var _spacing := 10.0
var _lc: Image
var _canopy: Image


func has_data() -> bool:
	return package != null and (package.has_layer("landcover") or package.has_layer("canopy"))


func _rebuild() -> void:
	_wait_tasks()
	for c in _chunks.values():
		for mi: Node in c.nodes:
			mi.queue_free()
	_chunks.clear()
	tree_count = 0
	chunks_built = 0
	if package == null or not has_data():
		return
	_lc = package.layers.get("landcover")
	_canopy = package.layers.get("canopy")
	_spacing = package.layer_spacing.get("landcover", package.layer_spacing.get("canopy", 10.0))
	# On a surface model the ground under a forest sits near the crowns; the ground model removes half the canopy.
	sink = 0.45 if str(package.meta.height.get("surface", "dsm")) == "dsm" else 0.0
	if _meshes.is_empty():
		for s in Species.values():
			_meshes.append(tree_mesh(s))
	_tree_material = ShaderMaterial.new()
	_tree_material.shader = TREE_SHADER
	_impostor_material = ShaderMaterial.new()
	_impostor_material.shader = IMPOSTOR_SHADER
	_impostor_mesh = QuadMesh.new()
	_impostor_mesh.size = Vector2(1.0, 1.0)
	_impostor_mesh.center_offset = Vector3(0.0, 0.5, 0.0)


func update_view(camera: Vector3) -> void:
	if package == null or _meshes.is_empty():
		return
	var cam := Vector2(camera.x, camera.z)
	var reach := far_distance + chunk_size
	# Free far chunks.
	for key: Vector2i in _chunks.keys():
		if _chunk_center(key).distance_to(cam) > reach + chunk_size:
			for mi: Node in _chunks[key].nodes:
				mi.queue_free()
			tree_count -= _chunks[key].count
			_chunks.erase(key)
	# Build missing chunks, nearest first, within the time budget.
	var half := package.size_m * 0.5
	var lo := Vector2i(floori((cam.x - reach + half) / chunk_size), floori((cam.y - reach + half) / chunk_size))
	var hi := Vector2i(floori((cam.x + reach + half) / chunk_size), floori((cam.y + reach + half) / chunk_size))
	var n := ceili(package.size_m / chunk_size)
	var todo: Array[Vector2i] = []
	for j in range(maxi(lo.y, 0), mini(hi.y, n - 1) + 1):
		for i in range(maxi(lo.x, 0), mini(hi.x, n - 1) + 1):
			var key := Vector2i(i, j)
			if not _chunks.has(key) and _chunk_center(key).distance_to(cam) < reach:
				todo.append(key)
	todo.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _chunk_center(a).distance_squared_to(cam) < _chunk_center(b).distance_squared_to(cam))
	if build_budget_ms == INF:  # synchronous (build_all_around)
		for key in todo:
			if not _tasks.has(key):
				_add_chunk(key, prepare_chunk(key))
		return
	var t0 := Time.get_ticks_usec()
	for key: Vector2i in _tasks.keys():
		if not WorkerThreadPool.is_task_completed(_tasks[key]):
			continue
		WorkerThreadPool.wait_for_task_completion(_tasks[key])
		_tasks.erase(key)
		_lock.lock()
		var prepared: Dictionary = _results.get(key, {})
		_results.erase(key)
		_lock.unlock()
		# build_all_around() may have built the chunk meanwhile.
		if not _chunks.has(key) and _chunk_center(key).distance_to(cam) < reach + chunk_size:
			_add_chunk(key, prepared)
		if (Time.get_ticks_usec() - t0) / 1000.0 > build_budget_ms:
			break
	for key in todo:
		if _tasks.size() >= MAX_TASKS:
			break
		if not _tasks.has(key) and not _chunks.has(key):  # may have been added just above
			_tasks[key] = WorkerThreadPool.add_task(_prepare.bind(key))


func _prepare(key: Vector2i) -> void:
	var prepared := prepare_chunk(key)
	# Upload the instance buffers here as well (RenderingServer calls are thread-safe).
	if prepared.count > 0 and can_draw():
		var far := _multimesh(null, prepared.count)
		far.mesh = _impostor_mesh
		far.buffer = prepared.far
		prepared.far_mm = far
		var near := []
		for item: Array in prepared.near:
			var mm := _multimesh(_meshes[item[0]], item[2])
			mm.buffer = item[1]
			near.append(mm)
		prepared.near_mm = near
	_lock.lock()
	_results[key] = prepared
	_lock.unlock()


func _wait_tasks() -> void:
	for id: int in _tasks.values():
		WorkerThreadPool.wait_for_task_completion(id)
	_tasks.clear()
	_results.clear()


func _exit_tree() -> void:
	_wait_tasks()


## Builds every chunk around `camera` now (for tests, screenshots and --check runs).
func build_all_around(camera: Vector3) -> void:
	var budget := build_budget_ms
	build_budget_ms = INF
	update_view(camera)
	build_budget_ms = budget


func _chunk_center(key: Vector2i) -> Vector2:
	var half := package.size_m * 0.5
	return Vector2((key.x + 0.5) * chunk_size - half, (key.y + 0.5) * chunk_size - half)


## Trees of one chunk: Array of [species, position (package frame), height, yaw, tint].
func chunk_trees(key: Vector2i) -> Array:
	var out := []
	var half := package.size_m * 0.5
	var x0 := key.x * chunk_size - half
	var z0 := key.y * chunk_size - half
	var s := _spacing
	var n := (_lc if _lc else _canopy).get_width()
	var c0 := maxi(ceili((x0 + half) / s - 0.5), 0)
	var c1 := mini(ceili((x0 + chunk_size + half) / s - 0.5), n)
	var r0 := maxi(ceili((z0 + half) / s - 0.5), 0)
	var r1 := mini(ceili((z0 + chunk_size + half) / s - 0.5), n)
	for r in range(r0, r1):
		for c in range(c0, c1):
			var cls := _lc.get_pixel(c, r).r8 if _lc else 0
			var canopy := _canopy.get_pixel(c, r).r8 * 0.25 if _canopy else 0.0
			var count := 0
			if cls == 10:
				count = int(density) + (1 if rand3(c, r, 99) < density - int(density) else 0)
			elif canopy >= 3.0 and cls != 80:
				count = 1 if rand3(c, r, 98) < clampf(canopy / 10.0, 0.3, 0.8) else 0
			for i in count:
				var x := -half + (c + rand3(c, r, i * 4) - 0.5) * s
				var z := -half + (r + rand3(c, r, i * 4 + 1) - 0.5) * s
				if package.water_at(x, z) > 0.3 or package.layer_value("footprints", x, z) > 0:
					continue
				var y := ground(x, z)
				if is_nan(y):
					continue
				var u := rand3(c, r, i * 4 + 2)
				var species := Species.BROADLEAF if u < SPECIES_SHARE[0] else (
						Species.PINE if u < SPECIES_SHARE[0] + SPECIES_SHARE[1] else Species.CYPRESS)
				var h := canopy if canopy >= 3.0 else default_height
				h *= 0.7 + 0.35 * rand3(c, r, i * 4 + 3)
				if species == Species.CYPRESS:
					h *= 0.9
				out.append([species, Vector3(x, y - sink * h, z), h, rand3(r, c, i) * TAU, rand3(r, c, i + 7)])
	return out


## MultiMesh buffers of a chunk (pure; runs on worker threads): {count, near: [[species, buffer, n]...],
## far: buffer}. Buffer layout per instance: 3 x 4 transform rows, colour, (far only) custom data.
func prepare_chunk(key: Vector2i) -> Dictionary:
	var trees := chunk_trees(key)
	var out := {"count": trees.size(), "near": [], "far": PackedFloat32Array()}
	if trees.is_empty():
		return out
	var center := _chunk_center(key)
	var per_species: Array[Array] = [[], [], []]
	for t: Array in trees:
		per_species[t[0]].append(t)
	var far := PackedFloat32Array()
	far.resize(trees.size() * 20)
	var k := 0
	for s in Species.values():
		var list: Array = per_species[s]
		if list.is_empty():
			continue
		var buf := PackedFloat32Array()
		buf.resize(list.size() * 16)
		for i in list.size():
			var t: Array = list[i]
			var xf := _transform(t, center)
			var col := _tint(s, t[4])
			var row := [xf.basis.x.x, xf.basis.y.x, xf.basis.z.x, xf.origin.x, xf.basis.x.y, xf.basis.y.y,
					xf.basis.z.y, xf.origin.y, xf.basis.x.z, xf.basis.y.z, xf.basis.z.z, xf.origin.z,
					col.r, col.g, col.b, col.a]
			for q in 16:
				buf[i * 16 + q] = row[q]
				far[k * 20 + q] = row[q]
			far[k * 20 + 16] = float(s)
			k += 1
		out.near.append([s, buf, list.size()])
	out.far = far
	return out


func _add_chunk(key: Vector2i, prepared: Dictionary) -> void:
	var count: int = prepared.get("count", 0)
	var entry := {"nodes": [], "count": count}
	_chunks[key] = entry
	chunks_built += 1
	tree_count += count
	if count == 0 or not can_draw():
		return
	var center := _chunk_center(key)
	var far_mm: MultiMesh = prepared.get("far_mm")
	if far_mm == null:
		far_mm = _multimesh(null, count)
		far_mm.mesh = _impostor_mesh
		far_mm.buffer = prepared.far
	for k in prepared.near.size():
		var item: Array = prepared.near[k]
		var mm: MultiMesh = prepared.near_mm[k] if prepared.has("near_mm") else null
		if mm == null:
			mm = _multimesh(_meshes[item[0]], item[2])
			mm.buffer = item[1]
		var near := MultiMeshInstance3D.new()
		near.multimesh = mm
		near.material_override = _tree_material
		near.position = Vector3(center.x, 0.0, center.y)
		near.visibility_range_end = near_distance
		near.visibility_range_end_margin = near_distance * 0.1
		near.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		near.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(near)
		entry.nodes.append(near)
	var far := MultiMeshInstance3D.new()
	far.multimesh = far_mm
	far.material_override = _impostor_material
	far.position = Vector3(center.x, 0.0, center.y)
	far.visibility_range_begin = near_distance
	far.visibility_range_begin_margin = near_distance * 0.1
	far.visibility_range_end = far_distance
	far.visibility_range_end_margin = far_distance * 0.05
	far.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(far)
	entry.nodes.append(far)


func _multimesh(mesh: Mesh, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = mesh == null
	mm.mesh = mesh
	mm.instance_count = count
	return mm


func _transform(t: Array, center: Vector2) -> Transform3D:
	var h: float = t[2]
	var w: float = h * WIDTH[t[0]]
	var b := Basis(Vector3.UP, t[3]).scaled(Vector3(w, h, w))
	var p: Vector3 = t[1]
	return Transform3D(b, Vector3(p.x - center.x, p.y, p.z - center.y))


func _tint(species: int, u: float) -> Color:
	var base: Color = [Color(0.27, 0.36, 0.16), Color(0.22, 0.31, 0.17), Color(0.17, 0.25, 0.14)][species]
	# Instance colours reach the shader as they are, so convert the sRGB tint to linear here.
	return base.lerp(Color(0.38, 0.40, 0.19), u * 0.5).darkened(0.2 * (1.0 - u)).srgb_to_linear()


## Low-poly tree of unit height and unit crown width (scaled per instance by height and WIDTH). UV.x: 0 = trunk,
## 1 = foliage; UV.y = how much the vertex sways in the wind (vertex colour stays white: the instance tint).
static func tree_mesh(species: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match species:
		Species.BROADLEAF:
			_trunk(st, 0.05, 0.5)
			_blob(st, Vector3(0.0, 0.62, 0.0), Vector3(0.36, 0.26, 0.36), 1)
			_blob(st, Vector3(0.16, 0.72, 0.08), Vector3(0.26, 0.22, 0.26), 2)
			_blob(st, Vector3(-0.14, 0.75, -0.1), Vector3(0.24, 0.22, 0.24), 3)
		Species.PINE:
			_trunk(st, 0.035, 0.82)
			_blob(st, Vector3(0.0, 0.84, 0.0), Vector3(0.5, 0.13, 0.5), 4)
			_blob(st, Vector3(0.12, 0.9, 0.05), Vector3(0.3, 0.1, 0.3), 5)
		Species.CYPRESS:
			_trunk(st, 0.08, 0.15)
			_blob(st, Vector3(0.0, 0.55, 0.0), Vector3(0.5, 0.46, 0.5), 6)
	st.generate_normals()
	return st.commit()


static func _trunk(st: SurfaceTool, r: float, top: float) -> void:
	var sides := 6
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var p0 := Vector3(cos(a0) * r, 0.0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, 0.0, sin(a1) * r)
		var q0 := p0 * 0.6 + Vector3(0.0, top, 0.0)
		var q1 := p1 * 0.6 + Vector3(0.0, top, 0.0)
		for v: Vector3 in [p0, q1, q0, p0, p1, q1]:
			st.set_color(Color.WHITE)
			st.set_uv(Vector2(0.0, v.y / top * 0.2))
			st.add_vertex(v - Vector3(0.0, 0.05, 0.0))


## Lumpy ellipsoid (8 x 6 UV sphere with hashed bumps).
static func _blob(st: SurfaceTool, c: Vector3, r: Vector3, seed: int) -> void:
	var seg := 8
	var rings := 6
	var pts := []
	for j in rings + 1:
		var v := PI * j / rings
		var row := []
		for i in seg:
			var u := TAU * i / seg
			var bump := 1.0 + 0.18 * (rand3(i, j, seed) - 0.5) if j > 0 and j < rings else 1.0
			row.append(c + Vector3(sin(v) * cos(u) * r.x, cos(v) * r.y, sin(v) * sin(u) * r.z) * bump)
		pts.append(row)
	for j in rings:
		for i in seg:
			var a: Vector3 = pts[j][i]
			var b: Vector3 = pts[j][(i + 1) % seg]
			var d: Vector3 = pts[j + 1][i]
			var e: Vector3 = pts[j + 1][(i + 1) % seg]
			for v: Vector3 in [a, b, d, b, e, d]:
				st.set_color(Color.WHITE)
				st.set_uv(Vector2(1.0, clampf(v.y, 0.0, 1.0)))
				st.add_vertex(v)
