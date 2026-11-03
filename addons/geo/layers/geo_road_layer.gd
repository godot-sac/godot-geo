@tool
## Roads and railways from the package's roads.bin (OpenStreetMap via Overture, see tools/roads.py).
##
## Roads are not meshes on the ground: the terrain's level of detail changes the drawn surface with distance, so a
## draped strip would z-fight or float. Instead Godot's 2D renderer paints the roads around the camera into two
## textures ("rings": near 2 km at 1 m per pixel, far 8 km at 4 m per pixel; red = asphalt, green = pavement,
## blue = rail) and the terrain shader blends them into the ground colour. A ring is repainted when the camera has
## moved an eighth of its size. Near the camera residential streets get pavements on both sides.
## Bridges are meshes: a deck at the heights stored in the package, with concrete sides. Tunnels are not drawn.
class_name GeoRoadLayer
extends GeoTerrainLayer

enum Flag { BRIDGE = 1, TUNNEL = 2, RAIL = 4 }
const RING_PIXELS := 2048
## Metres per pixel of the near and far rings.
const RING_SCALE: Array[float] = [1.0, 4.0]
const PAVEMENT_CLASSES := [10, 11, 12, 13, 15, 16]
const MINOR_CLASSES := [9, 11, 12, 13, 14, 15, 16]
## Road tiles whose draw commands are recorded per frame and ring.
const TILES_PER_FRAME := 3

@export var draw_bridges := true

## Record all pending ring tiles at once (screenshots, tests).
var build_all_now := false

var tile_m := 500.0
var tiles_x := 0
var tiles_z := 0
var count := 0
var bridges := 0
var _file: FileAccess
var _index := PackedInt64Array()
var _tiles := {}
var _lists := {}
var _viewports: Array[SubViewport] = []
var _painters: Array[_Painter] = []
var _centers: Array[Vector2] = [Vector2(INF, INF), Vector2(INF, INF)]
var _bridge_node: MeshInstance3D


func has_data() -> bool:
	return package != null and package.meta.has("roads")


func _rebuild() -> void:
	for v in _viewports:
		v.queue_free()
	_viewports.clear()
	_painters.clear()
	_centers = [Vector2(INF, INF), Vector2(INF, INF)]
	_tiles.clear()
	_lists.clear()
	if _bridge_node:
		_bridge_node.queue_free()
		_bridge_node = null
	if not has_data():
		return
	var err := _open(GeoTerrainPackage._global(package.path.path_join(package.meta.roads.file)))
	if not err.is_empty():
		push_error("GeoRoadLayer: " + err)
		return
	if not can_draw():
		return
	for k in 2:
		var vp := SubViewport.new()
		vp.size = Vector2i(RING_PIXELS, RING_PIXELS)
		vp.transparent_bg = true
		vp.disable_3d = true
		vp.msaa_2d = Viewport.MSAA_4X
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var p := _Painter.new()
		p.layer = self
		p.scale_m = RING_SCALE[k]
		p.near = k == 0
		vp.add_child(p)
		add_child(vp)
		_viewports.append(vp)
		_painters.append(p)
	if draw_bridges:
		_build_bridges()


func _open(file: String) -> String:
	_file = FileAccess.open(file, FileAccess.READ)
	if _file == null:
		return "%s: cannot open" % file
	var head := _file.get_buffer(20)
	if head.size() < 20 or head.slice(0, 4).get_string_from_ascii() != "GGRD" or head.decode_u16(4) != 1:
		return "%s: not a godot-geo roads file (version 1)" % file
	tile_m = head.decode_float(8)
	tiles_x = head.decode_u16(12)
	tiles_z = head.decode_u16(14)
	count = head.decode_u32(16)
	var err := GeoBuildingData.read_index(_file, tile_m, tiles_x, tiles_z, package.size_m, _index)
	return "%s: %s" % [file, err] if not err.is_empty() else ""


## Roads of tile (i, j): Array of [class, flags, width, PackedVector2Array points (package x / z),
## PackedFloat32Array deck heights (bridges) or empty].
func tile(i: int, j: int) -> Array:
	if i < 0 or j < 0 or i >= tiles_x or j >= tiles_z:
		return []
	var key := j * tiles_x + i
	if _tiles.has(key):
		return _tiles[key]
	var out := []
	var o := key * 4
	if _index[o + 3] > 0:
		_file.seek(_index[o])
		var b := _file.get_buffer(_index[o + 1]).decompress(_index[o + 2], FileAccess.COMPRESSION_DEFLATE)
		var center := Vector2(-package.size_m * 0.5 + (i + 0.5) * tile_m, -package.size_m * 0.5 + (j + 0.5) * tile_m)
		var p := 0
		while p + 8 <= b.size():  # a record that does not fit (truncated or corrupted file) ends the tile
			var cls := b[p]
			var flags := b[p + 1]
			var width := b.decode_float(p + 2)
			var n := b.decode_u16(p + 6)
			p += 8
			if p + n * (8 if flags & Flag.BRIDGE else 4) > b.size() or n < 2 or not is_finite(width):
				break
			var pts := PackedVector2Array()
			pts.resize(n)
			for k in n:
				pts[k] = Vector2(b.decode_s16(p) * 0.05, b.decode_s16(p + 2) * 0.05) + center
				p += 4
			var deck := PackedFloat32Array()
			if flags & Flag.BRIDGE:
				deck.resize(n)
				for k in n:
					deck[k] = b.decode_float(p)
					p += 4
			out.append([cls, flags, width, pts, deck])
	_tiles[key] = out
	return out


## Tiles that may hold roads inside `rect` (a road is filed under the tile of its middle point).
func tiles_in(rect: Rect2) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var half := package.size_m * 0.5
	var i0 := maxi(floori((rect.position.x + half) / tile_m) - 1, 0)
	var i1 := mini(floori((rect.end.x + half) / tile_m) + 1, tiles_x - 1)
	var j0 := maxi(floori((rect.position.y + half) / tile_m) - 1, 0)
	var j1 := mini(floori((rect.end.y + half) / tile_m) + 1, tiles_z - 1)
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			out.append(Vector2i(i, j))
	return out


## Draw lists of a tile for the ring painter, built once: [pavement near, pavement far, asphalt near, asphalt far,
## rail near, rail far], each an Array of [PackedVector2Array points, width in metres]. Near streets get
## pavements; the far ring leaves out minor ways. Bridges and tunnels are not painted.
func draw_lists(i: int, j: int) -> Array:
	var key := j * tiles_x + i
	if _lists.has(key):
		return _lists[key]
	var out := [[], [], [], [], [], []]
	for r: Array in tile(i, j):
		var cls: int = r[0]
		var flags: int = r[1]
		if flags & (Flag.BRIDGE | Flag.TUNNEL):
			continue
		var minor: bool = cls in MINOR_CLASSES
		var item := [r[3], r[2]]
		if flags & Flag.RAIL:
			out[4].append(item)
			out[5].append(item)
		elif cls in PAVEMENT_CLASSES:
			out[0].append(item)
			if not minor:
				out[1].append(item)
		else:
			if cls >= 4 and cls <= 8:
				out[0].append([r[3], r[2] + 4.0])  # pavements along streets
			out[2].append(item)
			if not minor:
				out[3].append(item)
	_lists[key] = out
	return out


func update_view(camera: Vector3) -> void:
	if _viewports.is_empty():
		return
	for k in 2:
		var extent := RING_PIXELS * RING_SCALE[k]
		var cam := Vector2(camera.x, camera.z)
		# Repaint after an eighth of the near ring, a quarter of the far one (it is costlier and changes less).
		if cam.distance_to(_centers[k]) < extent / (8.0 if k == 0 else 4.0):
			continue
		# Snap to whole pixels so the painted roads do not crawl between repaints.
		var c := (cam / RING_SCALE[k]).round() * RING_SCALE[k]
		_centers[k] = c
		_painters[k].show_rect(Rect2(c - Vector2(extent, extent) * 0.5, Vector2(extent, extent)))
	# Tiles entering a ring record their draw commands a few per frame; the ring texture and its rectangle switch
	# together once the new set is complete, so the ground never shows a half-painted ring.
	for k in 2:
		var p := _painters[k]
		if p.pending.is_empty():
			continue
		if p.step(TILES_PER_FRAME if build_all_now == false else 1 << 30):
			_viewports[k].render_target_update_mode = SubViewport.UPDATE_ONCE
			terrain.set_road_ring(k, _viewports[k].get_texture(), p.rect)


## Paints both rings around `camera` now (tests, screenshots, --check).
func build_all_around(camera: Vector3) -> void:
	build_all_now = true
	update_view(camera)
	build_all_now = false


## Number of road pieces painted in the near ring at its last repaint.
func painted() -> int:
	return _painters[0].painted if not _painters.is_empty() else 0


func _build_bridges() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	bridges = 0
	for j in tiles_z:
		for i in tiles_x:
			for r: Array in tile(i, j):
				if r[1] & Flag.BRIDGE and not (r[1] & Flag.TUNNEL):
					_deck(st, r[3], r[4], r[2])
					bridges += 1
	if bridges == 0:
		return
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	_bridge_node = MeshInstance3D.new()
	_bridge_node.name = "Bridges"
	_bridge_node.mesh = st.commit()
	_bridge_node.material_override = mat
	add_child(_bridge_node)


static func _deck(st: SurfaceTool, pts: PackedVector2Array, deck: PackedFloat32Array, width: float) -> void:
	var asphalt := Color(0.24, 0.24, 0.25).srgb_to_linear()
	var concrete := Color(0.62, 0.61, 0.58).srgb_to_linear()
	var hw := maxf(width, 3.0) * 0.5
	var thick := 1.6
	for k in pts.size() - 1:
		var a := pts[k]
		var b := pts[k + 1]
		var d := (b - a)
		if d.length() < 0.01:
			continue
		var side := Vector2(-d.y, d.x).normalized() * hw
		var ya := deck[k]
		var yb := deck[k + 1]
		var tl := Vector3(a.x + side.x, ya, a.y + side.y)
		var tr := Vector3(a.x - side.x, ya, a.y - side.y)
		var bl := Vector3(b.x + side.x, yb, b.y + side.y)
		var br := Vector3(b.x - side.x, yb, b.y - side.y)
		var dn := Vector3(0.0, -thick, 0.0)
		_quad(st, tl, bl, br, tr, Vector3.UP, asphalt)
		_quad(st, tl + dn, tr + dn, br + dn, bl + dn, Vector3.DOWN, concrete)
		_quad(st, tl, tl + dn, bl + dn, bl, Vector3(side.x, 0.0, side.y), concrete)
		_quad(st, tr, br, br + dn, tr + dn, Vector3(-side.x, 0.0, -side.y), concrete)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, out: Vector3, col: Color) -> void:
	for tri in [[a, b, c], [a, c, d]]:
		var p0: Vector3 = tri[0]
		var p1: Vector3 = tri[1]
		var p2: Vector3 = tri[2]
		if (p1 - p0).cross(p2 - p0).dot(out) > 0.0:  # front faces wind clockwise: the cross product points away
			var t := p1
			p1 = p2
			p2 = t
		for v: Vector3 in [p0, p1, p2]:
			st.set_color(col)
			st.add_vertex(v)


## One ring's canvas: three layers (pavement, asphalt, rail, drawn in that order) holding one canvas item per
## road tile. A tile records its draw commands once when it enters the ring; moving the ring only changes this
## node's transform (package metres -> pixels), so a repaint costs the GPU, not GDScript.
class _Painter:
	extends Node2D

	var layer: GeoRoadLayer
	var rect := Rect2()
	var scale_m := 1.0
	var near := true
	var painted := 0
	var pending: Array[Vector2i] = []  # tiles still to record for `rect`
	var _passes: Array[Node2D] = []
	var _items := {}  # Vector2i -> [3 canvas items]

	## Starts moving the ring to `r`; step() records the tiles it needs and applies the move when done.
	func show_rect(r: Rect2) -> void:
		rect = r
		pending.clear()
		for t: Vector2i in layer.tiles_in(r):
			if not _items.has(t):
				pending.append(t)

	## Records up to `n` pending tiles; when none are left, drops tiles outside the ring and moves the canvas.
	## Returns true when the ring is complete.
	func step(n: int) -> bool:
		if _passes.is_empty():
			for k in 3:
				var node := Node2D.new()
				add_child(node)
				_passes.append(node)
		while n > 0 and not pending.is_empty():
			var t: Vector2i = pending.pop_back()
			n -= 1
			var lists: Array = layer.draw_lists(t.x, t.y)
			var items := []
			for k in 3:
				var item := _TileCanvas.new()
				item.lines = lists[k * 2 + (0 if near else 1)]
				item.color = [Color(0, 1, 0), Color(1, 0, 0), Color(0, 0, 1)][k]
				item.min_width = scale_m
				_passes[k].add_child(item)
				items.append(item)
			_items[t] = items
		if not pending.is_empty():
			return false
		var keep := {}
		for t: Vector2i in layer.tiles_in(rect):
			keep[t] = true
		for t: Vector2i in _items.keys():
			if not keep.has(t):
				for item: Node in _items[t]:
					item.queue_free()
				_items.erase(t)
		var to_px := 1.0 / scale_m
		position = -rect.position * to_px
		scale = Vector2(to_px, to_px)
		painted = 0
		for t: Vector2i in _items:
			painted += _items[t][1].lines.size() + _items[t][0].lines.size()
		return true


class _TileCanvas:
	extends Node2D

	var lines: Array = []  # [PackedVector2Array points (metres), width (metres)]
	var color := Color.WHITE
	var min_width := 1.0

	func _draw() -> void:
		for item: Array in lines:
			draw_polyline(item[0], color, maxf(item[1], min_width), true)
