extends GutTest
## GeoTerrain as the ground of godot-dis DisEntityManager (needs tools/link_siblings.ps1; pending without it).
## godot-dis classes are created through ClassDB so this file parses without the addon.

const PACKAGE := "res://tests/data/ankara_small"


func _available() -> bool:
	if ClassDB.class_exists(&"DisEntityManager"):
		return true
	pending("godot-dis not linked (tools/link_siblings.ps1)")
	return false


func test_remote_tank_sits_on_geo_terrain() -> void:
	if not _available():
		return
	var pkg := GeoTerrainPackage.open(PACKAGE)
	# Scene origin at the package's latitude / longitude but at another height, like the demo.
	var origin: Node = ClassDB.instantiate(&"DisGeoOrigin")
	origin.call(&"set_origin_geodetic", pkg.latitude, pkg.longitude, 938.0)
	add_child_autofree(origin)
	var terrain := GeoTerrain.new()
	terrain.package_path = PACKAGE
	terrain.collision_enabled = false
	add_child_autofree(terrain)
	assert_almost_eq(terrain.origin_offset, -938.0, 1e-9)
	var manager: Node3D = ClassDB.instantiate(&"DisEntityManager")
	manager.set(&"auto_update", false)
	add_child_autofree(manager)
	manager.set(&"ground_path", manager.get_path_to(terrain))

	var points := [Vector3(300, 0, -400), Vector3(-1234.5, 0, 987.6), Vector3(1500, 0, 1500)]
	for i in points.size():
		var p: Vector3 = points[i]
		var pdu: RefCounted = ClassDB.instantiate(&"DisEntityStatePdu")
		pdu.set(&"entity_id", Vector3i(9, 9, i + 1))
		pdu.set(&"entity_type", PackedInt32Array([1, 1, 225, 1, 1, 0, 0]))
		# Sent at the tangent plane, as the 2D demo does.
		pdu.set(&"location_ecef", origin.call(&"local_to_ecef", p))
		manager.call(&"handle_entity_state", pdu, 0.0)
		var remote: Node3D = manager.call(&"get_entity", Vector3i(9, 9, i + 1))
		var ground := terrain.height_at(p.x, p.z)
		assert_almost_eq(remote.global_position.y, ground, 1e-2, "on the ground at %s" % p)
		# The ground height is what the package says, in the scene's frame.
		var g: PackedFloat64Array = origin.call(&"local_to_geodetic", remote.global_position)
		assert_almost_eq(g[2], terrain.geodetic_height(g[0], g[1]), 1e-2, "geodetic agreement at %s" % p)
