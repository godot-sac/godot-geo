extends GutTest
## Smoke tests for the Phase 0 prototype mesh (kept until the real GeoTerrain replaces it).


func test_grid_mesh_has_grid_and_skirt_vertices() -> void:
	var cells := 4
	var mesh := ProtoMeshTerrain._grid_mesh(cells, 100.0)
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var border := 4 * cells + 1  # closed ring
	assert_eq(verts.size(), (cells + 1) * (cells + 1) + border)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	assert_eq(indices.size(), cells * cells * 6 + (border - 1) * 6)


func test_grid_mesh_spans_chunk() -> void:
	var mesh := ProtoMeshTerrain._grid_mesh(5, 250.0)
	var aabb := mesh.get_aabb()
	assert_almost_eq(aabb.size.x, 250.0, 1e-4)
	assert_almost_eq(aabb.size.z, 250.0, 1e-4)


func test_height_range_covers_samples() -> void:
	var img := Image.create(11, 11, false, Image.FORMAT_RF)
	img.fill(Color(100.0, 0, 0))
	img.set_pixel(5, 5, Color(250.0, 0, 0))
	var r := ProtoMeshTerrain._height_range(img, Rect2i(0, 0, 11, 11))
	assert_lt(r.x, 100.0)
	assert_gt(r.y, 250.0)
