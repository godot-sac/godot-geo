## --check and --bench runs of demo/city.tscn (see docs/city.md).
##   --check [--report x.json]   layers present, instances around the reference views, frame times there, lines of
##                               sight with known answers; exit code 1 on a problem.
##   --bench <x.json>            flies a fixed route over Üsküdar at 150 m and 500 m above the ground with layer
##                               streaming on and records frame times (p50 / p95 / p99).
extends RefCounted

## Route over the 10 km package (WGS84): seafront, Capitol, Bulgurlu, Çamlıca hills, back over the Bosphorus.
const ROUTE: Array[Vector2] = [Vector2(41.0268, 29.0100), Vector2(41.0209, 29.0396), Vector2(41.0214, 29.0805),
		Vector2(41.0300, 29.0700), Vector2(41.0400, 29.0450), Vector2(41.0300, 29.0150), Vector2(41.0268, 29.0100)]
const FRAME_BUDGET_MS := 16.7

var demo: Node3D
var terrain: GeoTerrain


func _init(d: Node3D) -> void:
	demo = d
	terrain = d.terrain


func _ground_point(lat: float, lon: float, up: float) -> Vector3:
	var g := terrain.geodetic_to_global(lat, lon, 0.0)
	return Vector3(g.x, terrain.height_at(g.x, g.z) + up, g.z)


func _frames(n: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var t := Time.get_ticks_usec()
	for i in n:
		await demo.get_tree().process_frame
		var now := Time.get_ticks_usec()
		out.append((now - t) / 1000.0)
		t = now
	return out


static func percentiles(ms: PackedFloat64Array) -> Dictionary:
	var s := Array(ms)
	s.sort()
	var pick := func(q: float) -> float: return snappedf(s[mini(int(q * s.size()), s.size() - 1)], 0.01)
	var slow := []  # frames over two frame budgets: index (from the start of the run) and milliseconds
	for i in ms.size():
		if ms[i] > 2.0 * FRAME_BUDGET_MS:
			slow.append([i, snappedf(ms[i], 0.1)])
	return {"p50": pick.call(0.5), "p95": pick.call(0.95), "p99": pick.call(0.99), "max": snappedf(s[-1], 0.01),
			"frames": s.size(), "slow_frames": slow}


func run_check(report_path: String) -> void:
	var problems: Array[String] = []
	var report := {"package": terrain.package_path, "layers": {}, "views": {}, "lines_of_sight": {}}
	for l in terrain.layers():
		report.layers[l.get_script().get_global_name()] = true
	for key in ["GeoBuildingLayer", "GeoTreeLayer", "GeoRoadLayer"]:
		if terrain.package.meta.has({"GeoBuildingLayer": "buildings", "GeoTreeLayer": "canopy",
				"GeoRoadLayer": "roads"}[key]) and not report.layers.has(key):
			problems.append("%s missing" % key)
	var headless := DisplayServer.get_name() == "headless"
	for i in demo.places.size():
		var p: Dictionary = demo.places[i]
		if not p.get("check", false):
			continue
		demo._go_to(i)
		for l in terrain.layers():
			if l.has_method(&"build_all_around"):
				l.build_all_around(terrain.to_package_local(demo.camera.global_position))
		await _frames(20)
		var stats := percentiles(await _frames(120))
		stats.merge(demo._layer_counts())
		report.views[p.id] = stats
		for k in ["buildings", "trees"]:
			if report.layers.has({"buildings": "GeoBuildingLayer", "trees": "GeoTreeLayer"}[k]) and stats.get(k, 0) == 0:
				problems.append("%s: no %s around the view" % [p.id, k])
		if not headless and stats.p99 > FRAME_BUDGET_MS:
			problems.append("%s: p99 frame %.1f ms > %.1f" % [p.id, stats.p99, FRAME_BUDGET_MS])
	# Lines of sight with known answers.
	# [name, eye, target, visible, obstacle ("" = any), visible with terrain only (null = not checked)]
	var cases := [
		# Above the 369 m Çamlıca tower (the eye must not be inside a building) to above Kız Kulesi.
		["tower_top_to_kiz_kulesi", _ground_point(41.01637, 29.06554, 380.0), _ground_point(41.02108, 29.00412, 35.0),
				true, "", true],
		# From 40 m above the water off the Üsküdar seafront to a street behind the first row of buildings: the slope faces the
		# sea, so only the buildings hide it.
		["ferry_to_street_behind_seafront", _ground_point(41.0268, 29.0100, 40.0), _ground_point(41.0255, 29.0190, 2.0),
				false, "building", null],  # terrain-only result depends on the grid spacing (5 m vs 10 m)
		["street_bulgurlu_to_capitol", _ground_point(41.0166, 29.0755, 1.7), _ground_point(41.02093, 29.03958, 2.0),
				false, "", null],
		["across_the_bosphorus", _ground_point(41.0300, 29.0060, 5.0), _ground_point(41.0420, 29.0220, 5.0), true, "",
				true],
	]
	for c: Array in cases:
		var t0 := Time.get_ticks_usec()
		var r := terrain.line_of_sight(c[1], c[2])
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var bare := terrain.line_of_sight(c[1], c[2], 0.0, GeoVisibility.TERRAIN)
		report.lines_of_sight[c[0]] = {"visible": r.visible, "obstacle": r.obstacle, "distance_m": snappedf(r.distance, 0.1),
				"length_m": snappedf(c[1].distance_to(c[2]), 0.1), "ms": snappedf(ms, 0.01),
				"terrain_only_visible": bare.visible}
		if r.visible != c[3] or (not c[4].is_empty() and r.obstacle != c[4]) 				or (c[5] != null and bare.visible != c[5]):
			problems.append("line of sight %s: visible %s obstacle %s, terrain only %s (expected %s %s %s)" % [c[0],
					r.visible, r.obstacle, bare.visible, c[3], c[4], c[5]])
	report.problems = problems
	var text := JSON.stringify(report, "  ")
	print(text)
	if not report_path.is_empty():
		var f := FileAccess.open(report_path, FileAccess.WRITE)
		f.store_string(text)
	demo.get_tree().quit(1 if problems.size() > 0 else 0)


func run_bench(report_path: String) -> void:
	var report := {"package": terrain.package_path, "resolution": demo.get_viewport().get_visible_rect().size,
			"runs": {}}
	for setting: Array in [[150.0, 60.0], [500.0, 120.0]]:
		var agl: float = setting[0]
		var speed: float = setting[1]
		var pts: Array[Vector3] = []
		for p in ROUTE:
			pts.append(_ground_point(p.x, p.y, 0.0))
		var ms := PackedFloat64Array()
		var layer_max := {}
		var prims := 0.0
		var draws := 0.0
		var t := Time.get_ticks_usec()
		for k in pts.size() - 1:
			var a := pts[k]
			var b := pts[k + 1]
			var flat := Vector2(b.x - a.x, b.z - a.z)
			var steps := maxi(1, int(flat.length() / (speed / 60.0)))  # path advances as at 60 fps
			for s in steps:
				var q := a.lerp(b, float(s) / steps)
				var g := terrain.height_at(q.x, q.z)
				var pos := Vector3(q.x, (g if not is_nan(g) else q.y) + agl, q.z)
				var ahead := pos + Vector3(flat.x, 0.0, flat.y).normalized() * agl * 2.5 + Vector3(0.0, -agl, 0.0)
				demo.camera.global_position = pos
				demo.camera.look_at(ahead, Vector3.UP)
				await demo.get_tree().process_frame
				var now := Time.get_ticks_usec()
				ms.append((now - t) / 1000.0)
				t = now
				for key: String in terrain.layer_ms:
					layer_max[key] = maxf(layer_max.get(key, 0.0), snappedf(terrain.layer_ms[key], 0.01))
				prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
				draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		var run := percentiles(ms)
		run.merge({"agl_m": agl, "speed_m_s": speed, "primitives_avg": int(prims / ms.size()),
				"draw_calls_avg": int(draws / ms.size()), "layer_update_max_ms": layer_max})
		run.merge(demo._layer_counts())
		report.runs["%d_m" % int(agl)] = run
	report.video_mem_mb = snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1)
	var text := JSON.stringify(report, "  ")
	print(text)
	var f := FileAccess.open(report_path, FileAccess.WRITE)
	f.store_string(text)
	demo.get_tree().quit()
