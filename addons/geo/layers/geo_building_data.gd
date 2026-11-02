## The buildings of a package (buildings.bin, written by tools/buildings.py): tiles decoded on first use and kept,
## plus a 25 m grid per tile for ray queries. Positions are in the package frame (x east, z south, y up).
## Thread-safe: tiles are decoded under a lock, and a decoded tile is never changed.
class_name GeoBuildingData
extends RefCounted

const CELL := 25.0
enum Roof { FLAT, GABLED, HIPPED, PYRAMIDAL, DOME, ONION }

var path := ""
var error := ""
var tile_m := 500.0
var tiles_x := 0
var tiles_z := 0
var count := 0
var half := 0.0
var _file: FileAccess
var _index := PackedInt64Array()  # per tile: offset, zlib size, raw size, count
var _tiles := {}  # tile index -> [Array of buildings, {Vector2i cell: PackedInt32Array of building indices}]
var _lock := Mutex.new()


static func open(file: String, size_m: float) -> GeoBuildingData:
	var d := GeoBuildingData.new()
	d.path = file
	d.half = size_m * 0.5
	d.error = d._open()
	return d


func ok() -> bool:
	return error.is_empty()


func _open() -> String:
	_file = FileAccess.open(path, FileAccess.READ)
	if _file == null:
		return "%s: cannot open" % path
	var head := _file.get_buffer(20)
	if head.size() < 20 or head.slice(0, 4).get_string_from_ascii() != "GGBL":
		return "%s: not a godot-geo buildings file" % path
	if head.decode_u16(4) != 1:
		return "%s: version %d not supported" % [path, head.decode_u16(4)]
	tile_m = head.decode_float(8)
	tiles_x = head.decode_u16(12)
	tiles_z = head.decode_u16(14)
	count = head.decode_u32(16)
	var idx := _file.get_buffer(16 * tiles_x * tiles_z)
	_index.resize(4 * tiles_x * tiles_z)
	for i in tiles_x * tiles_z:
		for k in 4:
			_index[i * 4 + k] = idx.decode_u32(i * 16 + k * 4)
	return ""


func tile_count(i: int, j: int) -> int:
	if i < 0 or j < 0 or i >= tiles_x or j >= tiles_z:
		return 0
	return _index[(j * tiles_x + i) * 4 + 3]


func tile_center(i: int, j: int) -> Vector2:
	return Vector2(-half + (i + 0.5) * tile_m, -half + (j + 0.5) * tile_m)


func tile_of(x: float, z: float) -> Vector2i:
	return Vector2i(floori((x + half) / tile_m), floori((z + half) / tile_m))


## Buildings of tile (i, j): each a Dictionary with id, flags, roof (Roof), facade / roof_color (Color, sRGB),
## base, min_height, height, roof_height, rings (Array of PackedVector2Array, package-frame x / z; ring 0 is the
## outline, positive signed area), tris (PackedInt32Array into the rings' vertices in order), aabb (Rect2).
func tile(i: int, j: int) -> Array:
	return _entry(i, j)[0]


## [buildings, grid] of a tile, decoded on first use.
func _entry(i: int, j: int) -> Array:
	var key := j * tiles_x + i
	_lock.lock()
	var e: Array = _tiles.get(key, [])
	if e.is_empty():
		var out := []
		if tile_count(i, j) > 0:
			var o := key * 4
			_file.seek(_index[o])
			var raw := _file.get_buffer(_index[o + 1]).decompress(_index[o + 2], FileAccess.COMPRESSION_DEFLATE)
			out = _decode(raw, tile_center(i, j))
		e = [out, _grid_of(out)]
		_tiles[key] = e
	_lock.unlock()
	return e


func _decode(b: PackedByteArray, center: Vector2) -> Array:
	var out := []
	var p := 0
	var q := 0.05
	while p < b.size():
		var d := {}
		d.id = b.decode_u32(p)
		d.flags = b[p + 4]
		d.roof = b[p + 5]
		d.facade = Color8(b[p + 6], b[p + 7], b[p + 8])
		d.roof_color = Color8(b[p + 9], b[p + 10], b[p + 11])
		d.base = b.decode_float(p + 12)
		d.min_height = b.decode_float(p + 16)
		d.height = b.decode_float(p + 20)
		d.roof_height = b.decode_float(p + 24)
		p += 28
		var nr := b.decode_u16(p)
		p += 2
		var rings := []
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for r in nr:
			var n := b.decode_u16(p)
			p += 2
			var ring := PackedVector2Array()
			ring.resize(n)
			for k in n:
				var v := Vector2(b.decode_s16(p) * q, b.decode_s16(p + 2) * q) + center
				ring[k] = v
				lo = lo.min(v)
				hi = hi.max(v)
				p += 4
			rings.append(ring)
		d.rings = rings
		d.aabb = Rect2(lo, hi - lo)
		var nt := b.decode_u16(p)
		p += 2
		var tris := PackedInt32Array()
		tris.resize(nt * 3)
		for k in nt * 3:
			tris[k] = b.decode_u16(p + k * 2)
		p += nt * 6
		d.tris = tris
		out.append(d)
	return out


func _grid_of(list: Array) -> Dictionary:
	var grid := {}
	for k in list.size():
		var r: Rect2 = list[k].aabb
		for cz in range(floori(r.position.y / CELL), floori(r.end.y / CELL) + 1):
			for cx in range(floori(r.position.x / CELL), floori(r.end.x / CELL) + 1):
				var c := Vector2i(cx, cz)
				if not grid.has(c):
					grid[c] = PackedInt32Array()
				grid[c].append(k)
	return grid


## Height of the top of the building's block above which a ray passes freely: the walls plus half the roof (the
## roof shapes are not modelled in queries).
static func top_of(b: Dictionary) -> float:
	return b.base + b.height - b.roof_height * 0.5


static func bottom_of(b: Dictionary) -> float:
	return b.base + b.min_height if b.min_height > 0.0 else -INF


## First hit of segment a -> b (package frame) with a building block: {hit, t (0..1 along the segment), id,
## position}, or {hit: false}. `t_max` stops the search early (e.g. at a terrain hit).
func segment_hit(a: Vector3, b: Vector3, t_max := 1.0) -> Dictionary:
	var best_t := t_max
	var best := {}
	var d2 := Vector2(b.x - a.x, b.z - a.z)
	var length := d2.length()
	var steps := maxi(1, ceili(length / (CELL * 0.5)))
	var seen := {}
	for s in steps + 1:
		var t := float(s) / steps
		if t > best_t + CELL / maxf(length, 1e-6):
			break
		var p := Vector2(a.x, a.z) + d2 * t
		var ti := tile_of(p.x, p.y)
		var cell := Vector2i(floori(p.x / CELL), floori(p.y / CELL))
		# A building is filed under the tile of its centroid but may reach into neighbouring tiles.
		for tj in range(ti.y - 1, ti.y + 2):
			for tii in range(ti.x - 1, ti.x + 2):
				if tile_count(tii, tj) == 0:
					continue
				var key := tj * tiles_x + tii
				var e := _entry(tii, tj)
				var list: Array = e[0]
				var grid: Dictionary = e[1]
				for dz in range(-1, 2):
					for dx in range(-1, 2):
						for k: int in grid.get(cell + Vector2i(dx, dz), PackedInt32Array()):
							var tag := key * 1000000 + k
							if seen.has(tag):
								continue
							seen[tag] = true
							var hit := _segment_block(a, b, list[k], best_t)
							if hit >= 0.0 and hit < best_t:
								best_t = hit
								best = list[k]
	if best.is_empty():
		return {"hit": false}
	return {"hit": true, "t": best_t, "id": best.id, "position": a.lerp(b, best_t)}


## Smallest t in [0, t_max) where the segment is inside the building's block (footprint x [bottom, top]); -1 if none.
static func _segment_block(a: Vector3, b: Vector3, bld: Dictionary, t_max: float) -> float:
	var a2 := Vector2(a.x, a.z)
	var d2 := Vector2(b.x - a.x, b.z - a.z)
	var r: Rect2 = bld.aabb
	# Quick reject on the bounding box.
	var lo := a2.min(a2 + d2)
	var hi := a2.max(a2 + d2)
	if hi.x < r.position.x or hi.y < r.position.y or lo.x > r.end.x or lo.y > r.end.y:
		return -1.0
	# Parameters where the segment crosses the outline or a hole, sorted; between them it is inside or outside.
	var ts := PackedFloat64Array([0.0])
	for ring: PackedVector2Array in bld.rings:
		var n := ring.size()
		for k in n:
			var p := ring[k]
			var e := ring[(k + 1) % n] - p
			var den := d2.cross(e)
			if absf(den) < 1e-12:
				continue
			var w := p - a2
			var t := w.cross(e) / den
			var u := w.cross(d2) / den
			if t >= 0.0 and t <= 1.0 and u >= 0.0 and u <= 1.0:
				ts.append(t)
	ts.append(1.0)
	ts.sort()
	var top := top_of(bld)
	var bottom := bottom_of(bld)
	for k in ts.size() - 1:
		var t0 := ts[k]
		var t1 := ts[k + 1]
		if t0 >= t_max:
			break
		if t1 - t0 < 1e-9:
			continue
		var mid := a2 + d2 * ((t0 + t1) * 0.5)
		if not _inside(bld.rings, mid):
			continue
		# Inside the footprint on [t0, t1] the segment's height is linear: find where it enters (bottom, top).
		var y0 := lerpf(a.y, b.y, t0)
		var y1 := lerpf(a.y, b.y, t1)
		if y0 > bottom and y0 < top:
			return t0
		if y0 >= top and y1 < top:
			return t0 + (t1 - t0) * (top - y0) / (y1 - y0)
		if y0 <= bottom and y1 > bottom:
			return t0 + (t1 - t0) * (bottom - y0) / (y1 - y0)
	return -1.0


static func _inside(rings: Array, p: Vector2) -> bool:
	if not Geometry2D.is_point_in_polygon(p, rings[0]):
		return false
	for k in range(1, rings.size()):
		if Geometry2D.is_point_in_polygon(p, rings[k]):
			return false
	return true


## Buildings whose bounding box meets `rect` (package-frame x / z).
func buildings_in(rect: Rect2) -> Array:
	var out := []
	var a := tile_of(rect.position.x, rect.position.y)
	var b := tile_of(rect.end.x, rect.end.y)
	for j in range(a.y - 1, b.y + 2):
		for i in range(a.x - 1, b.x + 2):
			if tile_count(i, j) == 0:
				continue
			for bld: Dictionary in tile(i, j):
				if rect.intersects(bld.aabb):
					out.append(bld)
	return out


## The building whose footprint contains package-frame x, z (its Dictionary), or an empty one.
func building_at(x: float, z: float) -> Dictionary:
	var ti := tile_of(x, z)
	for dj in range(-1, 2):
		for di in range(-1, 2):
			var i := ti.x + di
			var j := ti.y + dj
			if tile_count(i, j) == 0:
				continue
			var e := _entry(i, j)
			var list: Array = e[0]
			var ids: PackedInt32Array = e[1].get(Vector2i(floori(x / CELL), floori(z / CELL)), PackedInt32Array())
			for k in ids:
				var bld: Dictionary = list[k]
				if bld.aabb.has_point(Vector2(x, z)) and _inside(bld.rings, Vector2(x, z)):
					return bld
	return {}
