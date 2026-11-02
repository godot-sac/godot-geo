## CDLOD terrain (Continuous Distance-Dependent Level of Detail, F. Strugar 2009). The package grid is covered by an
## implicit quadtree of square nodes; a leaf spans PATCH x PATCH height cells, each level up doubles the size.
## Every frame the nodes are chosen by distance (level l is used inside lod_range0 * 2^l of the camera) and each is
## drawn with the same grid mesh; the shader geomorphs vertices towards the next level near the range's end.
## Drawn surface at the finest level: the height grid split into triangles along the NE-SW diagonal of every cell
## (the split Jolt uses for HeightMapShape3D, so collision matches the picture).
class_name GeoCdlodBackend
extends GeoTerrainBackend

## Height cells per patch edge (must be even for geomorphing).
const PATCH := 64
const SHADER := preload("res://addons/geo/cdlod/geo_cdlod.gdshader")

## Level 0 range in patch sizes; must stay above ~3.5 so neighbouring nodes differ by at most one level.
var lod_distance := 4.0
var morph_start := 0.7

var cells := 0
var levels := 0  # top level; the root covers PATCH << levels cells
var ranges: PackedFloat64Array = []
## Per level: [lo, hi] height of each node, row-major, INF for nodes outside the grid.
var _minmax: Array[PackedFloat32Array] = []
var _material: ShaderMaterial
var _mesh: ArrayMesh
var _active := {}  # node key -> MeshInstance3D
var _free: Array[MeshInstance3D] = []
var _shadow_mode := GeometryInstance3D.SHADOW_CASTING_SETTING_ON
var selected: Array[Vector3i] = []  # (level, ix, iz) of the last selection


func build(pkg: GeoTerrainPackage) -> void:
	package = pkg
	cells = pkg.samples - 1
	levels = 0
	while (PATCH << levels) < cells:
		levels += 1
	_compute_minmax()
	ranges.resize(levels + 1)
	for l in levels + 1:
		ranges[l] = lod_distance * PATCH * pkg.spacing * float(1 << l)
	ranges[levels] = INF

	var hm := pkg.heights.duplicate() as Image
	hm.generate_mipmaps()
	var col := pkg.color.duplicate() as Image
	col.generate_mipmaps()
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("height_map", ImageTexture.create_from_image(hm))
	_material.set_shader_parameter("color_map", ImageTexture.create_from_image(col))
	_material.set_shader_parameter("spacing", pkg.spacing)
	_material.set_shader_parameter("half_size", pkg.size_m * 0.5)
	_material.set_shader_parameter("cells", cells)
	_material.set_shader_parameter("max_level", levels)
	_material.set_shader_parameter("normal_max_mip", clampi(hm.get_mipmap_count() - 2, 0, 8))
	_material.set_shader_parameter("lod_range0", ranges[0])
	_material.set_shader_parameter("morph_start", morph_start)
	_material.set_shader_parameter("color_scale", pkg.spacing / pkg.color_spacing)
	_material.set_shader_parameter("color_samples", float(pkg.color_samples))
	if pkg.has_water():
		var w := pkg.water.duplicate() as Image
		w.generate_mipmaps()
		_material.set_shader_parameter("water_map", ImageTexture.create_from_image(w))
		_material.set_shader_parameter("water_scale", pkg.spacing / pkg.water_spacing)
		_material.set_shader_parameter("water_samples", float(pkg.water_samples))
	_mesh = patch_mesh(PATCH)


func set_water(enabled: bool) -> void:
	if _material:
		_material.set_shader_parameter("water_enabled", enabled and package.has_water())


func set_ground_detail(strength: float) -> void:
	if _material:
		_material.set_shader_parameter("detail_strength", strength)


func set_overlay(texture: Texture2D, rect: Rect2) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("overlay_map", texture)
	_material.set_shader_parameter("overlay_rect", Vector4(rect.position.x, rect.position.y, rect.size.x,
			rect.size.y))
	_material.set_shader_parameter("overlay_enabled", texture != null)


func set_cast_shadows(mode: GeometryInstance3D.ShadowCastingSetting) -> void:
	_shadow_mode = mode
	for mi: MeshInstance3D in _active.values():
		mi.cast_shadow = mode


func update_view(camera_local: Vector3) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("lod_camera", camera_local)
	selected = select(camera_local)
	var keep := {}
	for n in selected:
		keep[_key(n)] = n
	for key: int in _active.keys():
		if not keep.has(key):
			var mi: MeshInstance3D = _active[key]
			mi.visible = false
			_free.append(mi)
			_active.erase(key)
	for key: int in keep:
		if _active.has(key):
			continue
		var n: Vector3i = keep[key]
		var mi: MeshInstance3D
		if _free.is_empty():
			mi = MeshInstance3D.new()
			mi.mesh = _mesh
			mi.material_override = _material
			add_child(mi)
		else:
			mi = _free.pop_back()
		mi.cast_shadow = _shadow_mode
		var step := 1 << n.x
		mi.set_instance_shader_parameter("node_data",
				Vector4(n.y * PATCH * step, n.z * PATCH * step, step, n.x))
		mi.custom_aabb = node_aabb(n.x, n.y, n.z).grow(1.0)
		mi.visible = true
		_active[key] = mi


func surface_height(x: float, z: float) -> float:
	var pkg := package
	var half := pkg.size_m * 0.5
	var px := clampf((x + half) / pkg.spacing, 0.0, cells)
	var pz := clampf((z + half) / pkg.spacing, 0.0, cells)
	var c := mini(int(px), cells - 1)
	var r := mini(int(pz), cells - 1)
	var fx := px - c
	var fz := pz - r
	var n := pkg.samples
	var i := r * n + c
	var h10 := pkg.height_data[i + 1]
	var h01 := pkg.height_data[i + n]
	if fx + fz <= 1.0:  # triangle (c, r), (c+1, r), (c, r+1)
		var h00 := pkg.height_data[i]
		return h00 + (h10 - h00) * fx + (h01 - h00) * fz
	var h11 := pkg.height_data[i + n + 1]  # triangle (c+1, r), (c+1, r+1), (c, r+1)
	return h11 + (h01 - h11) * (1.0 - fx) + (h10 - h11) * (1.0 - fz)


## CDLOD node selection around `cam` (local space): list of (level, ix, iz) that tile the grid exactly once.
func select(cam: Vector3) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	_select(levels, 0, 0, cam, out)
	return out


func _select(level: int, ix: int, iz: int, cam: Vector3, out: Array[Vector3i]) -> bool:
	var box := node_aabb(level, ix, iz)
	if box.size == Vector3.ZERO:  # outside the grid: nothing to draw, counts as covered
		return true
	if not _in_range(box, cam, ranges[level]):
		return false
	if level == 0 or not _in_range(box, cam, ranges[level - 1]):
		out.append(Vector3i(level, ix, iz))
		return true
	for k in 4:
		var cx := ix * 2 + (k & 1)
		var cz := iz * 2 + (k >> 1)
		# A child beyond its own range is drawn at its level anyway: the shader morphs it fully to this level's grid.
		if not _select(level - 1, cx, cz, cam, out):
			out.append(Vector3i(level - 1, cx, cz))
	return true


static func _in_range(box: AABB, p: Vector3, r: float) -> bool:
	if is_inf(r):
		return true
	var q := p.clamp(box.position, box.end)
	return p.distance_squared_to(q) <= r * r


## Local AABB of a node clipped to the grid; zero-sized if the node lies outside it.
func node_aabb(level: int, ix: int, iz: int) -> AABB:
	var span := PATCH << level
	var c0 := ix * span
	var r0 := iz * span
	if c0 >= cells or r0 >= cells:
		return AABB()
	var per_axis := 1 << (levels - level)
	var lo := _minmax[level][(iz * per_axis + ix) * 2]
	var hi := _minmax[level][(iz * per_axis + ix) * 2 + 1]
	var a := package.grid_to_local(c0, r0)
	var b := package.grid_to_local(mini(c0 + span, cells), mini(r0 + span, cells))
	return AABB(Vector3(a.x, lo, a.y), Vector3(b.x - a.x, hi - lo, b.y - a.y))


func _compute_minmax() -> void:
	_minmax.clear()
	_minmax.resize(levels + 1)
	var n := 1 << levels
	var leaf := PackedFloat32Array()
	leaf.resize(n * n * 2)
	for i in n * n:
		leaf[i * 2] = INF
		leaf[i * 2 + 1] = -INF
	var data := package.height_data
	var ns := package.samples
	# Exact min / max per leaf, borders included (they are shared with the neighbour).
	for iz in n:
		var r0 := iz * PATCH
		if r0 >= cells:
			break
		for r in range(r0, mini(r0 + PATCH, cells) + 1):
			for ix in n:
				var c0 := ix * PATCH
				if c0 >= cells:
					break
				var lo := leaf[(iz * n + ix) * 2]
				var hi := leaf[(iz * n + ix) * 2 + 1]
				for v in data.slice(r * ns + c0, r * ns + mini(c0 + PATCH, cells) + 1):
					lo = minf(lo, v)
					hi = maxf(hi, v)
				leaf[(iz * n + ix) * 2] = lo
				leaf[(iz * n + ix) * 2 + 1] = hi
	_minmax[0] = leaf
	for l in range(1, levels + 1):
		var m := 1 << (levels - l)
		var prev := _minmax[l - 1]
		var cur := PackedFloat32Array()
		cur.resize(m * m * 2)
		for iz in m:
			for ix in m:
				var lo := INF
				var hi := -INF
				for k in 4:
					var j := ((iz * 2 + (k >> 1)) * m * 2 + ix * 2 + (k & 1)) * 2
					lo = minf(lo, prev[j])
					hi = maxf(hi, prev[j + 1])
				cur[(iz * m + ix) * 2] = lo
				cur[(iz * m + ix) * 2 + 1] = hi
		_minmax[l] = cur


static func _key(n: Vector3i) -> int:
	return (n.x << 48) | (n.z << 24) | n.y


## (cells+1)^2 vertices at integer grid positions (i, 0, j), two clockwise triangles per cell split NE-SW.
static func patch_mesh(n: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	for j in n + 1:
		for i in n + 1:
			verts.append(Vector3(i, 0, j))
	var idx := PackedInt32Array()
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			var b := a + 1
			var c := a + n + 1
			var d := c + 1
			idx.append_array([a, b, c, b, d, c])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
