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
		for k in 3:
			while next[k] <= t + 1e-12:
				next[k] += step[k]
	return out


## Line of sight between local points a and b. See GeoTerrain.line_of_sight.
static func line_of_sight(pkg: GeoTerrainPackage, a: Vector3, b: Vector3, refraction := 0.0,
		tolerance := 0.001) -> Dictionary:
	var tr := trace(pkg, a, b, refraction, false, tolerance)
	var blocked: bool = tr.blocked
	var hit := a.lerp(b, tr.t_hit) if blocked else b
	return {
		"visible": not blocked,
		"point": hit,
		"distance": a.distance_to(hit),
		"clearance": tr.min_clearance if tr.tested else INF,
		"clearance_point": a.lerp(b, tr.t_min) if tr.tested else a,
		"partial": tr.partial,
	}


## First intersection of the ray from local `from` along `direction`. See GeoTerrain.raycast.
static func raycast(pkg: GeoTerrainPackage, from: Vector3, direction: Vector3, max_distance := 1.0e7) -> Dictionary:
	var dir := direction.normalized()
	# Shorten the ray to the package's square so the walk does not count lines far outside it.
	var half := pkg.size_m * 0.5
	var reach := max_distance
	for axis: int in [0, 2]:
		var d := dir[axis]
		if absf(d) > 1e-12:
			var limit := (half - from[axis]) / d if d > 0.0 else (-half - from[axis]) / d
			reach = minf(reach, maxf(limit, 0.0) + 1.0)
	var to := from + dir * reach
	var tr := trace(pkg, from, to, 0.0, true, 0.0)
	if not tr.blocked:
		return {"hit": false, "position": to, "distance": INF, "normal": Vector3.UP}
	var p := from.lerp(to, tr.t_hit)
	p.y = surface_height(pkg, p.x, p.z)
	return {"hit": true, "position": p, "distance": from.distance_to(p), "normal": surface_normal(pkg, p.x, p.z)}


## Viewshed around local `observer` (the eye position). Returns an Image (FORMAT_LA8) of resolution x resolution
## pixels covering the square observer.xz +- radius (row 0 = north, column 0 = west): luminance 255 = a point
## `target_height` above the surface there is visible, 0 = hidden; alpha 0 outside the radius or the package.
## Algorithm: R2 ray sweep (Franklin and Ray, 1994): one ray to the centre of each border pixel, stepping at most
## one pixel and one height sample along its major axis and keeping the steepest terrain slope seen so far; a pixel
## is visible if any ray sees a point of it. Cost: about 2 * resolution^2 * max(1, pixel size / sample spacing).
static func viewshed(pkg: GeoTerrainPackage, observer: Vector3, radius: float, target_height := 0.0,
		resolution := 256, refraction := 0.0) -> Image:
	var res := maxi(resolution, 2)
	var cell := 2.0 * radius / res
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
