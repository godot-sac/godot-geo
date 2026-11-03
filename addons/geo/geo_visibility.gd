## Ray casts, line of sight and viewsheds on the surface of a GeoTerrainPackage, in package-local metres (+X east,
## +Y up, +Z south). Use the GeoTerrain methods, which take scene positions; these static functions are the engine
## behind them and are safe to call from a worker thread (they only read the package).
##
## The surface is the one GeoTerrain draws and collides with: grid samples joined into two planar triangles per cell
## by the NE-SW diagonal. Along a straight segment that surface is planar between the segment's crossings of three
## line families (x on a grid line, z on a grid line, x + z on a grid line: the diagonals), so the clearance of the
## segment above the surface is linear between consecutive crossings, and checking it at the crossings is exact.
## Earth curvature is part of the package heights (they are relative to the origin's tangent plane), so a straight
## segment is a straight line of sight. Atmospheric refraction is optional: coefficient k bends the ray towards the
## ground with radius R / k (k = 0.13 is a common optical value, 0.25 the radio "4/3 Earth").
class_name GeoVisibility
extends RefCounted

const EARTH_RADIUS := 6371000.0
## What blocks a line of sight (bit mask): the terrain surface, buildings, tree crowns.
const TERRAIN := 1
const BUILDINGS := 2
const TREES := 4
const ALL := 7


## Surface height at local x, z (clamped to the grid); identical to the CDLOD backend's surface_height.
static func surface_height(pkg: GeoTerrainPackage, x: float, z: float) -> float:
	var half := pkg.size_m * 0.5
	return _height(pkg.height_data, pkg.samples, (x + half) / pkg.spacing, (z + half) / pkg.spacing)


## Height at grid coordinates gx (columns, east), gz (rows, south).
static func _height(data: PackedFloat32Array, n: int, gx: float, gz: float) -> float:
	var cells := n - 1
	gx = clampf(gx, 0.0, cells)
	gz = clampf(gz, 0.0, cells)
	var c := mini(int(gx), cells - 1)
	var r := mini(int(gz), cells - 1)
	var fx := gx - c
	var fz := gz - r
	var i := r * n + c
	var h10 := data[i + 1]
	var h01 := data[i + n]
	if fx + fz <= 1.0:
		var h00 := data[i]
		return h00 + (h10 - h00) * fx + (h01 - h00) * fz
	var h11 := data[i + n + 1]
	return h11 + (h01 - h11) * (1.0 - fx) + (h10 - h11) * (1.0 - fz)


## Upward unit normal of the surface triangle under local x, z.
static func surface_normal(pkg: GeoTerrainPackage, x: float, z: float) -> Vector3:
	var n := pkg.samples
	var cells := n - 1
	var half := pkg.size_m * 0.5
	var gx := clampf((x + half) / pkg.spacing, 0.0, cells)
	var gz := clampf((z + half) / pkg.spacing, 0.0, cells)
	var c := mini(int(gx), cells - 1)
	var r := mini(int(gz), cells - 1)
	var i := r * n + c
	var d := pkg.height_data
	var dx: float
	var dz: float
	if (gx - c) + (gz - r) <= 1.0:
		dx = d[i + 1] - d[i]
		dz = d[i + n] - d[i]
	else:
		dx = d[i + n + 1] - d[i + n]
		dz = d[i + n + 1] - d[i + 1]
	return Vector3(-dx, pkg.spacing, -dz).normalized()


## Walks the segment a -> b over the surface. Returns:
##   blocked (bool), t_hit (first entry below the surface, 0..1, or -1), min_clearance (metres; the segment's lowest
##   height above the surface, refraction included, negative below it), t_min, partial (part of the segment lies
##   outside the package and was not tested), tested (false when no part of it lies inside).
## With `stop_at_hit` the walk ends at the first entry. A crossing counts once the clearance drops below -tolerance.
static func trace(pkg: GeoTerrainPackage, a: Vector3, b: Vector3, refraction := 0.0, stop_at_hit := false,
		tolerance := 0.0) -> Dictionary:
	var out := {"blocked": false, "t_hit": -1.0, "min_clearance": INF, "t_min": -1.0, "partial": false,
			"tested": false}
	if not (a.is_finite() and b.is_finite()):  # e.g. a height_at() of a point outside the package (NaN)
		out.partial = true
		return out
	var data := pkg.height_data
	var n := pkg.samples
	var cells := float(n - 1)
	var sp := pkg.spacing
	var half := pkg.size_m * 0.5
	var gx0 := (a.x + half) / sp
	var gz0 := (a.z + half) / sp
	var dgx := (b.x - a.x) / sp
	var dgz := (b.z - a.z) / sp
	# Clip to the grid (Liang-Barsky).
	var t0 := 0.0
	var t1 := 1.0
	for axis in 2:
		var p := gx0 if axis == 0 else gz0
		var dp := dgx if axis == 0 else dgz
		if absf(dp) < 1e-12:
			if p < 0.0 or p > cells:
				out.partial = true
				return out
			continue
		var ta := -p / dp
		var tb := (cells - p) / dp
		if ta > tb:
			var s := ta
			ta = tb
			tb = s
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
	out.partial = t0 > 1e-12 or t1 < 1.0 - 1e-12
	if t0 > t1:
		out.partial = true
		return out
	out.tested = true

	var dy := b.y - a.y
	var length := Vector2(b.x - a.x, b.z - a.z).length()
	var bend := refraction * length * length / (2.0 * EARTH_RADIUS)  # bulge at t: bend * t * (1 - t)
	# Next crossing of each line family (x, z, x + z) and the t between two of its lines.
	var dgw := dgx + dgz
	var next := PackedFloat64Array([INF, INF, INF])
	var step := PackedFloat64Array([INF, INF, INF])
	var f0 := PackedFloat64Array([gx0, gz0, gx0 + gz0])
	var df := PackedFloat64Array([dgx, dgz, dgw])
	for k in 3:
		if absf(df[k]) < 1e-12:
			continue
		var f := f0[k] + df[k] * t0
		var line := floorf(f + 1e-9) + 1.0 if df[k] > 0.0 else ceilf(f - 1e-9) - 1.0
		next[k] = (line - f0[k]) / df[k]
		step[k] = absf(1.0 / df[k])

	var t := t0
	var c_prev := INF
	var t_prev := t0
	while true:
		var c := a.y + dy * t + bend * t * (1.0 - t) - _height(data, n, gx0 + dgx * t, gz0 + dgz * t)
		if c < out.min_clearance:
			out.min_clearance = c
			out.t_min = t
		if c < -tolerance and not out.blocked:
			out.blocked = true
			# Where the clearance crosses zero (exact without refraction: it is linear here).
			if c_prev == INF:
				out.t_hit = t
			elif c_prev <= 0.0:
				out.t_hit = t_prev
			else:
				out.t_hit = t_prev + (t - t_prev) * c_prev / (c_prev - c)
			if stop_at_hit:
				break
		if t >= t1:
			break
		t_prev = t
		c_prev = c
		t = minf(minf(next[0], next[1]), minf(next[2], t1))
		if t <= t_prev:  # steps below the resolution of t (absurdly long segments): stop rather than loop forever
			out.partial = true
			break
		for k in 3:
			while next[k] <= t + 1e-12:
				next[k] += step[k]
	return out


## Line of sight between local points a and b. See GeoTerrain.line_of_sight.
static func line_of_sight(pkg: GeoTerrainPackage, a: Vector3, b: Vector3, refraction := 0.0,
		tolerance := 0.001, mask := ALL) -> Dictionary:
	if not (a.is_finite() and b.is_finite()):
		return invalid_line(a, b)
	var tr := trace(pkg, a, b, refraction, false, tolerance)
	var blocked: bool = tr.blocked and (mask & TERRAIN) != 0
	var t_hit: float = tr.t_hit if blocked else 1.0
	var obstacle := "terrain" if blocked else ""
	var out := {}
	var ob := obstacle_hit(pkg, a, b, t_hit, mask)
	if ob.hit:
		blocked = true
		t_hit = ob.t
		obstacle = ob.obstacle
		if ob.has("id"):
			out.building_id = ob.id
	var hit := a.lerp(b, t_hit) if blocked else b
	out.merge({
		"visible": not blocked,
		"point": hit,
		"distance": a.distance_to(hit),
		"clearance": tr.min_clearance if tr.tested else INF,
		"clearance_point": a.lerp(b, tr.t_min) if tr.tested else a,
		"partial": tr.partial,
		"obstacle": obstacle,
	})
	return out


## Result of line_of_sight for an end point that is NaN or infinite (often the height_at() of a point outside the
## package): not visible, nothing tested, `error` set. No engine error is pushed (callers may meet this every frame).
static func invalid_line(a: Vector3, b: Vector3) -> Dictionary:
	return {"visible": false, "point": a, "distance": NAN, "clearance": NAN, "clearance_point": a, "partial": true,
			"obstacle": "", "error": "end point is not finite: %s -> %s" % [a, b]}


## First building or tree crown on the segment a -> b before `t_max` (0..1): {hit, t, obstacle ("building" /
## "tree"), id (buildings)}. Tree crowns are solid from the ground to the canopy height of their 10 m sample (see
## GeoTerrainPackage.tree_height_at), sampled every half land cover sample along the segment.
## Only the part of the segment over the package is searched. The tree samples within one land cover sample
## (horizontally) of either end are skipped: an eye standing among trees can still look up or out of its own cell.
static func obstacle_hit(pkg: GeoTerrainPackage, a: Vector3, b: Vector3, t_max := 1.0, mask := ALL) -> Dictionary:
	var best := {"hit": false, "t": t_max}
	if not (a.is_finite() and b.is_finite()) or is_nan(t_max):
		return best
	var span := clip_to_package(pkg, a, b)
	var lo := span.x
	var hi := minf(span.y, t_max)
	if lo > hi:
		return best
	var a2 := a.lerp(b, lo)
	var b2 := a.lerp(b, hi)
	if mask & BUILDINGS:
		var bd := pkg.buildings_data()
		if bd:
			var h := bd.segment_hit(a2, b2)
			if h.hit:
				best = {"hit": true, "t": lo + h.t * (hi - lo), "obstacle": "building", "id": h.id}
	if mask & TREES and pkg.has_layer("canopy"):
		var cell: float = pkg.layer_spacing.canopy
		var length := Vector2(b.x - a.x, b.z - a.z).length()
		var t_end: float = best.t if best.hit else hi
		var n := maxi(1, ceili(length * (t_end - lo) / (cell * 0.5)))
		for s in n + 1:
			var t: float = lo + (t_end - lo) * s / n
			if length * minf(t, 1.0 - t) < cell:
				continue
			var p := a.lerp(b, t)
			var crown := pkg.tree_height_at(p.x, p.z)
			if crown > 0.0 and p.y < surface_height(pkg, p.x, p.z) + crown:
				if t < best.t or not best.hit:
					best = {"hit": true, "t": t, "obstacle": "tree"}
				break
	return best


## Parameter range [t0, t1] of segment a -> b over the package square (x / z); t0 > t1 when it misses.
static func clip_to_package(pkg: GeoTerrainPackage, a: Vector3, b: Vector3) -> Vector2:
	var half := pkg.size_m * 0.5
	var t0 := 0.0
	var t1 := 1.0
	for axis: int in [0, 2]:
		var p := a[axis]
		var d := b[axis] - a[axis]
		if absf(d) < 1e-12:
			if p < -half or p > half:
				return Vector2(1.0, 0.0)
			continue
		var ta := (-half - p) / d
		var tb := (half - p) / d
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
	return Vector2(t0, t1)


## First intersection of the ray from local `from` along `direction`. See GeoTerrain.raycast.
static func raycast(pkg: GeoTerrainPackage, from: Vector3, direction: Vector3, max_distance := 1.0e7,
		mask := ALL) -> Dictionary:
	if not (from.is_finite() and direction.is_finite()) or direction.is_zero_approx() or is_nan(max_distance):
		return {"hit": false, "position": from, "distance": INF, "normal": Vector3.UP,
				"error": "origin or direction is not finite (or zero)"}
	var dir := direction.normalized()
	# Shorten the ray to the package's square so the walk does not count lines far outside it.
	var half := pkg.size_m * 0.5
	var reach := max_distance
	for axis: int in [0, 2]:
		var d := dir[axis]
		if absf(d) > 1e-12:
			var limit := (half - from[axis]) / d if d > 0.0 else (-half - from[axis]) / d
			reach = minf(reach, maxf(limit, 0.0) + 1.0)
	# Vertically, nothing lies below the lowest ground or above the highest ground plus the tallest structure.
	if dir.y < -1e-12:
		reach = minf(reach, maxf(from.y - pkg.height_min, 0.0) / -dir.y + 1.0)
	elif dir.y > 1e-12:
		reach = minf(reach, maxf(pkg.height_max + 1000.0 - from.y, 0.0) / dir.y + 1.0)
	var to := from + dir * reach
	var tr := trace(pkg, from, to, 0.0, true, 0.0)
	var t_hit: float = tr.t_hit if tr.blocked and (mask & TERRAIN) else 1.0
	var ob := obstacle_hit(pkg, from, to, t_hit, mask)
	if ob.hit:
		var q := from.lerp(to, ob.t)
		var r := {"hit": true, "position": q, "distance": from.distance_to(q), "normal": -dir, "obstacle": ob.obstacle}
		if ob.has("id"):
			r.building_id = ob.id
		return r
	if not tr.blocked or not (mask & TERRAIN):
		return {"hit": false, "position": to, "distance": INF, "normal": Vector3.UP}
	var p := from.lerp(to, tr.t_hit)
	p.y = surface_height(pkg, p.x, p.z)
	return {"hit": true, "position": p, "distance": from.distance_to(p), "normal": surface_normal(pkg, p.x, p.z),
			"obstacle": "terrain"}


## Viewshed around local `observer` (the eye position). Returns an Image (FORMAT_LA8) of resolution x resolution
## pixels covering the square observer.xz +- radius (row 0 = north, column 0 = west): luminance 255 = a point
## `target_height` above the surface there is visible, 0 = hidden; alpha 0 outside the radius or the package.
## Algorithm: R2 ray sweep (Franklin and Ray, 1994): one ray to the centre of each border pixel, stepping at most
## one pixel and one height sample along its major axis and keeping the steepest terrain slope seen so far; a pixel
## is visible if any ray sees a point of it. Cost: about 2 * resolution^2 * max(1, pixel size / sample spacing).
static func viewshed(pkg: GeoTerrainPackage, observer: Vector3, radius: float, target_height := 0.0,
		resolution := 256, refraction := 0.0, mask := ALL) -> Image:
	if not observer.is_finite() or not is_finite(radius) or radius <= 0.0:
		return null  # a NaN eye (outside the package) would never finish the sweep
	var res := maxi(resolution, 2)
	var cell := 2.0 * radius / res
	var tops := obstacle_tops(pkg, Rect2(observer.x - radius, observer.z - radius, 2.0 * radius, 2.0 * radius), res,
			mask)
	var x0 := observer.x - radius
	var z0 := observer.z - radius
	var half := pkg.size_m * 0.5
	var data := pkg.height_data
	var n := pkg.samples
	var sp := pkg.spacing
	var curve := refraction / (2.0 * EARTH_RADIUS)
	var bytes := PackedByteArray()
	bytes.resize(res * res * 2)
	bytes.fill(0)
	# Alpha: inside the radius and the package.
	var r2 := radius * radius
	for row in res:
		var z := z0 + (row + 0.5) * cell
		for col in res:
			var x := x0 + (col + 0.5) * cell
			var dx := x - observer.x
			var dz := z - observer.z
			if dx * dx + dz * dz <= r2 and absf(x) <= half and absf(z) <= half:
				bytes[(row * res + col) * 2 + 1] = 255
	var oc := int((observer.x - x0) / cell)
	var orow := int((observer.z - z0) / cell)
	if oc >= 0 and oc < res and orow >= 0 and orow < res:
		bytes[(orow * res + oc) * 2] = 255
	var border: Array[Vector2i] = []
	for i in res:
		border.append(Vector2i(i, 0))
		border.append(Vector2i(i, res - 1))
		if i > 0 and i < res - 1:
			border.append(Vector2i(0, i))
			border.append(Vector2i(res - 1, i))
	# Steps of at most one pixel and one height sample along the major axis, so no ridge falls between two steps.
	# A pixel takes the verdict of the step closest to its centre (over all rays).
	var stride := minf(cell, sp)
	var reach := radius + 2.0 * cell  # pixels whose centre is inside the radius may be entered beyond it
	var best := PackedFloat32Array()
	best.resize(res * res)
	best.fill(INF)
	if oc >= 0 and oc < res and orow >= 0 and orow < res:
		best[orow * res + oc] = 0.0
	for bp in border:
		var tx := x0 + (bp.x + 0.5) * cell - observer.x
		var tz := z0 + (bp.y + 0.5) * cell - observer.z
		var steps := int(ceilf(maxf(absf(tx), absf(tz)) / stride))
		if steps == 0:
			continue
		var sx := tx / steps
		var sz := tz / steps
		var ds := sqrt(sx * sx + sz * sz)
		var max_slope := -INF
		for s in range(1, steps + 1):
			var d := ds * s
			if d > reach:
				break
			var x := observer.x + sx * s
			var z := observer.z + sz * s
			if absf(x) > half or absf(z) > half:
				break
			var h := _height(data, n, (x + half) / sp, (z + half) / sp) - curve * d * d - observer.y
			var fc := (x - x0) / cell
			var fr := (z - z0) / cell
			var col := floori(fc)
			var row := floori(fr)
			if not tops.is_empty() and col >= 0 and col < res and row >= 0 and row < res:
				h += tops[row * res + col]
			if col >= 0 and col < res and row >= 0 and row < res:
				var ec := fc - col - 0.5
				var er := fr - row - 0.5
				var e2 := ec * ec + er * er
				var k := row * res + col
				if e2 < best[k]:
					best[k] = e2
					bytes[k * 2] = 255 if (h + target_height) / d >= max_slope else 0
			max_slope = maxf(max_slope, h / d)
	return Image.create_from_data(res, res, false, Image.FORMAT_LA8, bytes)


## Height of buildings and tree crowns above the terrain at each pixel centre of a res x res grid over `rect`
## (package frame); empty when the mask or the package has neither. A pixel takes the tallest building whose
## footprint contains its centre (blocks' tops as in line_of_sight), else the tree crown there.
static func obstacle_tops(pkg: GeoTerrainPackage, rect: Rect2, res: int, mask := ALL) -> PackedFloat32Array:
	var bd := pkg.buildings_data() if mask & BUILDINGS else null
	var trees := (mask & TREES) != 0 and pkg.has_layer("canopy")
	if bd == null and not trees:
		return PackedFloat32Array()
	var cell := rect.size.x / res
	var tops := PackedFloat32Array()
	tops.resize(res * res)
	tops.fill(0.0)
	if trees:
		for row in res:
			for col in res:
				var x := rect.position.x + (col + 0.5) * cell
				var z := rect.position.y + (row + 0.5) * cell
				if pkg.contains(x, z):
					tops[row * res + col] = pkg.tree_height_at(x, z)
	if bd:
		for bld: Dictionary in bd.buildings_in(rect):
			var r: Rect2 = bld.aabb
			var c0 := maxi(floori((r.position.x - rect.position.x) / cell - 0.5), 0)
			var c1 := mini(ceili((r.end.x - rect.position.x) / cell - 0.5), res - 1)
			var r0 := maxi(floori((r.position.y - rect.position.y) / cell - 0.5), 0)
			var r1 := mini(ceili((r.end.y - rect.position.y) / cell - 0.5), res - 1)
			for row in range(r0, r1 + 1):
				for col in range(c0, c1 + 1):
					var p := Vector2(rect.position.x + (col + 0.5) * cell, rect.position.y + (row + 0.5) * cell)
					if r.has_point(p) and GeoBuildingData._inside(bld.rings, p):
						var top := GeoBuildingData.top_of(bld) - surface_height(pkg, p.x, p.y)
						tops[row * res + col] = maxf(tops[row * res + col], top)
	return tops


## Colours a viewshed image for GeoTerrain.set_overlay: visible and hidden pixels get the given colours (with their
## alpha), pixels outside the radius stay transparent.
static func viewshed_colors(viewshed_image: Image, visible := Color(0.1, 0.9, 0.2, 0.45),
		hidden := Color(0.9, 0.1, 0.1, 0.45)) -> Image:
	var src := viewshed_image.get_data()
	var count := viewshed_image.get_width() * viewshed_image.get_height()
	var out := PackedByteArray()
	out.resize(count * 4)
	var vis := PackedByteArray([visible.r8, visible.g8, visible.b8, visible.a8])
	var hid := PackedByteArray([hidden.r8, hidden.g8, hidden.b8, hidden.a8])
	for i in count:
		if src[i * 2 + 1] == 0:
			out[i * 4 + 3] = 0
			continue
		var c := vis if src[i * 2] > 0 else hid
		out[i * 4] = c[0]
		out[i * 4 + 1] = c[1]
		out[i * 4 + 2] = c[2]
		out[i * 4 + 3] = c[3]
	return Image.create_from_data(viewshed_image.get_width(), viewshed_image.get_height(), false,
			Image.FORMAT_RGBA8, out)
