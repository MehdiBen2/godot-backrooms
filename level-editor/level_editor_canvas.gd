extends Control
## Level editor, part 1: the map canvas. Draws the grid, zones, markers and free-placed objects with their
## gizmos, turns mouse input into painting, erasing, placing, moving and rotating, snaps and aligns objects,
## and keeps the undo stack. level_editor_files.gd adds opening and saving levels, level_editor.gd the UI.

const CREAM := Color("e6e1cd")
const DIM := Color(0.9, 0.882, 0.804, 0.55)
const GOLD := Color("e6c65a")
const RED := Color("c4271f")
const SEL := Color("35e0ff")             # selection gizmo: nothing else on the map is cyan, so it reads on any floor

const WALL := "#"
const FLOOR := "."
const PIT := "O"
const THIN := "T"                    # v1 tiles, converted into objects when a level opens (_migrate_legacy)
const ARCH := "A"
const DOOR := "D"
const ZONES := {"tall": Color("5a9bff"), "low": Color("ff8a3d"), "tiles": Color("f2f2f2"), "bright": Color("fff04a"),
	"dark": Color("7a2cff"), "dim": Color("8a6a3a"), "flicker": Color("ff3f9a"), "grime": Color("8a6a30"), "classic": Color("ffe86a"),
	"mannequin": Color("e8e0d0")}
const PAINT_SLOTS := ["wall", "floor", "ceiling"]
const MARKERS := {"spawn": Color("2fd968"), "exit": Color("2fd9ee"), "entity": Color("ff3030"), "tv": Color("5c8dff"), "drop_hole": Color("ff7722")}
const BASE_COLORS := {WALL: Color("3f3a30"), FLOOR: Color("cdb86a"), PIT: Color("050505"),
	THIN: Color("7a7364"), ARCH: Color("8a7a52"), DOOR: Color("6b4a2e")}
# Free-placed objects, mirrored from the game's level_data.gd. Positions are in cells with a cell's centre
# on a whole number (the same frame as "spawn"), rotation is degrees clockwise on this map, scale is the
# width in cells. Locally an object faces +x (you walk through it along x) and spans y.
const CELL_M := 4.5                  # metres per cell in the game (level_data.gd CELL)
const SNAP_STEP := 0.5               # snap to cell centres and cell edges
var index: Array = []
var current := -1
var grid_size := 46
var grid: Array = []                 # grid[z] is an Array of one-char strings
var zones := {}                      # zone -> {Vector2i: true}
var paint := {"wall": {}, "floor": {}, "ceiling": {}}   # slot -> {Vector2i: pbr name}: per-cell material overrides
var paint_mat := ""                  # the material the paint tools lay down
var markers := {}                    # marker -> Vector2i or null
var spawn_rot := 270.0               # the way the player looks at spawn: degrees clockwise on the map, 0 = right, 270 = up
var tool := "base:" + WALL
var brush := 1
var undo_stack: Array = []
var painting := false
var erasing := false
var panning := false
var space_down := false
var zoom := 14.0
var pan := Vector2(10, 10)
var hover := Vector2i(-1, -1)
var dirty := false
var objects: Array = []              # {type, pos_x, pos_y, rotation, scale}
var selected := -1                   # index into objects
var hover_obj := -1
var drag := ""                       # "" | "move" | "rotate" | "place"
var drag_off := Vector2.ZERO         # grab point -> object origin, in cells
var mouse_px := Vector2(-1, -1)
var place_rot := 0.0                 # new objects start at the last rotation / width used
var place_scale := 1.0
var snap := true
var rot_snap := true
var align := true                    # turn doors / arches / thin walls to fit the wall or corridor they land on
var OBJ_TYPES: Array = []            # the object types, in levels/object_types.json order
var OBJ_INFO := {}                   # type -> its object_types.json entry, plus "col" as a Color
var insp_undo := -1                  # the object the inspector already pushed an undo step for
var redo_stack: Array = []

var GAME := OS.get_environment("BACKROOMS_GAME_DIR") if OS.has_environment("BACKROOMS_GAME_DIR") \
	else ProjectSettings.globalize_path("res://").path_join("../godot-backrooms").simplify_path()
var materials := {}                  # slot -> pbr name: the level-wide material of each surface
var pbr_names: Array = []            # the folders in the game's textures/pbr/

# How the map is shown (the bar above it)
var view_ceiling := false            # show the ceiling's materials instead of the floor's
var show_tex := true                 # draw the real textures on cells
var show_zones := true
var show_paint := true               # outline painted materials and list them
var show_objects := true
var show_grid := true
# How a click paints: "brush" (drag the brush), "rect" (drag a rectangle), "fill" (the connected area)
var mode := "brush"
var rect_from := Vector2i(-1, -1)    # where a rectangle drag started
var hover_raw := Vector2i(-1, -1)    # the cell under the mouse even outside the map (drawing there grows it)
var auto_walls := true               # floor rectangles are drawn as rooms: a wall round a floor
var scatter := 100                   # % of the cells a paint stroke actually paints (random variation)
var paint_mix: Array = []            # more materials painted at random alongside paint_mat
var stroke_seed := 0                 # new each click, so scatter / mix are stable while you drag over a cell
const MAX_SIZE := 160

# Floors: the level's other floors, kept aside while you edit one. The live grid / zones / paint / markers /
# objects are floor `floor_idx`; floor_store holds every other floor (int -> the same set of fields).
var floor_idx := 0
var floor_store := {}
var show_onion := true               # the floor below (or above) drawn faintly under this one

var font: FontFile = load("res://fonts/vcr.ttf")
var canvas: Control
var title_label: Label
var status: Label
var info: Label
var insp: VBoxContainer
var insp_type: OptionButton
var insp_x: SpinBox
var insp_y: SpinBox
var insp_rot: SpinBox
var insp_scale: SpinBox
func _info(t: String) -> Dictionary:
	return OBJ_INFO.get(t, {"label": t, "key": "", "col": Color("a39c8a"), "help": ""})

## A size from object_types.json, in cells
func _cells(t: String, key: String, metres: float) -> float:
	return float(_info(t).get(key, metres)) / CELL_M

func _update_title() -> void:
	if current < 0: return
	title_label.text = "%s%s" % [str(index[current].get("name", "")), "  *" if dirty else ""]
	title_label.add_theme_color_override("font_color", RED if dirty else CREAM)
	_update_info()

func _update_info() -> void:
	var open_cells := 0
	for row in grid:
		for ch in row:
			if ch == FLOOR or ch == ARCH: open_cells += 1
	var warn := []
	var ground: Dictionary = markers if floor_idx == 0 else floor_store.get(0, {}).get("markers", {})
	for m in ["spawn", "exit"]:
		var found = ground.get(m)
		if m == "exit":                        # an exit can be on any floor
			for f in floor_store:
				if floor_store[f].markers.get("exit") != null: found = true
			if markers.get("exit") != null: found = true
		if found == null: warn.append("no " + m)
	info.text = "%s   %dx%d   %d open   %d objects   %s" % [_floor_name(floor_idx), grid_size, grid_size, open_cells, objects.size(), ("WARN: " + ", ".join(warn)) if not warn.is_empty() else "OK"]
	info.add_theme_color_override("font_color", RED if not warn.is_empty() else DIM)

var preview3d: Control               # level_editor_3d.gd: rebuilt when the map changes while it is open

func _mark_dirty() -> void:
	dirty = true
	if preview3d != null and preview3d.visible: preview3d.mark_stale()
	_update_title()
	canvas.queue_redraw()

# ---------------------------------------------------------------- canvas
func _fit() -> void:
	if canvas == null: return
	if canvas.size.x < 32.0:             # not laid out yet (the level opens before the first frame)
		if not canvas.resized.is_connected(_fit): canvas.resized.connect(_fit, CONNECT_ONE_SHOT)
		return
	zoom = clampf(minf(canvas.size.x, canvas.size.y) / maxf(grid_size, 1) * 0.96, 6.0, 40.0)
	pan = (canvas.size - Vector2(grid_size, grid_size) * zoom) / 2.0
	canvas.queue_redraw()

## Every material keeps one bright colour (from its name), used for its outlines and marks on the map
func _paint_colour(id: String) -> Color:
	return Color.from_hsv(fmod(float(hash(id) & 0xffff) / 65535.0, 1.0), 0.7, 1.0)

# ---------------------------------------------------------------- material thumbnails
# How a surface looks when the level sets no material: the game's own Level 0 textures
const DEFAULT_TEX := {"wall": "textures/wall_color.png", "floor": "textures/l0_carpet_color.webp",
	"ceiling": "textures/l0_ceiling_color.webp", "tiles": "textures/tiles_color.png"}
# ...and the tint the game puts over each (level_geometry.gd _mat / _wall_material)
const DEFAULT_TINT := {"wall": Color(1.0, 0.98, 0.88), "floor": Color(1.0, 0.94, 0.75), "ceiling": Color(0.89, 0.85, 0.74)}
const THUMB := 128
const DIRS4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const WALL_SHADE := Color(0.42, 0.4, 0.36)      # wall tops drawn darker than the floor round them
const DEEP_WALL := Color("1d1a14")               # wall mass with no open side
var _thumbs := {}                    # key -> {tex, avg}

## The colour map of a folder in the game's textures/pbr/: its <name>_Color file, else what its .tres uses as albedo
func _pbr_colour_path(id: String) -> String:
	var dir := GAME.path_join("textures/pbr/" + id)
	for ext in ["jpg", "png", "webp"]:
		var p := dir.path_join("%s_Color.%s" % [id, ext])
		if FileAccess.file_exists(p): return p
	var tres := FileAccess.get_file_as_string(dir.path_join(id + ".tres"))
	var m := RegEx.create_from_string('albedo_texture = ExtResource\\("([^"]+)"\\)').search(tres)
	if m != null:
		var r := RegEx.create_from_string('path="res://([^"]+)" id="%s"' % m.get_string(1)).search(tres)
		if r != null: return GAME.path_join(r.get_string(1))
	return ""

## A small texture of a material and its average colour. `key` is a pbr name, or "default:<slot>" for the
## game's built-in look. Thumbnails are cached in user://thumbs so the editor opens fast next time.
func _thumb(key: String) -> Dictionary:
	if _thumbs.has(key): return _thumbs[key]
	var e := {"tex": null, "avg": _paint_colour(key)}
	var path := ""
	if key.begins_with("default:"): path = GAME.path_join(str(DEFAULT_TEX.get(key.get_slice(":", 1), "")))
	elif key != "": path = _pbr_colour_path(key)
	if path != "" and FileAccess.file_exists(path):
		var cache := "user://thumbs/%s_v2.png" % key.replace(":", "_")
		var img: Image = null
		if FileAccess.file_exists(cache) and FileAccess.get_modified_time(cache) >= FileAccess.get_modified_time(path):
			img = Image.load_from_file(cache)
		if img == null:
			img = Image.load_from_file(path)
			if img != null:
				if img.is_compressed(): img.decompress()
				img.convert(Image.FORMAT_RGBA8)
				img.resize(THUMB, THUMB, Image.INTERPOLATE_LANCZOS)
				var tint: Color = DEFAULT_TINT.get(key.get_slice(":", 1), Color.WHITE) if key.begins_with("default:") else Color.WHITE
				if tint != Color.WHITE:
					for y in THUMB:
						for x in THUMB:
							img.set_pixel(x, y, img.get_pixel(x, y) * tint)
				DirAccess.make_dir_recursive_absolute("user://thumbs")
				img.save_png(cache)
		if img != null:
			var sum := Color(0, 0, 0, 0)
			var n := 0.0
			for y in range(0, img.get_height(), 8):
				for x in range(0, img.get_width(), 8):
					sum += img.get_pixel(x, y)
					n += 1.0
			e.avg = Color(sum.r / n, sum.g / n, sum.b / n)
			img.generate_mipmaps()
			e.tex = ImageTexture.create_from_image(img)
	_thumbs[key] = e
	return e

## What a cell's surface is made of: its painted material, else the level's, else "default:<slot>".
## A Tiles zone floor uses the level's tiles material, as in the game.
func _surface_key(slot: String, c: Vector2i) -> String:
	if paint.has(slot) and paint[slot].has(c): return paint[slot][c]
	var s := slot
	if slot == "floor" and zones.has("tiles") and zones["tiles"].has(c): s = "tiles"
	var id := str(materials.get(s, ""))
	return id if id != "" else "default:" + s

func _nice_key(k: String) -> String:
	return "default" if k.begins_with("default:") else k

# ---------------------------------------------------------------- drawing
func _cell_at(p: Vector2) -> Vector2i:
	var q := (p - pan) / zoom
	return Vector2i(floori(q.x), floori(q.y))

func _in_grid(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < grid_size and c.y < grid_size

func _cell_rect(c: Vector2i) -> Rect2:
	return Rect2(pan + Vector2(c) * zoom, Vector2(zoom, zoom))

## The strip `w` wide along side `d` of `r`, inside it
func _edge(r: Rect2, d: Vector2i, w: float) -> Rect2:
	if d.x > 0: return Rect2(r.end.x - w, r.position.y, w, r.size.y)
	if d.x < 0: return Rect2(r.position.x, r.position.y, w, r.size.y)
	if d.y > 0: return Rect2(r.position.x, r.end.y - w, r.size.x, w)
	return Rect2(r.position.x, r.position.y, r.size.x, w)

## A little label on a dark pill, its top-left corner at `p`
func _tag(p: Vector2, text: String, col: Color, size := 11) -> void:
	var ts := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	canvas.draw_rect(Rect2(p, ts + Vector2(6, 2)), Color(0, 0, 0, 0.78))
	canvas.draw_string(font, p + Vector2(3, 1 + font.get_ascent(size)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _draw_canvas() -> void:
	canvas.draw_rect(Rect2(Vector2.ZERO, canvas.size), Color("080704"))
	if _can_grow() and zoom >= 7.0:             # the space round the map you can draw into
		var off := Vector2(fposmod(pan.x, zoom), fposmod(pan.y, zoom))
		for i in int(canvas.size.x / zoom) + 2:
			canvas.draw_line(Vector2(off.x + i * zoom, 0), Vector2(off.x + i * zoom, canvas.size.y), Color(1, 1, 1, 0.035))
		for i in int(canvas.size.y / zoom) + 2:
			canvas.draw_line(Vector2(0, off.y + i * zoom), Vector2(canvas.size.x, off.y + i * zoom), Color(1, 1, 1, 0.035))
	# only the cells on screen
	var lo := Vector2i(maxi(0, floori(-pan.x / zoom)), maxi(0, floori(-pan.y / zoom)))
	var hi := Vector2i(mini(grid_size - 1, floori((canvas.size.x - pan.x) / zoom)), mini(grid_size - 1, floori((canvas.size.y - pan.y) / zoom)))
	var tex_on := show_tex and zoom >= 5.0
	var surf := "ceiling" if view_ceiling else "floor"
	for z in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			_draw_cell(Vector2i(x, z), tex_on, surf)
	_draw_shading(lo, hi)
	if show_onion: _draw_onion()
	if show_zones: _draw_zones()
	if show_paint: _draw_paint_marks()
	if show_grid: _draw_grid(lo, hi)
	if show_objects:
		for o: Dictionary in objects:
			_draw_object(o, 1.0)
	_draw_markers()
	if _object_tool():
		if not show_objects: pass
		elif hover_obj >= 0 and hover_obj != selected and drag == "":
			_draw_outline(objects[hover_obj], Color(SEL, 0.6), 1.5)
		elif hover.x >= 0 and hover_obj < 0 and drag == "" and tool.begins_with("obj:"):
			var p := _snap_pos(_pos_at(mouse_px))           # ghost of what a click would place
			var ghost := {"type": tool.get_slice(":", 1), "pos_x": p.x, "pos_y": p.y, "rotation": _wall_align(p, place_rot), "scale": place_scale}
			_draw_object(ghost, 0.45)
			_draw_arrow(ghost, Color(SEL, 0.5))
	else:
		_draw_hover()
	if selected >= 0 and show_objects:
		_draw_gizmo(objects[selected])
	canvas.draw_rect(Rect2(pan, Vector2(grid_size, grid_size) * zoom), GOLD, false, 1.5)
	_draw_rulers()
	if show_paint: _draw_legend()
	if view_ceiling:
		_tag(Vector2(canvas.size.x * 0.5 - 90, 8), "CEILING VIEW  (C: floor)", GOLD, 14)

func _draw_cell(c: Vector2i, tex_on: bool, surf: String) -> void:
	var r := _cell_rect(c)
	var ch: String = grid[c.y][c.x]
	if ch == WALL:
		var exposed := false
		for d: Vector2i in DIRS4:
			var n := c + d
			if _in_grid(n) and grid[n.y][n.x] != WALL: exposed = true
		if not exposed:
			canvas.draw_rect(r, DEEP_WALL)
			if zoom >= 10.0:       # hatched like the solid mass on a floor plan; the lines join up cell to cell
				var hc := Color(1, 1, 1, 0.045)
				canvas.draw_line(r.position + Vector2(0, zoom), r.position + Vector2(zoom, 0), hc)
				canvas.draw_line(r.position + Vector2(0, zoom * 0.5), r.position + Vector2(zoom * 0.5, 0), hc)
				canvas.draw_line(r.position + Vector2(zoom * 0.5, zoom), r.position + Vector2(zoom, zoom * 0.5), hc)
			return
		if not tex_on:
			canvas.draw_rect(r, BASE_COLORS[WALL])
			return
		var tw := _thumb(_surface_key("wall", c))
		if tw.tex != null: canvas.draw_texture_rect(tw.tex, r, false, WALL_SHADE)
		else: canvas.draw_rect(r, (tw.avg as Color) * WALL_SHADE)
		return
	if ch == PIT:
		canvas.draw_rect(r, Color("030303"))
		canvas.draw_rect(r.grow(-zoom * 0.14), Color("100e0a"), false, maxf(1.0, zoom * 0.06))
		return
	if not tex_on:
		canvas.draw_rect(r, BASE_COLORS.get(ch, BASE_COLORS[FLOOR]))
		return
	var t := _thumb(_surface_key(surf, c))
	if t.tex != null: canvas.draw_texture_rect(t.tex, r, false, Color(0.9, 0.9, 0.95) if view_ceiling else Color.WHITE)
	else: canvas.draw_rect(r, t.avg)

## Contact shadows where floor meets wall (as if looking down into the rooms), and a lit rim on the wall tops
func _draw_shading(lo: Vector2i, hi: Vector2i) -> void:
	if zoom < 6.0: return
	var s1 := zoom * 0.1
	var s2 := zoom * 0.26
	var rim := maxf(1.0, zoom * 0.06)
	for z in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			if grid[z][x] == WALL: continue
			var c := Vector2i(x, z)
			var r := _cell_rect(c)
			for d: Vector2i in DIRS4:
				var n := c + d
				if not _in_grid(n) or grid[n.y][n.x] != WALL: continue
				canvas.draw_rect(_edge(r, d, s2), Color(0, 0, 0, 0.16))
				canvas.draw_rect(_edge(r, d, s1), Color(0, 0, 0, 0.3))
				canvas.draw_rect(_edge(_cell_rect(n), -d, rim), Color(1, 0.95, 0.8, 0.3))

## The floor below this one (the one above, on the lowest floor) as a faint cyan outline of its open space,
## and its stairs, so floors line up
func _draw_onion() -> void:
	var other := floor_idx - 1 if floor_store.has(floor_idx - 1) else floor_idx + 1
	if not floor_store.has(other): return
	var fd: Dictionary = floor_store[other]
	var open := {}
	for z in grid_size:
		for x in grid_size:
			if fd.grid[z][x] != WALL: open[Vector2i(x, z)] = true
	var col := Color(0.35, 0.85, 1.0, 0.55)
	_outline_cells(open, col, maxf(1.0, zoom * 0.05), 0.0)
	for o: Dictionary in fd.objects:
		if str(o.type).begins_with("stairs_"): _draw_object(o, 0.35)
	if zoom >= 9.0:
		_tag(Vector2(canvas.size.x - 200, 8), "cyan: " + _floor_name(other), col, 11)

func _draw_grid(lo: Vector2i, hi: Vector2i) -> void:
	if zoom < 7.0: return
	for i in range(lo.x, hi.x + 2):
		canvas.draw_line(pan + Vector2(i, lo.y) * zoom, pan + Vector2(i, hi.y + 1) * zoom, Color(0, 0, 0, 0.34 if i % 5 == 0 else 0.13))
	for i in range(lo.y, hi.y + 2):
		canvas.draw_line(pan + Vector2(lo.x, i) * zoom, pan + Vector2(hi.x + 1, i) * zoom, Color(0, 0, 0, 0.34 if i % 5 == 0 else 0.13))

## Cell numbers along the map's top and left edges, kept on screen when the map is scrolled past them
func _draw_rulers() -> void:
	if zoom < 4.0: return
	var step := 5 if zoom >= 9.0 else 10
	var ty := clampf(pan.y - 17.0, 2.0, canvas.size.y - 17.0)
	var lx := clampf(pan.x - 4.0, 26.0, canvas.size.x)
	for i in range(0, grid_size, step):
		var x := pan.x + (i + 0.5) * zoom
		if x > 0 and x < canvas.size.x:
			var w := font.get_string_size(str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			_tag(Vector2(x - w * 0.5 - 3, ty), str(i), DIM, 10)
		var y := pan.y + (i + 0.5) * zoom
		if y > 0 and y < canvas.size.y:
			var w := font.get_string_size(str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			_tag(Vector2(lx - w - 6, y - 7), str(i), DIM, 10)

## The top-left cell of every separate patch in `cells` (side-by-side neighbours make one patch) of at least
## `min_cells` cells
func _patch_tops(cells: Dictionary, min_cells := 1) -> Array:
	var seen := {}
	var tops: Array = []
	for start: Vector2i in cells:
		if seen.has(start): continue
		var best := start
		var todo: Array = [start]
		seen[start] = true
		var count := 0
		while not todo.is_empty():
			var c: Vector2i = todo.pop_back()
			count += 1
			if c.y < best.y or (c.y == best.y and c.x < best.x): best = c
			for d: Vector2i in DIRS4:
				var n: Vector2i = c + d
				if cells.has(n) and not seen.has(n):
					seen[n] = true
					todo.append(n)
		if count >= min_cells: tops.append(best)
	return tops

## An outline `w` wide round each patch of `cells`, `inset` pixels in from the cell edges
func _outline_cells(cells: Dictionary, col: Color, w: float, inset: float) -> void:
	for c: Vector2i in cells:
		var r := _cell_rect(c).grow(-inset)
		for d: Vector2i in DIRS4:
			if not cells.has(c + d): canvas.draw_rect(_edge(r, d, w), col)

## Each zone as a light wash with a solid outline round every patch, and its name on the patch
func _draw_zones() -> void:
	var w := maxf(1.5, zoom * 0.07)
	var i := 0
	for zn in ZONES:
		var cells: Dictionary = zones[zn]
		if cells.is_empty(): continue
		var col: Color = ZONES[zn]
		for c: Vector2i in cells:
			canvas.draw_rect(_cell_rect(c), Color(col, 0.16))
		_outline_cells(cells, col, w, 1.0 + (i % 3) * w)       # overlapping zones step their outlines inwards
		if zoom >= 9.0:
			for top: Vector2i in _patch_tops(cells):
				_tag(pan + Vector2(top) * zoom + Vector2(3, 3 + (i % 3) * 14), zn.to_upper(), col, 10)
		i += 1

## Painted materials: an outline in the material's own colour round each painted patch, and its name, for
## the surfaces this view shows. The floor view also flags painted ceilings with a corner mark.
func _draw_paint_marks() -> void:
	var w := maxf(1.5, zoom * 0.08)
	for slot in (["ceiling"] if view_ceiling else ["floor", "wall"]):
		var by_mat := {}
		for c: Vector2i in paint[slot]:
			if not by_mat.has(paint[slot][c]): by_mat[paint[slot][c]] = {}
			by_mat[paint[slot][c]][c] = true
		for id in by_mat:
			var col := _paint_colour(id)
			_outline_cells(by_mat[id], Color(0, 0, 0, 0.6), w + 2.0, w * 0.5)
			_outline_cells(by_mat[id], col, w, w * 0.5 + 1.0)
			if zoom >= 9.0:
				for top: Vector2i in _patch_tops(by_mat[id], 4):      # scattered specks go unlabelled (the legend has them)
					_tag(pan + (Vector2(top) + Vector2(0, 1)) * zoom + Vector2(3, -17), id, col, 10)
	if not view_ceiling:
		var k := maxf(4.0, zoom * 0.32)
		for c: Vector2i in paint["ceiling"]:
			var e := _cell_rect(c).end
			var col := _paint_colour(paint["ceiling"][c])
			canvas.draw_colored_polygon(PackedVector2Array([e, e - Vector2(k, 0), e - Vector2(0, k)]), col)

## Bottom-left of the map: every material painted on this level and how many cells of each surface
func _draw_legend() -> void:
	var rows := {}
	for slot in PAINT_SLOTS:
		for c in paint[slot]:
			var id: String = paint[slot][c]
			if not rows.has(id): rows[id] = {"floor": 0, "wall": 0, "ceiling": 0}
			rows[id][slot] += 1
	if rows.is_empty(): return
	var lines := {}
	var width := 90.0
	for id in rows:
		var parts := []
		for slot in PAINT_SLOTS:
			if rows[id][slot] > 0: parts.append("%s %d" % [slot, rows[id][slot]])
		lines[id] = "%s   %s" % [id, "  ".join(parts)]
		width = maxf(width, font.get_string_size(lines[id], HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 44)
	var lh := 22.0
	var box := Rect2(8, canvas.size.y - 14 - lh * (rows.size() + 1), width, lh * (rows.size() + 1) + 6)
	canvas.draw_rect(box, Color(0, 0, 0, 0.8))
	canvas.draw_rect(box, Color("3a3522"), false, 1.0)
	canvas.draw_string(font, box.position + Vector2(8, 16), "PAINTED MATERIALS", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, GOLD)
	var y := box.position.y + lh
	for id in rows:
		var sw := Rect2(box.position.x + 8, y + 2, 18, 18)
		var t := _thumb(id)
		if t.tex != null: canvas.draw_texture_rect(t.tex, sw, false)
		else: canvas.draw_rect(sw, t.avg)
		canvas.draw_rect(sw, _paint_colour(id), false, 2.0)
		canvas.draw_string(font, Vector2(sw.end.x + 8, y + 16), lines[id], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, CREAM)
		y += lh

func _draw_markers() -> void:
	for m in MARKERS:
		var c = markers[m]
		if c == null: continue
		var p: Vector2 = pan + (Vector2(c) + Vector2(0.5, 0.5)) * zoom
		var rad := maxf(zoom * 0.42, 7.0)
		canvas.draw_circle(p + Vector2(1.5, 2.0), rad, Color(0, 0, 0, 0.5))
		canvas.draw_circle(p, rad, MARKERS[m])
		canvas.draw_arc(p, rad, 0, TAU, 24, Color.BLACK, 1.5)
		var fs := maxi(8, int(rad * 1.2))
		var letter: String = str(m).substr(0, 1).to_upper()
		var ls := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		canvas.draw_string(font, p + Vector2(-ls.x * 0.5, fs * 0.36), letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.BLACK)
		if m == "spawn": _draw_look_arrow(p, rad)
		elif m == "drop_hole": _draw_drop_hole_indicator(p, rad)
		if zoom >= 12.0:
			var tag_text: String = m.to_upper()
			if m == "drop_hole":
				tag_text = "DROP HOLE [TO F%d]" % (floor_idx - 1)
			_tag(p + Vector2(rad + 4, -8), tag_text, MARKERS[m], 10)

## Visual transition indicator for a drop hole / pit descent
func _draw_drop_hole_indicator(p: Vector2, rad: float) -> void:
	canvas.draw_circle(p, rad * 0.72, Color(0.04, 0.04, 0.04, 0.95))
	canvas.draw_circle(p, rad * 0.42, Color(0.85, 0.4, 0.1, 0.8))
	canvas.draw_circle(p, rad * 0.18, Color.BLACK)
	var sz := rad * 0.55
	var pts := PackedVector2Array([p + Vector2(-sz * 0.45, -sz * 0.25), p + Vector2(0, sz * 0.4), p + Vector2(sz * 0.45, -sz * 0.25)])
	canvas.draw_polyline(pts, Color.WHITE, 1.8)

## An arrow out of the spawn marker showing where the player starts out looking
func _draw_look_arrow(p: Vector2, rad: float) -> void:
	var d := Vector2.from_angle(deg_to_rad(spawn_rot))
	var n := d.orthogonal()
	var tip := p + d * (rad + maxf(zoom * 1.1, 16.0))
	var base := p + d * (rad + 1.0)
	var head := maxf(zoom * 0.4, 7.0)
	var col: Color = MARKERS["spawn"]
	canvas.draw_line(base, tip - d * head * 0.5, Color.BLACK, 5.0)
	canvas.draw_line(base, tip - d * head * 0.5, col, 3.0)
	var tri := PackedVector2Array([tip, tip - d * head + n * head * 0.6, tip - d * head - n * head * 0.6])
	canvas.draw_colored_polygon(tri, col)
	canvas.draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), Color.BLACK, 1.5)

## What the current tool is about to do under the mouse: the brush footprint, the rectangle being dragged,
## or the cell a fill starts from, filled with the colour or material it lays down
func _draw_hover() -> void:
	var grow := _can_grow()
	var at := hover_raw if grow else hover
	if at.x < -1000 or (not grow and hover.x < 0): return
	if tool.begins_with("mark:"):
		var r := _cell_rect(hover)
		canvas.draw_rect(r, Color(MARKERS.get(tool.get_slice(":", 1), Color.WHITE), 0.4))
		canvas.draw_rect(r, Color.WHITE, false, 1.5)
		return
	var m := "rect" if tool == "gen" else _mode_now()
	var cells: Array
	if rect_from.x >= 0: cells = _rect_cells(rect_from, at)
	elif m == "fill" or tool == "gen": cells = [at]
	else: cells = _brush_cells(at)
	var area := {}
	for c: Vector2i in cells:
		if grow or _in_grid(c): area[c] = true
	var tex: Texture2D = null
	if tool.begins_with("paint:") and paint_mat != "": tex = _thumb(paint_mat).tex
	var col := _tool_colour()
	var room := rect_from.x >= 0 and auto_walls and tool == "base:" + FLOOR and absi(at.x - rect_from.x) >= 2 and absi(at.y - rect_from.y) >= 2
	var lo := rect_from.min(at)
	var hi := rect_from.max(at)
	for c: Vector2i in area:
		var ring := room and (c.x == lo.x or c.y == lo.y or c.x == hi.x or c.y == hi.y)
		if ring: canvas.draw_rect(_cell_rect(c), Color(0.15, 0.13, 0.1, 0.85))
		elif tex != null: canvas.draw_texture_rect(tex, _cell_rect(c), false, Color(1, 1, 1, 0.8))
		else: canvas.draw_rect(_cell_rect(c), Color(col, 0.5))
	_outline_cells(area, Color.WHITE, 1.5, 0.0)
	if rect_from.x >= 0:
		var sz := (at - rect_from).abs() + Vector2i.ONE
		var what := "GENERATE " if tool == "gen" else ("ROOM " if room else "")
		_tag(mouse_px + Vector2(14, 10), "%s%d x %d" % [what, sz.x, sz.y], CREAM, 12)
	elif tool == "gen":
		_tag(mouse_px + Vector2(14, 10), "drag the area to generate", CREAM, 12)
	elif grow and not _in_grid(at):
		_tag(mouse_px + Vector2(14, 10), "draws outside: the map grows", CREAM, 12)
	elif m == "fill":
		_tag(mouse_px + Vector2(14, 10), "FILL", CREAM, 12)

func _tool_colour() -> Color:
	var what := tool.get_slice(":", 1)
	match tool.get_slice(":", 0):
		"base": return Color("8a7f68") if what == WALL else BASE_COLORS.get(what, Color.WHITE)
		"zone": return ZONES.get(what, Color.WHITE)
		"paint": return _paint_colour(paint_mat)
		"gen": return Color("3fd1a0")
	return Color.WHITE

## Ctrl held = fill, Shift held = rectangle, otherwise the mode picked in the bar over the map
func _mode_now() -> String:
	if Input.is_key_pressed(KEY_CTRL): return "fill"
	if Input.is_key_pressed(KEY_SHIFT): return "rect"
	return mode

# ---------------------------------------------------------------- input
## Zoom by `factor`, keeping the map point under `at` fixed.
func _zoom_at(at: Vector2, factor: float) -> void:
	var before := (at - pan) / zoom
	zoom = clampf(zoom * factor, 4.0, 80.0)
	pan = at - before * zoom
	canvas.queue_redraw()

func _canvas_input(ev: InputEvent) -> void:
	if ev is InputEventMagnifyGesture:              # trackpad pinch
		_zoom_at((ev as InputEventMagnifyGesture).position, (ev as InputEventMagnifyGesture).factor)
	elif ev is InputEventPanGesture:                # trackpad two-finger scroll: move the map, Ctrl = zoom
		var pg := ev as InputEventPanGesture
		if pg.ctrl_pressed or pg.meta_pressed:
			_zoom_at(pg.position, 1.0 - pg.delta.y * 0.05)
		else:
			pan -= pg.delta * 18.0
			canvas.queue_redraw()
	elif ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(mb.position, 1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_LEFT and space_down:
			panning = mb.pressed
		elif (mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT) and _object_tool():
			_object_press(mb)
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			var c := _cell_at(mb.position)
			if not mb.pressed:
				if rect_from.x >= 0:
					_apply_rect(rect_from, c if _can_grow() else c.clamp(Vector2i.ZERO, Vector2i(grid_size - 1, grid_size - 1)))
					rect_from = Vector2i(-1, -1)
				painting = false
				canvas.queue_redraw()
				return
			erasing = mb.button_index == MOUSE_BUTTON_RIGHT
			if mb.alt_pressed and not erasing and tool.begins_with("paint:"):
				_eyedrop(c)
				return
			if not _in_grid(c) and not _can_grow(): return
			_push_undo()
			stroke_seed = randi()
			var m := "brush" if tool.begins_with("mark:") else ("rect" if tool == "gen" else _mode_now())
			if m == "fill" and not _in_grid(c): m = "brush"
			if m == "fill": _apply_cells(_flood_cells(c))
			elif m == "rect": rect_from = c
			else:
				painting = true
				_apply(c)
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		mouse_px = mm.position
		if panning:
			pan += mm.relative
		elif drag != "":
			_object_drag(mm.position)
		elif painting and tool == "mark:spawn" and not erasing:
			_face_spawn(mm.position)                # drag from the spawn marker to turn where the player looks
		elif painting:
			_apply(_cell_at(mm.position))
		var c := _cell_at(mm.position)
		hover = c if _in_grid(c) else Vector2i(-1, -1)
		hover_raw = c
		hover_obj = _obj_at(mm.position) if _object_tool() and show_objects and drag == "" else -1
		canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
		if _object_tool() and (_on_handle(mm.position) or drag == "rotate"):
			canvas.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		elif _object_tool() and (hover_obj >= 0 or drag == "move"):
			canvas.mouse_default_cursor_shape = Control.CURSOR_MOVE
		if drag != "" and selected >= 0:
			_status(_describe(objects[selected]))
		elif hover_obj >= 0:
			_status(_describe(objects[hover_obj]) + "   click to select, drag to move, right click deletes")
		elif hover.x >= 0:
			_status(_describe_cell(hover))
		canvas.queue_redraw()

## The status line for a cell: where it is, what its surfaces are made of (painted or the level's) and its zones
func _describe_cell(c: Vector2i) -> String:
	var bits := ["cell %d, %d" % [c.x, c.y]]
	var slots := ["wall"] if grid[c.y][c.x] == WALL else (["pit"] if grid[c.y][c.x] == PIT else ["floor", "ceiling"])
	for slot in slots:
		if slot == "pit":
			bits.append("pit")
			continue
		bits.append("%s: %s%s" % [slot, _nice_key(_surface_key(slot, c)), " (painted)" if paint[slot].has(c) else ""])
	var tags := []
	for z in ZONES:
		if zones[z].has(c): tags.append(z)
	if not tags.is_empty(): bits.append("zones: " + ", ".join(tags))
	return "    ".join(bits)

func _brush_cells(c: Vector2i) -> Array:
	var out: Array = []
	var half := brush / 2
	for dz in brush:
		for dx in brush:
			out.append(c + Vector2i(dx - half, dz - half))
	return out

func _rect_cells(a: Vector2i, b: Vector2i) -> Array:
	var out: Array = []
	for z in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
		for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
			out.append(Vector2i(x, z))
	return out

## The area a fill click covers: cells joined side by side to `start` that look the same to the current tool
## (same terrain, same zone state, or the same material on that surface). Wall paint clicked on a floor
## cell does the walls round the whole open area instead: "paint this room's walls".
func _flood_cells(start: Vector2i) -> Array:
	var kind := tool.get_slice(":", 0)
	var what := tool.get_slice(":", 1)
	var room_walls: bool = kind == "paint" and what == "wall" and grid[start.y][start.x] != WALL
	var key := func(c: Vector2i) -> String:
		var wall: bool = grid[c.y][c.x] == WALL
		if room_walls: return "open" if not wall else "stop"
		match kind:
			"base": return grid[c.y][c.x]
			"zone": return "stop" if wall else str(zones[what].has(c))
			"paint":
				if (what == "wall") != wall: return "stop"
				return _surface_key(what, c)
		return "stop"
	var want: String = key.call(start)
	if want == "stop": return []
	var seen := {start: true}
	var todo: Array = [start]
	while not todo.is_empty():
		var c: Vector2i = todo.pop_back()
		for d: Vector2i in DIRS4:
			var n: Vector2i = c + d
			if n.x < 1 or n.y < 1 or n.x >= grid_size - 1 or n.y >= grid_size - 1 or seen.has(n): continue
			if key.call(n) == want:
				seen[n] = true
				todo.append(n)
	if not room_walls: return seen.keys()
	var walls := {}
	for c: Vector2i in seen:
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var n := c + Vector2i(dx, dz)
				if _in_grid(n) and grid[n.y][n.x] == WALL: walls[n] = true
	return walls.keys()

func _face_spawn(px: Vector2) -> void:
	var c = markers.get("spawn")
	if c == null: return
	var v := px - (pan + (Vector2(c) + Vector2(0.5, 0.5)) * zoom)
	if v.length() < maxf(zoom * 0.6, 10.0): return
	var a := snappedf(fposmod(rad_to_deg(v.angle()), 360.0), 15.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	if not is_equal_approx(a, spawn_rot):
		spawn_rot = fposmod(a, 360.0)
		_mark_dirty()
		_status("Player looks %d°   (hold Shift to snap to 15°)" % roundi(spawn_rot))
		canvas.queue_redraw()

func _apply(c: Vector2i) -> void:
	if tool.begins_with("mark:"):
		if c.x >= 1 and c.y >= 1 and c.x < grid_size - 1 and c.y < grid_size - 1:
			markers[tool.get_slice(":", 1)] = null if erasing else c
		_mark_dirty()
		return
	_apply_cells(_brush_cells(c))

func _apply_cells(cells: Array) -> void:
	var kind := tool.get_slice(":", 0)
	var what := tool.get_slice(":", 1)
	if _can_grow() and not erasing:
		var off := _grow_to(cells)
		if off != Vector2i.ZERO: cells = cells.map(func(c): return c + off)
	for p: Vector2i in cells:
		if kind == "paint" and what == "wall":
			if not _in_grid(p) or grid[p.y][p.x] != WALL: continue      # the border walls can be painted too
		elif p.x < 1 or p.y < 1 or p.x >= grid_size - 1 or p.y >= grid_size - 1: continue
		if kind == "base":
			grid[p.y][p.x] = (FLOOR if what == WALL else WALL) if erasing else what
			if grid[p.y][p.x] == WALL:      # solid cells: the game drops any zone tag on load
				for z in zones: zones[z].erase(p)
		elif kind == "paint":
			if what != "wall" and grid[p.y][p.x] == WALL: continue
			if erasing: paint[what].erase(p)
			elif paint_mat != "":
				var hv := absi(hash([p, stroke_seed]))
				if scatter < 100 and hv % 100 >= scatter: continue
				var mix: Array = [paint_mat] + paint_mix
				paint[what][p] = mix[(hv / 100) % mix.size()]
		elif kind == "zone" and grid[p.y][p.x] != WALL:
			if erasing: zones[what].erase(p)
			else: zones[what][p] = true
	_mark_dirty()

## A dragged rectangle: the generator's area, a room when auto walls is on (floor inside a wall ring), or
## just every cell in it
func _apply_rect(a: Vector2i, b: Vector2i) -> void:
	var cells := _rect_cells(a, b)
	if tool == "gen":
		var off := _grow_to(cells)
		_generate(Rect2i(a.min(b) + off, (a - b).abs() + Vector2i.ONE))
		return
	var room := auto_walls and tool == "base:" + FLOOR and not erasing and absi(a.x - b.x) >= 2 and absi(a.y - b.y) >= 2
	if not room:
		_apply_cells(cells)
		return
	var off := _grow_to(cells)
	var lo := a.min(b) + off
	var hi := a.max(b) + off
	for p: Vector2i in _rect_cells(lo, hi):
		if p.x < 1 or p.y < 1 or p.x >= grid_size - 1 or p.y >= grid_size - 1: continue
		var ring := p.x == lo.x or p.y == lo.y or p.x == hi.x or p.y == hi.y
		grid[p.y][p.x] = WALL if ring else FLOOR
		if ring:
			for z in zones: zones[z].erase(p)
	_mark_dirty()
	_status("Room %d x %d with walls round it (auto walls). Carve doorways with the Floor brush" % [hi.x - lo.x - 1, hi.y - lo.y - 1])

## level_editor_gen.gd
func _generate(_area: Rect2i) -> void:
	pass

## Take the material under the mouse into the brush (I, or Alt+click with a paint tool)
func _eyedrop(c: Vector2i) -> void:
	if not _in_grid(c): return
	var slot := "wall"
	if grid[c.y][c.x] != WALL:
		slot = "ceiling" if view_ceiling or tool == "paint:ceiling" else "floor"
	var k := _surface_key(slot, c)
	if k.begins_with("default:") or k == "":
		_status("The %s here is the game's default look: nothing to pick" % slot)
		return
	_set_paint_mat(k)
	_select_tool("paint:" + slot)
	_status("Picked %s from the %s" % [k, slot])

## Overridden by level_editor.gd, which also updates the buttons
func _select_tool(id: String) -> void:
	tool = id

func _set_paint_mat(id: String) -> void:
	paint_mat = id

# ---------------------------------------------------------------- undo
# ---------------------------------------------------------------- floors
func _live_floor() -> Dictionary:
	return {"grid": grid, "zones": zones, "paint": paint, "markers": markers, "objects": objects}

func _load_floor(fd: Dictionary) -> void:
	grid = fd.grid
	zones = fd.zones
	paint = fd.paint
	markers = fd.markers
	objects = fd.objects

func _copy_floor(fd: Dictionary) -> Dictionary:
	var z := {}
	for k in fd.zones: z[k] = fd.zones[k].duplicate()
	var pt := {}
	for k in fd.paint: pt[k] = fd.paint[k].duplicate()
	return {"grid": fd.grid.duplicate(true), "zones": z, "paint": pt, "markers": fd.markers.duplicate(), "objects": fd.objects.duplicate(true)}

## A new floor: solid everywhere (draw its rooms in), no zones, paint, markers or objects
func _new_floor() -> Dictionary:
	var g: Array = []
	for z in grid_size:
		var row := []
		row.resize(grid_size)
		row.fill(WALL)
		g.append(row)
	var zd := {}
	for z in ZONES: zd[z] = {}
	var mk := {}
	for m in MARKERS: mk[m] = null
	return {"grid": g, "zones": zd, "paint": {"wall": {}, "floor": {}, "ceiling": {}}, "markers": mk, "objects": []}

## Every floor, the live one included: int -> its fields
func _all_floors() -> Dictionary:
	var all := floor_store.duplicate()
	all[floor_idx] = _live_floor()
	return all

func _floor_numbers() -> Array:
	var ks: Array = _all_floors().keys()
	ks.sort()
	return ks

func _floor_name(f: int) -> String:
	if f == 0: return "Ground floor"
	return ("Floor %d" % f) if f > 0 else ("Basement %d" % -f)

func _switch_floor(f: int) -> void:
	if f == floor_idx or not floor_store.has(f): return
	floor_store[floor_idx] = _live_floor()
	_load_floor(floor_store[f])
	floor_store.erase(f)
	floor_idx = f
	selected = -1
	hover_obj = -1
	drag = ""
	rect_from = Vector2i(-1, -1)
	_floors_changed()
	_sync_inspector()
	if preview3d != null and preview3d.visible: preview3d.mark_stale()
	_update_info()
	canvas.queue_redraw()
	_status("Editing " + _floor_name(f))

## Overridden by level_editor.gd to refresh the floor picker
func _floors_changed() -> void:
	pass

# ---------------------------------------------------------------- growing the map
## Re-lay every floor on an n x n grid with its old cell (x, z) at (x, z) + off. Cells, zones, paint,
## markers and objects that end up outside are dropped; the new border is wall.
func _reframe(n: int, off: Vector2i) -> void:
	var all := _all_floors()
	var inner := func(c: Vector2i) -> bool: return c.x >= 1 and c.y >= 1 and c.x < n - 1 and c.y < n - 1
	for f in all:
		var fd: Dictionary = all[f]
		var ng: Array = []
		for z in n:
			var row := []
			for x in n:
				var o := Vector2i(x, z) - off
				var inside := o.x >= 0 and o.y >= 0 and o.x < grid_size and o.y < grid_size
				var edge := x == 0 or z == 0 or x == n - 1 or z == n - 1
				row.append(WALL if edge or not inside else fd.grid[o.y][o.x])
			ng.append(row)
		fd.grid = ng
		for k in fd.zones:
			var moved := {}
			for c: Vector2i in fd.zones[k]:
				if inner.call(c + off): moved[c + off] = true
			fd.zones[k] = moved
		for k in fd.paint:
			var moved := {}
			for c: Vector2i in fd.paint[k]:
				var d: Vector2i = c + off
				if d.x >= 0 and d.y >= 0 and d.x < n and d.y < n: moved[d] = fd.paint[k][c]
			fd.paint[k] = moved
		for m in fd.markers:
			var c = fd.markers[m]
			if c != null: fd.markers[m] = (c + off) if inner.call(c + off) else null
		var kept: Array = []
		for o: Dictionary in fd.objects:
			o.pos_x += off.x
			o.pos_y += off.y
			if o.pos_x >= 0 and o.pos_y >= 0 and o.pos_x <= n - 1 and o.pos_y <= n - 1: kept.append(o)
		fd.objects = kept
	grid_size = n
	for f in all:
		if f == floor_idx: _load_floor(all[f])
		else: floor_store[f] = all[f]
	selected = -1
	_sync_inspector()

## Drawing outside the map grows it (every floor) so `cells` land inside with a wall border round them.
## Returns how far existing cells moved (drawing above / left of the map shifts everything down / right).
func _grow_to(cells: Array) -> Vector2i:
	if cells.is_empty(): return Vector2i.ZERO
	var mn := Vector2i(1, 1)
	var mx := Vector2i(grid_size - 2, grid_size - 2)
	for c: Vector2i in cells:
		mn = mn.min(c)
		mx = mx.max(c)
	if mn.x >= 1 and mn.y >= 1 and mx.x <= grid_size - 2 and mx.y <= grid_size - 2:
		return Vector2i.ZERO
	var off := Vector2i(maxi(0, 1 - mn.x), maxi(0, 1 - mn.y))
	var n := maxi(grid_size + maxi(off.x, off.y), maxi(mx.x, mx.y) + maxi(off.x, off.y) + 2)
	if n > MAX_SIZE:
		_status("The map can't grow past %d x %d" % [MAX_SIZE, MAX_SIZE])
		n = MAX_SIZE
	_reframe(n, off)
	pan -= Vector2(off) * zoom                  # the map moves under the mouse, not the view
	if rect_from.x >= 0: rect_from += off
	_status("Map grown to %d x %d" % [grid_size, grid_size])
	return off

## Tools that may draw outside the map (and so grow it)
func _can_grow() -> bool:
	return tool == "base:" + FLOOR or tool == "base:" + PIT or tool == "gen"

## Shrink every floor to what is used (open cells and markers) plus a wall border
func _trim() -> void:
	var mn := Vector2i(grid_size, grid_size)
	var mx := Vector2i(-1, -1)
	var all := _all_floors()
	for f in all:
		var fd: Dictionary = all[f]
		for z in grid_size:
			for x in grid_size:
				if fd.grid[z][x] != WALL:
					mn = mn.min(Vector2i(x, z))
					mx = mx.max(Vector2i(x, z))
		for m in fd.markers:
			if fd.markers[m] != null:
				mn = mn.min(fd.markers[m])
				mx = mx.max(fd.markers[m])
	if mx.x < 0:
		_status("Nothing to trim to: the level has no open floor")
		return
	_push_undo()
	var n := maxi(maxi(mx.x - mn.x, mx.y - mn.y) + 3, 8)
	_reframe(n, Vector2i(1, 1) - mn)
	_mark_dirty()
	_fit()
	_status("Trimmed to %d x %d" % [n, n])

# ---------------------------------------------------------------- undo
## Undo steps hold the whole level (every floor): growing the map or adding a floor touches them all
func _snapshot() -> Dictionary:
	var fl := {}
	var all := _all_floors()
	for f in all: fl[f] = _copy_floor(all[f])
	return {"floors": fl, "floor": floor_idx, "size": grid_size, "selected": selected}

func _restore(s: Dictionary) -> void:
	floor_store = s.floors
	floor_idx = s.floor
	_load_floor(floor_store[floor_idx])
	floor_store.erase(floor_idx)
	grid_size = s.size
	selected = s.selected if s.selected < objects.size() else -1
	drag = ""
	_floors_changed()
	_sync_inspector()
	_mark_dirty()

func _push_undo() -> void:
	undo_stack.append(_snapshot())
	if undo_stack.size() > 80: undo_stack.pop_front()
	redo_stack.clear()
	insp_undo = -1

func _undo() -> void:
	if undo_stack.is_empty():
		_status("Nothing to undo")
		return
	redo_stack.append(_snapshot())
	_restore(undo_stack.pop_back())

func _redo() -> void:
	if redo_stack.is_empty():
		_status("Nothing to redo")
		return
	undo_stack.append(_snapshot())
	_restore(redo_stack.pop_back())

# ---------------------------------------------------------------- objects
func _object_tool() -> bool:
	return tool == "select" or tool.begins_with("obj:")

## Canvas pixels -> object space (cells, a cell's centre on a whole number)
func _pos_at(p: Vector2) -> Vector2:
	return (p - pan) / zoom - Vector2(0.5, 0.5)

func _snap_pos(v: Vector2) -> Vector2:
	if snap and not Input.is_key_pressed(KEY_ALT):
		v = (v / SNAP_STEP).round() * SNAP_STEP
	return v.clamp(Vector2.ZERO, Vector2(grid_size - 1, grid_size - 1))

## 90° steps with rotation snap on, otherwise free; Shift steps 15°, Alt ignores snapping
func _snap_rot(deg: float) -> float:
	var step := 1.0
	if Input.is_key_pressed(KEY_SHIFT): step = 15.0
	elif rot_snap and not Input.is_key_pressed(KEY_ALT): step = 90.0
	return fposmod(snappedf(deg, step), 360.0)

## Object space -> canvas pixels. Local x = the way it faces, local y = its span, both in cells * zoom.
func _obj_xf(o: Dictionary) -> Transform2D:
	return Transform2D(deg_to_rad(o.rotation), pan + (Vector2(o.pos_x, o.pos_y) + Vector2(0.5, 0.5)) * zoom)

## Footprint depth along local x, in cells (at least a few pixels, so thin pieces stay clickable)
func _obj_depth(o: Dictionary) -> float:
	return maxf(_cells(o.type, "thickness", 0.3), 4.0 / zoom)

func _obj_at(p: Vector2) -> int:
	for i in range(objects.size() - 1, -1, -1):
		var o: Dictionary = objects[i]
		var l := (_obj_xf(o).affine_inverse() * p) / zoom
		if absf(l.x) <= maxf(_obj_depth(o) * 0.5, 6.0 / zoom) and absf(l.y) <= o.scale * 0.5 + 2.0 / zoom:
			return i
	return -1

## The rotate handle: a knob just past the facing arrow's tip
func _handle_px(o: Dictionary) -> Vector2:
	var xf := _obj_xf(o)
	return xf.origin + xf.x.normalized() * (_obj_depth(o) * 0.5 * zoom + maxf(zoom * 0.8, 26.0) + 9.0)

func _on_handle(p: Vector2) -> bool:
	return selected >= 0 and p.distance_to(_handle_px(objects[selected])) <= 9.0

## Wall-aware placement. On a cell edge a piece lines up with that edge; square on a cell it spans the
## corridor or wall run it lands in (you walk through it the way the open neighbours lie, like the game's
## old tiles did). Of the two ways to face along that axis it keeps the one nearer `cur`, so a door keeps
## its swing side. Off, with Alt held, on a cell corner or off the half-cell grid, `cur` stays.
func _wall_align(p: Vector2, cur: float) -> float:
	if not align or Input.is_key_pressed(KEY_ALT): return cur
	var whole := func(v: float) -> bool: return absf(v - roundf(v)) < 0.1
	var half := func(v: float) -> bool: return absf(absf(v - floorf(v)) - 0.5) < 0.1
	var facing := -1.0
	if half.call(p.x) and whole.call(p.y): facing = 0.0            # on a north-south edge: face across it
	elif whole.call(p.x) and half.call(p.y): facing = 90.0
	elif whole.call(p.x) and whole.call(p.y):
		var c := Vector2i(roundi(p.x), roundi(p.y))
		var ew := _open_cell(c + Vector2i(1, 0)) and _open_cell(c + Vector2i(-1, 0))
		var ns := _open_cell(c + Vector2i(0, 1)) and _open_cell(c + Vector2i(0, -1))
		if ew and not ns: facing = 0.0
		elif ns and not ew: facing = 90.0
	if facing < 0.0: return cur
	return facing if absf(angle_difference(deg_to_rad(cur), deg_to_rad(facing))) <= PI / 2.0 else facing + 180.0

func _open_cell(c: Vector2i) -> bool:
	return c.x > 0 and c.y > 0 and c.x < grid_size - 1 and c.y < grid_size - 1 and grid[c.y][c.x] != WALL

func _object_press(mb: InputEventMouseButton) -> void:
	if not mb.pressed:
		if drag != "":
			if selected >= 0 and str(objects[selected].type).begins_with("stairs_") and drag in ["place", "rotate"]:
				_sync_stairs_partner(objects[selected])
			drag = ""
			_sync_inspector()
		return
	var i := _obj_at(mb.position)
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		if i >= 0:
			_push_undo()
			_delete_object(i)
		return
	if _on_handle(mb.position):
		_push_undo()
		drag = "rotate"
	elif i >= 0:
		_select(i)
		_push_undo()
		var o: Dictionary = objects[i]
		drag_off = Vector2(o.pos_x, o.pos_y) - _pos_at(mb.position)
		drag = "move"
	elif tool == "select":
		_select(-1)
	else:
		_push_undo()
		var p := _snap_pos(_pos_at(mb.position))
		objects.append({"type": tool.get_slice(":", 1), "pos_x": p.x, "pos_y": p.y, "rotation": _wall_align(p, place_rot), "scale": place_scale})
		if tool.begins_with("obj:stairs_"):
			objects[-1].pos_x = roundf(p.x)          # stairs fill a whole cell
			objects[-1].pos_y = roundf(p.y)
			objects[-1].scale = 1.0
			_link_stairs(objects[-1])
		_select(objects.size() - 1)
		drag = "place"                   # keep the button down and drag away to aim it
		_mark_dirty()

## Stairs join two floors. The new flight's cell is made right for it (floor under stairs up, a pit for stairs
## down) and the floor it leads to gets the opposite flight at the same spot, with open floor to arrive on
## beside it; that floor is created if the level doesn't have it yet.
func _link_stairs(o: Dictionary) -> void:
	var up: bool = o.type == "stairs_up"
	var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
	var dir := Vector2i(Vector2.from_angle(deg_to_rad(o.rotation)).round())
	if not _in_grid(c): return
	grid[c.y][c.x] = FLOOR if up else PIT
	if _in_grid(c - dir) and grid[c.y - dir.y][c.x - dir.x] == WALL: grid[c.y - dir.y][c.x - dir.x] = FLOOR
	var f := floor_idx + (1 if up else -1)
	var created := false
	if not floor_store.has(f):
		floor_store[f] = _new_floor()
		created = true
		_floors_changed()
	var fd: Dictionary = floor_store[f]
	var kind := "stairs_down" if up else "stairs_up"
	for other: Dictionary in fd.objects:
		if other.type == kind and Vector2(other.pos_x, other.pos_y).distance_to(Vector2(o.pos_x, o.pos_y)) < 1.5:
			_status("Linked to the %s already on %s" % [kind.replace("_", " "), _floor_name(f)])
			return
	fd.objects.append({"type": kind, "pos_x": o.pos_x, "pos_y": o.pos_y, "rotation": o.rotation, "scale": 1.0})
	fd.grid[c.y][c.x] = PIT if up else FLOOR
	var a := c - dir                               # where you arrive on that floor: open it, and a little landing
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var n := a + Vector2i(dx, dz)
			if n.x >= 1 and n.y >= 1 and n.x < grid_size - 1 and n.y < grid_size - 1 and n != c and fd.grid[n.y][n.x] == WALL:
				fd.grid[n.y][n.x] = FLOOR
	_status("%s%s got the matching %s here (PageUp / PageDown to go there)" % [("Made " if created else ""), _floor_name(f), kind.replace("_", " ")])

## A flight was turned: turn its partner on the next floor the same way (arrival stays beside it)
func _sync_stairs_partner(o: Dictionary) -> void:
	var f := floor_idx + (1 if o.type == "stairs_up" else -1)
	if not floor_store.has(f): return
	var kind := "stairs_down" if o.type == "stairs_up" else "stairs_up"
	var fd: Dictionary = floor_store[f]
	for other: Dictionary in fd.objects:
		if other.type == kind and Vector2(other.pos_x, other.pos_y).distance_to(Vector2(o.pos_x, o.pos_y)) < 1.5:
			other.rotation = o.rotation
			var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
			var a := c - Vector2i(Vector2.from_angle(deg_to_rad(o.rotation)).round())
			for g in [grid, fd.grid]:                  # both floors: open where you step off
				if a.x >= 1 and a.y >= 1 and a.x < grid_size - 1 and a.y < grid_size - 1 and g[a.y][a.x] == WALL:
					g[a.y][a.x] = FLOOR
			_mark_dirty()
			return

func _object_drag(p: Vector2) -> void:
	if selected < 0:
		drag = ""
		return
	var o: Dictionary = objects[selected]
	if drag == "move":
		var q := _snap_pos(_pos_at(p) + drag_off)
		o.pos_x = q.x
		o.pos_y = q.y
		if is_zero_approx(fposmod(o.rotation, 90.0)):      # a piece hand-turned off the grid axes keeps its angle
			o.rotation = _wall_align(q, o.rotation)
	else:
		var v := p - _obj_xf(o).origin
		if drag == "place" and v.length() < maxf(zoom * 0.5, 12.0): return    # a plain click keeps place_rot
		o.rotation = _snap_rot(rad_to_deg(v.angle()))
		place_rot = o.rotation
	_sync_inspector()
	_mark_dirty()

func _select(i: int) -> void:
	selected = i
	insp_undo = -1
	_sync_inspector()
	canvas.queue_redraw()

func _delete_object(i: int) -> void:
	objects.remove_at(i)
	if selected == i: selected = -1
	elif selected > i: selected -= 1
	hover_obj = -1
	_sync_inspector()
	_mark_dirty()

func _delete_selected() -> void:
	if selected < 0: return
	_push_undo()
	_delete_object(selected)

func _duplicate_selected() -> void:
	if selected < 0: return
	_push_undo()
	var o: Dictionary = objects[selected].duplicate()
	var off := SNAP_STEP if snap else 0.25
	o.pos_x = minf(o.pos_x + off, grid_size - 1)
	o.pos_y = minf(o.pos_y + off, grid_size - 1)
	objects.append(o)
	_select(objects.size() - 1)
	_mark_dirty()

## R / Shift+R and the inspector's buttons: turn the selection, or the next placement when nothing is selected
func _rotate_selected(deg: float) -> void:
	if selected < 0:
		place_rot = fposmod(place_rot + deg, 360.0)
		_status("placing at %s°" % _deg(place_rot))
		canvas.queue_redraw()
		return
	_push_undo()
	var o: Dictionary = objects[selected]
	o.rotation = fposmod(o.rotation + deg, 360.0)
	place_rot = o.rotation
	_sync_inspector()
	_mark_dirty()

## An inspector field changed. One undo step per object per round of edits, not one per keystroke.
func _set_prop(key: String, v) -> void:
	if selected < 0: return
	if insp_undo != selected:
		_push_undo()
		insp_undo = selected
	var o: Dictionary = objects[selected]
	o[key] = v
	match key:
		"rotation":
			o.rotation = fposmod(v, 360.0)
			place_rot = o.rotation
			insp_rot.set_value_no_signal(o.rotation)
		"scale":
			place_scale = v
	_mark_dirty()

func _sync_inspector() -> void:
	if insp == null: return
	insp.get_parent().visible = selected >= 0
	if selected < 0: return
	var o: Dictionary = objects[selected]
	insp_type.select(OBJ_TYPES.find(o.type))
	for sb: SpinBox in [insp_x, insp_y]: sb.max_value = grid_size - 1
	insp_x.set_value_no_signal(o.pos_x)
	insp_y.set_value_no_signal(o.pos_y)
	insp_rot.set_value_no_signal(o.rotation)
	insp_scale.set_value_no_signal(o.scale)

func _deg(d: float) -> String:
	return str(snappedf(d, 0.1)).trim_suffix(".0")

func _describe(o: Dictionary) -> String:
	return "%s   x %.2f   y %.2f   rotation %s°   width %.2f" % [_info(o.type).label, o.pos_x, o.pos_y, _deg(o.rotation), o.scale]

## A rectangle in the object's local space (cells), as canvas points
func _local_rect(xf: Transform2D, x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([xf * (Vector2(x0, y0) * zoom), xf * (Vector2(x1, y0) * zoom), xf * (Vector2(x1, y1) * zoom), xf * (Vector2(x0, y1) * zoom)])

func _fill(pts: PackedVector2Array, col: Color) -> void:
	canvas.draw_colored_polygon(pts, col)
	canvas.draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0, 0, 0, col.a * 0.8), 1.0)

## Plan view of an object, the way an architect's floor plan draws it
func _draw_object(o: Dictionary, alpha: float) -> void:
	var xf := _obj_xf(o)
	var col: Color = _info(o.type).col
	col.a = alpha
	var half: float = o.scale * 0.5
	var t := maxf(_cells(o.type, "thickness", 0.3), 5.0 / zoom)
	match o.type:
		"door":
			# the partition either side of the doorway, the leaf (closed) and its swing either way
			var door_c := _cells("door", "opening", 1.12)
			var dw := door_c * 0.5
			var wall_col := Color(_info("thin_wall").col, alpha)
			_fill(_local_rect(xf, -t * 0.5, -half, t * 0.5, -dw), wall_col)
			_fill(_local_rect(xf, -t * 0.5, dw, t * 0.5, half), wall_col)
			var hinge := xf * (Vector2(0, -dw) * zoom)
			canvas.draw_line(hinge, xf * (Vector2(0, dw) * zoom), col, maxf(2.0, zoom * 0.04))
			var a := deg_to_rad(o.rotation)
			canvas.draw_arc(hinge, door_c * zoom, a, a + PI, 24, Color(col, alpha * 0.8), 1.5)
		"arch":
			# two pillars and the passage between them, dashed where the crown spans it
			var p := _cells("arch", "pillar", 0.75)
			var d := t * 0.5
			_fill(_local_rect(xf, -d, -half, d, -half + p), col)
			_fill(_local_rect(xf, -d, half - p, d, half), col)
			for s: float in [-d, d]:
				canvas.draw_dashed_line(xf * (Vector2(s, -half + p) * zoom), xf * (Vector2(s, half - p) * zoom),
					Color(col, alpha * 0.8), 1.5, maxf(zoom * 0.12, 3.0))
		"stairs_up", "stairs_down":
			# the flight seen from above: its treads across the run, the far end (top / bottom) darker
			var d := 0.5
			_fill(_local_rect(xf, -d, -half, d, half), Color(col, alpha * 0.85))
			for i in range(1, 12):
				var x := -d + i / 12.0
				canvas.draw_line(xf * (Vector2(x, -half) * zoom), xf * (Vector2(x, half) * zoom), Color(0, 0, 0, alpha * 0.45), 1.0)
			_fill(_local_rect(xf, d - 0.12, -half, d, half), Color(0, 0, 0, alpha * 0.8))
			if zoom >= 12.0:
				var lbl := "UP" if o.type == "stairs_up" else "DN"
				var fs := int(clampf(zoom * 0.35, 9, 18))
				var p := xf.origin - Vector2(font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x * 0.5, -fs * 0.35)
				canvas.draw_string(font, p, lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, alpha))
			_draw_arrow(o, Color(1, 1, 1, alpha * 0.8))
			_draw_stairs_transition(o, xf, alpha)
		_:
			# thin walls, and any type the editor has no plan drawing for: a slab its thickness by its width
			_fill(_local_rect(xf, -t * 0.5, -half, t * 0.5, half), col)

func _draw_stairs_transition(o: Dictionary, xf: Transform2D, alpha: float) -> void:
	var up: bool = o.type == "stairs_up"
	var target_f: int = floor_idx + (1 if up else -1)
	var linked := false
	if floor_store.has(target_f):
		var fd: Dictionary = floor_store[target_f]
		var kind: String = "stairs_down" if up else "stairs_up"
		for other: Dictionary in fd.get("objects", []):
			if other.type == kind and Vector2(other.pos_x, other.pos_y).distance_to(Vector2(o.pos_x, o.pos_y)) < 1.8:
				linked = true
				break
	if zoom >= 10.0:
		var symbol := "▲" if up else "▼"
		var text := "%s TO %s [%s]" % [symbol, _floor_name(target_f).to_upper(), "LINKED" if linked else "UNLINKED"]
		var tag_col: Color = Color("2fd968") if linked else Color("ff9922")
		_tag(xf.origin + Vector2(-48, -maxf(zoom * 0.85, 14.0)), text, Color(tag_col, alpha), 9)
		if linked:
			canvas.draw_arc(xf.origin, maxf(zoom * 0.55, 8.0), 0, TAU, 16, Color(tag_col, alpha * 0.6), 1.5)

func _draw_outline(o: Dictionary, col: Color, width: float) -> void:
	var pad := 3.0 / zoom
	var hx := _obj_depth(o) * 0.5 + pad
	var hy: float = o.scale * 0.5 + pad
	var pts := _local_rect(_obj_xf(o), -hx, -hy, hx, hy)
	canvas.draw_polyline(pts + PackedVector2Array([pts[0]]), col, width)

## The facing arrow, out of the front along local +x (the way you walk through it)
func _draw_arrow(o: Dictionary, col: Color) -> void:
	var xf := _obj_xf(o)
	var dir := xf.x.normalized()
	var tip := xf.origin + dir * (_obj_depth(o) * 0.5 * zoom + maxf(zoom * 0.8, 26.0))
	var side := dir.orthogonal() * 5.0
	var head := PackedVector2Array([tip, tip - dir * 10.0 + side, tip - dir * 10.0 - side])
	canvas.draw_line(xf.origin, tip - dir * 6.0, Color(0, 0, 0, col.a * 0.7), 4.0)     # dark underlay for contrast
	canvas.draw_polyline(head + PackedVector2Array([head[0]]), Color(0, 0, 0, col.a * 0.7), 3.0)
	canvas.draw_line(xf.origin, tip - dir * 6.0, col, 2.0)
	canvas.draw_colored_polygon(head, col)

## Selection gizmo: bounding box, facing arrow, rotate handle with its angle, pivot, and a door's hinge
func _draw_gizmo(o: Dictionary) -> void:
	_draw_outline(o, Color(0, 0, 0, 0.7), 4.0)
	_draw_outline(o, SEL, 2.0)
	_draw_arrow(o, SEL)
	var h := _handle_px(o)
	var hot := drag == "rotate" or _on_handle(mouse_px)
	canvas.draw_circle(h, 6.0, Color.WHITE if hot else SEL)
	canvas.draw_arc(h, 6.0, 0, TAU, 16, Color.BLACK, 1.5)
	var label := "%s°" % _deg(o.rotation)
	var lp := h + Vector2(10, -8)
	canvas.draw_rect(Rect2(lp + Vector2(-3, -13), font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13) + Vector2(6, 4)), Color(0, 0, 0, 0.75))
	canvas.draw_string(font, lp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, SEL)
	var xf := _obj_xf(o)
	if o.type == "door":
		canvas.draw_circle(xf * (Vector2(0, -_cells("door", "opening", 1.12) * 0.5) * zoom), 3.0, Color.WHITE)
	canvas.draw_circle(xf.origin, 2.5, SEL)

func _status(t: String) -> void:
	if status: status.text = t
