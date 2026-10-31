extends GutTest
## CDLOD node selection: the chosen nodes tile the grid exactly once and neighbours differ by at most one level
## (the condition for crack-free geomorphing).

var backend: GeoCdlodBackend


## Synthetic package: 2000 x 2000 cells at 10 m (not a power of two, like real packages), gentle slope.
func before_all() -> void:
	var n := 2001
	var img := Image.create_empty(n, n, false, Image.FORMAT_RF)
	img.fill(Color(500.0, 0, 0))
	var p := GeoTerrainPackage.new()
	p.heights = img
	p.height_data = img.get_data().to_float32_array()
	p.color = Image.create_empty(4, 4, false, Image.FORMAT_RGB8)
	p.samples = n
	p.spacing = 10.0
	p.size_m = 20000.0
	p.color_samples = 4
	p.color_spacing = 20000.0 / 3.0
	backend = GeoCdlodBackend.new()
	backend.build(p)


func after_all() -> void:
	backend.free()


func test_levels_cover_grid() -> void:
	assert_eq(backend.cells, 2000)
	assert_eq(backend.levels, 5, "64 << 5 = 2048 >= 2000")


func _check(cam: Vector3) -> void:
	var sel := backend.select(cam)
	assert_gt(sel.size(), 0)
	var leaves := 1 << backend.levels
	var leaf_cells := backend.cells / GeoCdlodBackend.PATCH + 1  # leaves that hold grid cells per axis
	var owner := PackedInt32Array()
	owner.resize(leaves * leaves)
	owner.fill(-1)
	var lvl := PackedInt32Array()
	lvl.resize(leaves * leaves)
	for i in sel.size():
		var n := sel[i]
		var span := 1 << n.x
		for dz in span:
			for dx in span:
				var lx := n.y * span + dx
				var lz := n.z * span + dz
				assert_eq(owner[lz * leaves + lx], -1, "leaf %d,%d drawn twice (cam %s)" % [lx, lz, cam])
				owner[lz * leaves + lx] = i
				lvl[lz * leaves + lx] = n.x
	var level_jump := 0
	for lz in leaf_cells:
		for lx in leaf_cells:
			if lx * GeoCdlodBackend.PATCH >= backend.cells or lz * GeoCdlodBackend.PATCH >= backend.cells:
				continue
			assert_ne(owner[lz * leaves + lx], -1, "leaf %d,%d not drawn (cam %s)" % [lx, lz, cam])
			for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var ox := lx + d.x
				var oz := lz + d.y
				if ox * GeoCdlodBackend.PATCH >= backend.cells or oz * GeoCdlodBackend.PATCH >= backend.cells:
					continue
				level_jump = maxi(level_jump, absi(lvl[lz * leaves + lx] - lvl[oz * leaves + ox]))
	assert_lte(level_jump, 1, "neighbour level difference (cam %s)" % cam)


func test_selection_near_ground() -> void:
	_check(Vector3(0, 520, 0))
	_check(Vector3(-9990, 505, 9990))
	_check(Vector3(3333, 600, -7777))


func test_selection_high_and_outside() -> void:
	_check(Vector3(0, 8000, 0))
	_check(Vector3(30000, 2000, 30000))
	_check(Vector3(0, 100000, 0))


func test_finest_level_at_camera() -> void:
	var sel := backend.select(Vector3(1234, 510, -4321))
	var finest := 99
	for n in sel:
		finest = mini(finest, n.x)
	assert_eq(finest, 0)
