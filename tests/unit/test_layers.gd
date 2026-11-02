extends GutTest
## Package layers on the Üsküdar test package: buildings (decoding, line of sight, ray cast, viewshed), trees
## (deterministic placement), land cover and canopy rasters.

const PACKAGE := "res://tests/data/uskudar_small"

var pkg: GeoTerrainPackage
var bd: GeoBuildingData


func before_all() -> void:
	pkg = GeoTerrainPackage.open(PACKAGE, true)
	bd = pkg.buildings_data()


func _terrain() -> GeoTerrain:
	var t := GeoTerrain.new()
	t.package_path = PACKAGE
	add_child_autofree(t)
	return t


## A tall, roomy flat-roofed building away from the package edge (deterministic: the first in tile order).
func _sample_building() -> Dictionary:
	for j in bd.tiles_z:
		for i in bd.tiles_x:
			for b: Dictionary in bd.tile(i, j):
				var r: Rect2 = b.aabb
				if b.height > 12.0 and b.roof == GeoBuildingData.Roof.FLAT and b.min_height == 0.0 \
						and r.size.x > 12.0 and r.size.y > 12.0 and absf(r.get_center().x) < 1200.0 \
						and absf(r.get_center().y) < 1200.0 \
						and GeoBuildingData._inside(b.rings, r.get_center()):
					return b
	return {}


func test_layers_load() -> void:
	assert_true(pkg.ok(), pkg.error)
	for key in ["water", "landcover", "canopy", "footprints"]:
		assert_true(pkg.has_layer(key), key)
	assert_eq(pkg.meta.height.surface, "dtm-approx")
	assert_not_null(bd)
	assert_eq(bd.count, int(pkg.meta.buildings.count))


func test_all_buildings_decode() -> void:
	var n := 0
	for j in bd.tiles_z:
		for i in bd.tiles_x:
			var list := bd.tile(i, j)
			assert_eq(list.size(), bd.tile_count(i, j))
			for b: Dictionary in list:
				assert_gte(b.rings[0].size(), 3)
				assert_gt(b.height, b.min_height)
				assert_true(b.tris.size() % 3 == 0)
			n += list.size()
	assert_eq(n, bd.count)
	assert_gt(n, 3000)


func test_line_of_sight_through_a_building() -> void:
	var b := _sample_building()
	assert_false(b.is_empty(), "no sample building")
	var c: Vector2 = b.aabb.get_center()
	var w: float = b.aabb.size.x * 0.5 + 10.0
	var low: float = b.base + 3.0
	var a := Vector3(c.x - w, low, c.y)
	var e := Vector3(c.x + w, low, c.y)
	var r := GeoVisibility.line_of_sight(pkg, a, e, 0.0, 0.001, GeoVisibility.BUILDINGS)
	assert_false(r.visible)
	assert_eq(r.obstacle, "building")
	assert_true(GeoBuildingData._inside(b.rings, Vector2(r.point.x, r.point.z)) or r.distance < w, "hit point")
	# Above the block nothing blocks.
	var top := GeoBuildingData.top_of(b) + 5.0
	r = GeoVisibility.line_of_sight(pkg, Vector3(a.x, top, a.z), Vector3(e.x, top, e.z), 0.0, 0.001,
			GeoVisibility.BUILDINGS)
	assert_true(r.visible)
	# Terrain only: buildings ignored.
	r = GeoVisibility.line_of_sight(pkg, a, e, 0.0, 0.001, GeoVisibility.TERRAIN)
	assert_ne(r.obstacle, "building")


func test_raycast_hits_roof() -> void:
	var b := _sample_building()
	var c: Vector2 = b.aabb.get_center()
	var from := Vector3(c.x, b.base + b.height + 50.0, c.y)
	var r := GeoVisibility.raycast(pkg, from, Vector3.DOWN, 500.0, GeoVisibility.BUILDINGS | GeoVisibility.TERRAIN)
	assert_true(r.hit)
	assert_eq(r.obstacle, "building")
	assert_eq(r.building_id, b.id)
	assert_almost_eq(r.position.y, GeoBuildingData.top_of(b), 0.01)


func test_building_at() -> void:
	var b := _sample_building()
	var c: Vector2 = b.aabb.get_center()
	assert_eq(bd.building_at(c.x, c.y).id, b.id)
	assert_true(bd.building_at(0.0, -1450.0).is_empty() or pkg.water_at(0.0, -1450.0) < 0.5)


func test_viewshed_buildings_hide_ground() -> void:
	var b := _sample_building()
	var c: Vector2 = b.aabb.get_center()
	var eye := Vector3(c.x - b.aabb.size.x * 0.5 - 8.0, 0.0, c.y)
	eye.y = GeoVisibility.surface_height(pkg, eye.x, eye.z) + 2.0
	var bare := GeoVisibility.viewshed(pkg, eye, 300.0, 1.0, 64, 0.0, GeoVisibility.TERRAIN)
	var city := GeoVisibility.viewshed(pkg, eye, 300.0, 1.0, 64, 0.0, GeoVisibility.ALL)
	var seen_bare := 0
	var seen_city := 0
	for y in 64:
		for x in 64:
			if bare.get_pixel(x, y).a > 0.5:
				seen_bare += int(bare.get_pixel(x, y).r > 0.5)
				seen_city += int(city.get_pixel(x, y).r > 0.5)
	assert_lt(seen_city, seen_bare * 0.8, "buildings must hide part of the ground (%d vs %d)" % [seen_city, seen_bare])


func test_tree_placement_is_deterministic() -> void:
	var t := _terrain()
	var trees: GeoTreeLayer = null
	for l in t.layers():
		if l is GeoTreeLayer:
			trees = l
	assert_not_null(trees, "auto layer")
	var total := 0
	var first := []
	var n := ceili(pkg.size_m / trees.chunk_size)
	for j in n:
		for i in n:
			var list := trees.chunk_trees(Vector2i(i, j))
			total += list.size()
			if first.is_empty() and not list.is_empty():
				first = list[0]
	var again := trees.chunk_trees(Vector2i(0, 0))
	assert_eq(again, trees.chunk_trees(Vector2i(0, 0)))
	gut.p("trees: %d, first %s" % [total, first])
	assert_eq(total, TREES_TOTAL)
	assert_almost_eq((first[1] as Vector3).x, TREE0_X, 0.001)
	assert_almost_eq((first[1] as Vector3).z, TREE0_Z, 0.001)
	# No tree inside a building footprint or on water.
	for j in n:
		for i in n:
			for tr: Array in trees.chunk_trees(Vector2i(i, j)):
				var p: Vector3 = tr[1]
				assert_eq(pkg.layer_value("footprints", p.x, p.z), 0)
				assert_lt(pkg.water_at(p.x, p.z), 0.31)


func test_auto_layers() -> void:
	var t := _terrain()
	var kinds := t.layers().map(func(l: GeoTerrainLayer) -> String: return l.get_script().get_global_name())
	assert_has(kinds, "GeoBuildingLayer")
	assert_has(kinds, "GeoTreeLayer")
	var b := GeoTerrain.new()
	b.auto_layers = false
	b.package_path = PACKAGE
	add_child_autofree(b)
	assert_eq(b.layers().size(), 0)


func test_building_tile_mesh() -> void:
	var list := bd.tile(bd.tiles_x / 2, bd.tiles_z / 2)
	var mesh := GeoBuildingLayer.tile_mesh(list, bd.tile_center(bd.tiles_x / 2, bd.tiles_z / 2))
	assert_not_null(mesh)
	assert_eq(mesh.get_surface_count(), 2)
	gut.p("tile mesh: %d buildings, %d + %d vertices" % [list.size(),
			mesh.surface_get_array_len(0), mesh.surface_get_array_len(1)])
	assert_gt(mesh.surface_get_array_len(0), list.size() * 6)


# Golden values from the committed package (update with the package; printed by the test).
const TREES_TOTAL := 6468
const TREE0_X := -1495.313
const TREE0_Z := -1498.152
