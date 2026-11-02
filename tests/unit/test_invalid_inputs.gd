extends GutTest
## Visibility queries with end points that are NaN or infinite (typically height_at() outside the package) must
## return at once instead of walking forever.

const PACKAGE := "res://tests/data/uskudar_small"

var terrain: GeoTerrain


func before_each() -> void:
	terrain = GeoTerrain.new()
	terrain.package_path = PACKAGE
	add_child_autofree(terrain)


func test_line_of_sight_nan_end_point() -> void:
	var outside := Vector3(9000.0, terrain.height_at(9000.0, 0.0), 0.0)
	assert_true(is_nan(outside.y), "height_at outside the package is NaN")
	var t0 := Time.get_ticks_msec()
	var r := terrain.line_of_sight(Vector3(0.0, 200.0, 0.0), outside)
	assert_lt(Time.get_ticks_msec() - t0, 1000)
	assert_false(r.visible)
	assert_true(r.partial)
	assert_true(r.has("error"))
	r = terrain.line_of_sight(Vector3(NAN, 0.0, 0.0), Vector3(0.0, 100.0, 0.0), 0.0, GeoVisibility.TERRAIN)
	assert_false(r.visible)
	r = terrain.line_of_sight(Vector3(0.0, INF, 0.0), Vector3(0.0, 100.0, 10.0))
	assert_true(r.has("error"))


func test_raycast_and_viewshed_nan() -> void:
	var r := terrain.raycast(Vector3(0.0, NAN, 0.0), Vector3.DOWN)
	assert_false(r.hit)
	assert_true(r.has("error"))
	r = terrain.raycast(Vector3(0.0, 500.0, 0.0), Vector3.ZERO)
	assert_false(r.hit)
	assert_null(terrain.viewshed(Vector3(0.0, NAN, 0.0), 500.0))
	assert_null(terrain.viewshed(Vector3(0.0, 100.0, 0.0), NAN))


func test_trace_nan_returns_untested() -> void:
	var tr := GeoVisibility.trace(terrain.package, Vector3(0.0, NAN, 0.0), Vector3(10.0, 0.0, 10.0))
	assert_false(tr.tested)
	assert_true(tr.partial)


func test_free_leaves_no_orphans() -> void:
	# GeoTerrain used to queue_free its internal children on leaving the tree; they then counted as orphans.
	var t := GeoTerrain.new()
	t.package_path = PACKAGE
	add_child(t)
	var before := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	t.free()
	assert_eq(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), before)
	# Reloading frees the old backend at once as well.
	terrain.load_package()
	assert_no_new_orphans()
