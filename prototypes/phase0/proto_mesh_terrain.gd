## Phase 0 prototype of our own terrain renderer: a grid of chunks, each drawn with one of four shared grid meshes
## (10/20/50/100 m cells) chosen by distance through visibility ranges. Heights are read from an R32F texture in
## the vertex shader; skirts hide cracks between neighbouring chunks of different LOD.
class_name ProtoMeshTerrain
extends Node3D

const CHUNKS := 16
## Cells per chunk edge for each LOD and the camera distance where the next LOD takes over.
const LOD_CELLS: Array[int] = [250, 125, 50, 25]
const LOD_END: Array[float] = [3000.0, 7000.0, 16000.0, 0.0]
const SKIRT_DEPTH := 40.0

var triangle_count_lod0 := 0


func build(heights: Image, color: Texture2D, size_m: float, spacing: float) -> void:
	var chunk_m := size_m / CHUNKS
	var half := size_m * 0.5
	var material := ShaderMaterial.new()
	material.shader = preload("res://prototypes/phase0/proto_mesh_terrain.gdshader")
	material.set_shader_parameter("height_map", ImageTexture.create_from_image(heights))
	material.set_shader_parameter("color_map", color)
	material.set_shader_parameter("half_size", half)
	material.set_shader_parameter("spacing", spacing)
	material.set_shader_parameter("samples", heights.get_width())
	material.set_shader_parameter("skirt_depth", SKIRT_DEPTH)

	var meshes: Array[ArrayMesh] = []
	for cells in LOD_CELLS:
		meshes.append(_grid_mesh(cells, chunk_m))
	triangle_count_lod0 = LOD_CELLS[0] * LOD_CELLS[0] * 2

	var samples_per_chunk := int(round(chunk_m / spacing))
	for cz in CHUNKS:
		for cx in CHUNKS:
			# Height range of this chunk, for culling (the vertex shader moves vertices, so the AABB must be explicit).
			var rect := Rect2i(cx * samples_per_chunk, cz * samples_per_chunk, samples_per_chunk + 1,
					samples_per_chunk + 1)
			var range_y := _height_range(heights, rect)
			for lod in LOD_CELLS.size():
				var mi := MeshInstance3D.new()
				mi.mesh = meshes[lod]
				mi.material_override = material
				mi.position = Vector3(-half + cx * chunk_m, 0.0, -half + cz * chunk_m)
				mi.custom_aabb = AABB(Vector3(0.0, range_y.x - SKIRT_DEPTH, 0.0),
						Vector3(chunk_m, range_y.y - range_y.x + SKIRT_DEPTH, chunk_m))
				mi.visibility_range_begin = 0.0 if lod == 0 else LOD_END[lod - 1]
				mi.visibility_range_end = LOD_END[lod]
				add_child(mi)


## Grid of cells x cells quads over [0, size] in X and Z, plus a skirt ring (UV2.x = 1) the shader pushes down.
static func _grid_mesh(cells: int, size: float) -> ArrayMesh:
	var n := cells + 1
	var verts := PackedVector3Array()
	var uv2 := PackedVector2Array()
	var indices := PackedInt32Array()
	var step := size / cells
	for z in n:
		for x in n:
			verts.append(Vector3(x * step, 0.0, z * step))
			uv2.append(Vector2.ZERO)
	for z in cells:
		for x in cells:
			var i := z * n + x
			indices.append_array([i, i + 1, i + n, i + 1, i + n + 1, i + n])
	# Skirt: walk the border clockwise, duplicate each border vertex flagged as skirt, stitch a strip.
	var border: Array[int] = []
	for x in n: border.append(x)
	for z in range(1, n): border.append(z * n + cells)
	for x in range(cells - 1, -1, -1): border.append(cells * n + x)
	for z in range(cells - 1, 0, -1): border.append(z * n)
	border.append(0)
	var base := verts.size()
	for b in border:
		verts.append(verts[b])
		uv2.append(Vector2(1.0, 0.0))
	for k in border.size() - 1:
		var a := border[k]
		var b := border[k + 1]
		var sa := base + k
		var sb := base + k + 1
		indices.append_array([a, sa, b, b, sa, sb])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _height_range(img: Image, rect: Rect2i) -> Vector2:
	var lo := INF
	var hi := -INF
	var w := img.get_width()
	var h := img.get_height()
	# Coarse scan (every 5th sample) plus a margin: enough for culling bounds.
	for y in range(rect.position.y, mini(rect.end.y, h), 5):
		for x in range(rect.position.x, mini(rect.end.x, w), 5):
			var v := img.get_pixel(x, y).r
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return Vector2(lo - 30.0, hi + 30.0)
