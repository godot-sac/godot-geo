extends GutTest
## Building collision (GeoTerrain.collision_buildings) on the Üsküdar test package: the shape matches the blocks of
## the visibility queries, physics rays and bodies hit roofs and walls, and the shape follows its target.

const PACKAGE := "res://tests/data/uskudar_small"

var pkg: GeoTerrainPackage
var bd: GeoBuildingData


func before_all() -> void:
	pkg = GeoTerrainPackage.open(PACKAGE)
	bd = pkg.buildings_data()


## A tall, roomy flat-roofed building on the ground, east of `min_x` (package frame).
func _sample_building(min_x := -1200.0) -> Dictionary:
	for j in bd.tiles_z:
		for i in bd.tiles_x:
			for b: Dictionary in bd.tile(i, j):
				var r: Rect2 = b.aabb
				var c := r.get_center()
				if b.height > 12.0 and b.roof == GeoBuildingData.Roof.FLAT and b.min_height == 0.0 \
						and r.size.x > 12.0 and r.size.y > 12.0 and c.x > min_x and absf(c.x) < 1200.0 \
						and absf(c.y) < 1200.0 and GeoBuildingData._inside(b.rings, c):
					return b
	return {}


func _terrain(target: Node3D, buildings := true) -> GeoTerrain:
	var t := GeoTerrain.new()
	t.auto_layers = false  # physics only
	t.collision_buildings = buildings
	add_child_autofree(t)
	t.add_child(target)
	t.collision_target = t.get_path_to(target)
	t.package_path = PACKAGE
	t.load_package()
	return t


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	return get_tree().root.world_3d.direct_space_state.intersect_ray(q)


func test_faces_cover_the_blocks() -> void:
	var b := _sample_building()
	assert_false(b.is_empty(), "no sample building")
	var c: Vector2 = b.aabb.get_center()
	var r := bd.collision_faces(Rect2(c - Vector2(100, 100), Vector2(200, 200)), c)
	var faces: PackedVector3Array = r.faces
	assert_gt(r.buildings, 0)
	assert_eq(faces.size() % 3, 0)
	var top := GeoBuildingData.top_of(b)
	var has_top := false
	for v in faces:
		has_top = has_top or (absf(v.y - top) < 0.001 and Vector2(v.x, v.z).length() < b.aabb.size.length())
	assert_true(has_top, "the sample building's top is in the shape")


func test_off_by_default() -> void:
	var t := GeoTerrain.new()
	t.auto_layers = false
	add_child_autofree(t)
	t.package_path = PACKAGE
	t.load_package()
	assert_false(t.collision_buildings)
	assert_eq(t.find_children("BuildingCollision", "", true, false).size(), 0)
	assert_eq(t.get_children(true).filter(func(n: Node) -> bool: return n.name == &"BuildingCollision").size(), 0)


func test_rays_hit_roof_and_wall() -> void:
	var b := _sample_building()
	var c: Vector2 = b.aabb.get_center()
	var target := Node3D.new()
	target.position = Vector3(c.x, 0, c.y)
	var t := _terrain(target)
	assert_gt(t.building_collision_count, 0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var top := GeoBuildingData.top_of(b)
	var hit := _ray(Vector3(c.x, top + 50.0, c.y), Vector3(c.x, top - 1.0, c.y))
	assert_false(hit.is_empty(), "ray down hits the roof")
	if not hit.is_empty():
		assert_almost_eq(hit.position.y, top, 0.05)
	var w: float = b.aabb.size.x * 0.5 + 20.0
	var low: float = b.base + 3.0
	hit = _ray(Vector3(c.x - w, low, c.y), Vector3(c.x + w, low, c.y))
	assert_false(hit.is_empty(), "ray along the street hits the wall")
	if not hit.is_empty():
		assert_lt(hit.position.x, c.x, "hit on the near side")
		var expected := GeoVisibility.line_of_sight(pkg, Vector3(c.x - w, low, c.y), Vector3(c.x + w, low, c.y),
				0.0, 0.001, GeoVisibility.BUILDINGS)
		assert_almost_eq(hit.position.x, expected.point.x, 0.5, "where line_of_sight says")


func test_body_stops_at_wall() -> void:
	var b := _sample_building()
	var c: Vector2 = b.aabb.get_center()
	var target := Node3D.new()
	target.position = Vector3(c.x, 0, c.y)
	var t := _terrain(target)
	var body := CharacterBody3D.new()
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 1.0
	shape.shape = sphere
	body.add_child(shape)
	var w: float = b.aabb.size.x * 0.5 + 20.0
	body.position = Vector3(c.x - w, b.base + 5.0, c.y)
	t.add_child(body)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var col := body.move_and_collide(Vector3(2.0 * w, 0, 0))
	assert_not_null(col, "the body collides")
	if col:
		assert_lt(body.position.x, c.x, "stopped before the building's centre")


func test_shape_follows_the_target() -> void:
	var b := _sample_building()
	var c: Vector2 = b.aabb.get_center()
	var target := Node3D.new()
	target.position = Vector3(c.x - 900.0, 0, c.y)  # the 600 m square around it misses the building
	var t := _terrain(target)
	await get_tree().physics_frame
	var top := GeoBuildingData.top_of(b)
	var down := func() -> Dictionary: return _ray(Vector3(c.x, top + 50.0, c.y), Vector3(c.x, top - 1.0, c.y))
	var first: Dictionary = down.call()
	assert_true(first.is_empty() or first.position.y < top - 0.5, "no roof far from the target")
	target.position = Vector3(c.x, 0, c.y)  # the worker thread rebuilds the shape
	var hit := {}
	for i in 120:
		await get_tree().process_frame
		await get_tree().physics_frame
		hit = down.call()
		if not hit.is_empty() and absf(hit.position.y - top) < 0.05:
			break
	assert_false(hit.is_empty(), "roof after the target moved")
	if not hit.is_empty():
		assert_almost_eq(hit.position.y, top, 0.05)
	t.update_collision_now()
	assert_gt(t.building_collision_count, 0)
