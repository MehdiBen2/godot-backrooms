extends Window
## The mannequin pose editor: a window of the level editor (the stick-figure button in the toolbar). Poses are drawn
## with sliders on a 3D mannequin, named, sorted by what they are for and saved to the game's
## levels/mannequin_poses.json, which the game (scripts/Entities/mannequin/mannequin_model.gd) mixes in with its own
## generated poses:
##   Walking   a stride: it snaps into the pose on a step and into its mirror on the next, so the legs alternate
##   Stalking  a close-in step (the lunge at you, arms out): used more often the nearer it gets
##   Standing  a still decoy's pose in the crowd
## The preview is the jointed mannequin (creepy_mannequin.glb), posed with the same joints and the same maths as the
## game's mannequin_model.gd part_transforms(): the other sculpts in the crowd are posed from the same numbers.
##   left drag turns the figure, wheel zooms, right / middle drag pans, Ctrl+S saves

const POSES_FILE := "levels/mannequin_poses.json"
const MODEL_FILE := "models/entities/creepy_mannequin.glb"
const HEIGHT := 1.85
const KEYS := ["legL", "legR", "armL", "armR", "splayL", "splayR", "rollL", "rollR", "headYaw", "headTilt", "headNod", "lean", "twist", "bob"]
## [kind, shown name, what it is for]
const KINDS := [
	["walk", "Walking", "A stride. The mannequin snaps into it on a step and into its mirror on the next, so the legs alternate: draw one side forward."],
	["stalk", "Stalking", "A close-in step: the lunge at you. Used more and more often the nearer it gets. Arms out, head fixed on you."],
	["stand", "Standing", "A still pose for the mannequins standing in the crowd (and the real one, when it stops)."],
]
## [pose key, shown name, min, max]
const SLIDERS := [
	["legL", "Left leg", -1.2, 1.2], ["legR", "Right leg", -1.2, 1.2],
	["armL", "Left arm", -0.8, 3.0], ["armR", "Right arm", -0.8, 3.0],
	["splayL", "Left arm out", -0.4, 1.4], ["splayR", "Right arm out", -0.4, 1.4],
	["headYaw", "Head turn", -1.5, 1.5], ["headTilt", "Head tilt", -0.8, 0.8], ["headNod", "Head nod", -0.6, 0.6],
	["lean", "Lean forward", -0.4, 0.6], ["twist", "Torso twist", -0.6, 0.6],
]
const BG := Color("17181b")
const PANEL := Color("1f2023")
const TEXT := Color("d6d8dd")
const DIM := Color("8b8f98")
const ACCENT := Color("4c9eff")
const SNAP_TIME := 0.11                    # s a step takes to snap into its pose (the game's)
const PLAY_STEP := 0.55                    # s between the strides of the preview

var game := ""                             # the game's folder
var poses: Array = []                      # {name, kind, pose: {key: float}}
var shown: Array = []                      # the indices into poses of what the list shows
var cur := -1                              # the pose being edited
var dirty := false

var _built := false
var _loading := false                      # the sliders are being set from a pose: their changes are not edits
var _kind_pick: OptionButton
var _kind_help: Label
var _list: ItemList
var _name_edit: LineEdit
var _status: Label
var _play_btn: Button
var _sliders := {}                         # key -> HSlider
var _values := {}                          # key -> its number Label
var _edit_widgets: Array = []              # whatever goes dead while no pose is picked
var _confirm: ConfirmationDialog

# the 3D view
var _vp: SubViewport
var _cam: Camera3D
var _figure: Node3D
var _yaw := 0.55
var _pitch := 0.12
var _dist := 3.4
var _target := Vector3(0.0, 0.95, 0.0)
var _part_nodes: Array = []

# the figure (a port of the game's MannequinModel.load_template)
var _parts: Array = []
var _hip_pivot := Vector3.ZERO
var _norm_xf := Transform3D.IDENTITY
var _top_x := Vector2.ZERO
var _model_ok := false

# the preview of a stride
var _playing := false
var _play_t := 0.0
var _play_flip := 1.0
var _play_from := {}
var _play_to := {}

func _init() -> void:
	title = "Mannequin poses"
	size = Vector2i(1220, 800)
	min_size = Vector2i(940, 620)
	visible = false
	close_requested.connect(_on_close)

## Open the window on the game folder `game_dir` (builds it the first time)
func open(game_dir: String) -> void:
	game = game_dir
	if not _built:
		_built = true
		_build_ui()
		_load_model()
		_load_file()
		_fill_list()
		_select(shown[0] if not shown.is_empty() else -1)
	popup_centered()

# ================================================================= data
static func rest() -> Dictionary:
	var d := {}
	for k in KEYS:
		d[k] = 0.0
	return d

static func mirrored(p: Dictionary) -> Dictionary:
	var m := p.duplicate()
	for pair in [["legL", "legR"], ["armL", "armR"], ["splayL", "splayR"], ["rollL", "rollR"]]:
		m[pair[0]] = p[pair[1]]
		m[pair[1]] = p[pair[0]]
	m.headYaw = -p.headYaw
	m.headTilt = -p.headTilt
	m.twist = -p.twist
	return m

func _load_file() -> void:
	poses.clear()
	dirty = false
	var path := game.path_join(POSES_FILE)
	if not FileAccess.file_exists(path):
		_say("No poses saved yet. NEW makes one; SAVE writes %s." % POSES_FILE)
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (data is Dictionary):
		_say("Could not read %s: it is not valid JSON." % POSES_FILE)
		return
	for e in data.get("poses", []):
		if not (e is Dictionary) or not (e.get("pose") is Dictionary):
			continue
		var p := rest()
		for k in KEYS:
			if e.pose.has(k):
				p[k] = float(e.pose[k])
		poses.append({"name": str(e.get("name", "Pose")), "kind": str(e.get("kind", "walk")), "pose": p})
	_say("%d poses loaded from %s." % [poses.size(), POSES_FILE])

func _save() -> void:
	var out: Array = []
	for p in poses:
		var d := {}
		for k in KEYS:
			d[k] = snappedf(float(p.pose.get(k, 0.0)), 0.001)
		out.append({"name": p.name, "kind": p.kind, "pose": d})
	var f := FileAccess.open(game.path_join(POSES_FILE), FileAccess.WRITE)
	if f == null:
		_say("Could not write %s (error %d)." % [game.path_join(POSES_FILE), FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify({"version": 1, "poses": out}, "\t"))
	f.close()
	dirty = false
	_say("Saved %d poses to %s. The game reads them the next time it starts a level." % [out.size(), POSES_FILE])
	_title_refresh()

func _mark_dirty() -> void:
	dirty = true
	_title_refresh()

func _title_refresh() -> void:
	title = "Mannequin poses" + (" *" if dirty else "")

func _say(text: String) -> void:
	if _status != null:
		_status.text = text

func _kind() -> String:
	return KINDS[_kind_pick.selected][0]

func _kind_label(kind: String) -> String:
	for k in KINDS:
		if k[0] == kind:
			return k[1]
	return kind

# ================================================================= the window
func _label(text: String, size_px := 13, col := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", col)
	return l

func _button(text: String, cb: Callable, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

func _build_ui() -> void:
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG
	bg.add_theme_stylebox_override("panel", sb)
	add_child(bg)
	var split := HSplitContainer.new()
	bg.add_child(split)
	# the 3D view
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	svc.custom_minimum_size = Vector2(500, 400)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	svc.add_child(_vp)
	svc.gui_input.connect(_view_input)
	split.add_child(svc)
	_build_world()
	# the panel
	var side := PanelContainer.new()
	var sb2 := StyleBoxFlat.new()
	sb2.bg_color = PANEL
	sb2.set_content_margin_all(12)
	side.add_theme_stylebox_override("panel", sb2)
	side.custom_minimum_size = Vector2(400, 0)
	split.add_child(side)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)

	box.add_child(_label("MANNEQUIN POSES", 15, ACCENT))
	var kinds := HBoxContainer.new()
	kinds.add_child(_label("For  ", 13, DIM))
	_kind_pick = OptionButton.new()
	_kind_pick.focus_mode = Control.FOCUS_NONE
	for k in KINDS:
		_kind_pick.add_item(k[1])
	_kind_pick.item_selected.connect(func(_i): _kind_changed())
	_kind_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kinds.add_child(_kind_pick)
	box.add_child(kinds)
	_kind_help = _label(KINDS[0][2], 12, DIM)
	_kind_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_kind_help.custom_minimum_size = Vector2(360, 0)
	box.add_child(_kind_help)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 130)
	_list.focus_mode = Control.FOCUS_NONE
	_list.item_selected.connect(func(i): _select(shown[i]))
	box.add_child(_list)
	var row := HBoxContainer.new()
	row.add_child(_button("NEW", _new_pose, "A new pose of this kind"))
	row.add_child(_button("DUPLICATE", _duplicate_pose))
	row.add_child(_button("DELETE", _delete_pose))
	box.add_child(row)
	var name_row := HBoxContainer.new()
	name_row.add_child(_label("Name  ", 13, DIM))
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_changed.connect(_rename)
	name_row.add_child(_name_edit)
	box.add_child(name_row)
	_edit_widgets.append(_name_edit)

	box.add_child(HSeparator.new())
	for s in SLIDERS:
		var r := HBoxContainer.new()
		var l := _label(s[1], 13, TEXT)
		l.custom_minimum_size = Vector2(98, 0)
		r.add_child(l)
		var sl := HSlider.new()
		sl.min_value = s[2]
		sl.max_value = s[3]
		sl.step = 0.01
		sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sl.custom_minimum_size = Vector2(150, 0)
		sl.focus_mode = Control.FOCUS_NONE
		sl.value_changed.connect(_on_slider.bind(s[0]))
		r.add_child(sl)
		var v := _label("0.00", 12, DIM)
		v.custom_minimum_size = Vector2(44, 0)
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		r.add_child(v)
		box.add_child(r)
		_sliders[s[0]] = sl
		_values[s[0]] = v
		_edit_widgets.append(sl)

	box.add_child(HSeparator.new())
	var tools := HBoxContainer.new()
	var mir := _button("MIRROR L / R", _mirror_pose, "Swap the left and right sides of this pose")
	tools.add_child(mir)
	var rst := _button("RESET", _reset_pose, "Back to the neutral standing pose")
	tools.add_child(rst)
	_play_btn = _button("PLAY STRIDE", _toggle_play, "Show the pose and its mirror in turn, snapping between them like the game")
	_play_btn.toggle_mode = true
	tools.add_child(_play_btn)
	box.add_child(tools)
	_edit_widgets.append(mir)
	_edit_widgets.append(rst)
	_edit_widgets.append(_play_btn)
	var views := HBoxContainer.new()
	views.add_child(_label("View  ", 13, DIM))
	for v: Array in [["Front", 0.0], ["Side", PI / 2.0], ["Back", PI], ["3/4", 0.55]]:
		views.add_child(_button(v[0], func(): _look_from(v[1])))
	box.add_child(views)

	box.add_child(HSeparator.new())
	var save := _button("SAVE  (Ctrl+S)", _save, "Writes " + POSES_FILE + " in the game folder")
	save.custom_minimum_size = Vector2(0, 34)
	box.add_child(save)
	_status = _label("", 12, DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(360, 0)
	box.add_child(_status)

func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("1a1b1e")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.58, 0.6, 0.66)
	env.ambient_light_energy = 0.9
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-48.0, 30.0, 0.0)
	key.light_energy = 1.0
	_vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20.0, 210.0, 0.0)
	fill.light_energy = 0.45
	_vp.add_child(fill)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(6.0, 6.0)
	floor_mesh.mesh = plane
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color("2a2c31")
	fm.roughness = 1.0
	floor_mesh.material_override = fm
	_vp.add_child(floor_mesh)
	# a 1 m tape on the floor and a head-height mark, so a pose reads against a size
	var mark := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.02, HEIGHT, 0.02)
	mark.mesh = bm
	mark.position = Vector3(-0.9, HEIGHT * 0.5, -0.5)
	var mm := StandardMaterial3D.new()
	mm.albedo_color = Color("4c9eff")
	mm.emission_enabled = true
	mm.emission = Color("4c9eff")
	mm.emission_energy_multiplier = 0.5
	mark.material_override = mm
	_vp.add_child(mark)
	_cam = Camera3D.new()
	_cam.fov = 40.0
	_cam.current = true
	_vp.add_child(_cam)
	_figure = Node3D.new()
	_vp.add_child(_figure)
	_place_camera()

func _place_camera() -> void:
	if _cam == null:
		return
	var off := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * _dist
	_cam.position = _target + off
	if _cam.is_inside_tree():
		_cam.look_at(_target, Vector3.UP)

func _look_from(yaw: float) -> void:
	_yaw = yaw
	_pitch = 0.1
	_place_camera()

func _view_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var m: InputEventMouseMotion = e
		if m.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_yaw -= m.relative.x * 0.01
			_pitch = clampf(_pitch + m.relative.y * 0.006, -0.6, 1.3)
			_place_camera()
		elif m.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE):
			var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
			_target += (-right * m.relative.x + Vector3.UP * m.relative.y) * _dist * 0.0022
			_target.y = clampf(_target.y, 0.1, 1.9)
			_place_camera()
	elif e is InputEventMouseButton:
		var mb: InputEventMouseButton = e
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(_dist * 0.9, 1.2)
			_place_camera()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(_dist * 1.11, 9.0)
			_place_camera()

func _input(e: InputEvent) -> void:
	if not visible:
		return
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_S and e.ctrl_pressed:
		_save()
		get_viewport().set_input_as_handled()

func _on_close() -> void:
	if not dirty:
		hide()
		return
	if _confirm == null:
		_confirm = ConfirmationDialog.new()
		_confirm.title = "Unsaved poses"
		_confirm.dialog_text = "Save the pose changes before closing?"
		_confirm.ok_button_text = "Save"
		_confirm.cancel_button_text = "Keep editing"
		_confirm.add_button("Discard", true, "discard")
		_confirm.confirmed.connect(func():
			_save()
			hide())
		_confirm.custom_action.connect(func(_a):
			_confirm.hide()
			_load_file()
			_fill_list()
			_select(shown[0] if not shown.is_empty() else -1)
			_title_refresh()
			hide())
		add_child(_confirm)
	_confirm.popup_centered()

# ================================================================= the list
func _kind_changed() -> void:
	_kind_help.text = KINDS[_kind_pick.selected][2]
	_playing = false
	_play_btn.button_pressed = false
	_fill_list()
	_select(shown[0] if not shown.is_empty() else -1)

func _fill_list() -> void:
	var kind := _kind()
	_list.clear()
	shown.clear()
	for i in poses.size():
		if poses[i].kind == kind:
			shown.append(i)
			_list.add_item(poses[i].name)

func _select(i: int) -> void:
	cur = i
	_playing = false
	_play_btn.button_pressed = false
	_loading = true
	var live := i >= 0
	for w in _edit_widgets:
		if w is Button:
			(w as Button).disabled = not live
		elif w is LineEdit:
			(w as LineEdit).editable = live
		elif w is Slider:
			(w as Slider).editable = live
	_play_btn.disabled = not live or _kind() == "stand"
	if live:
		var p: Dictionary = poses[i].pose
		_name_edit.text = poses[i].name
		for s in SLIDERS:
			(_sliders[s[0]] as HSlider).set_value_no_signal(float(p.get(s[0], 0.0)))
			(_values[s[0]] as Label).text = "%.2f" % float(p.get(s[0], 0.0))
		var at := shown.find(i)
		if at >= 0:
			_list.select(at)
		_apply(p)
	else:
		_name_edit.text = ""
		for s in SLIDERS:
			(_sliders[s[0]] as HSlider).set_value_no_signal(0.0)
			(_values[s[0]] as Label).text = "0.00"
		_apply(rest())
	_loading = false

func _new_pose() -> void:
	var kind := _kind()
	var p := rest()
	match kind:
		"walk":
			p.legL = 0.45; p.legR = -0.3; p.armL = -0.3; p.armR = 0.3; p.splayL = 0.15; p.splayR = 0.15; p.lean = 0.05
		"stalk":
			p.armL = 1.45; p.armR = 1.45; p.splayL = 0.08; p.splayR = 0.08; p.legL = 0.4; p.legR = -0.3; p.lean = 0.06
	var n := 1
	for q in poses:
		if q.kind == kind:
			n += 1
	poses.append({"name": "%s %d" % [_kind_label(kind), n], "kind": kind, "pose": p})
	_mark_dirty()
	_fill_list()
	_select(poses.size() - 1)

func _duplicate_pose() -> void:
	if cur < 0:
		return
	var src: Dictionary = poses[cur]
	poses.append({"name": str(src.name) + " copy", "kind": src.kind, "pose": (src.pose as Dictionary).duplicate()})
	_mark_dirty()
	_fill_list()
	_select(poses.size() - 1)

func _delete_pose() -> void:
	if cur < 0:
		return
	poses.remove_at(cur)
	_mark_dirty()
	_fill_list()
	_select(shown[0] if not shown.is_empty() else -1)

func _rename(text: String) -> void:
	if _loading or cur < 0:
		return
	poses[cur].name = text
	var at := shown.find(cur)
	if at >= 0:
		_list.set_item_text(at, text)
	_mark_dirty()

func _on_slider(v: float, key: String) -> void:
	if _loading or cur < 0:
		return
	poses[cur].pose[key] = v
	(_values[key] as Label).text = "%.2f" % v
	_mark_dirty()
	if not _playing:
		_apply(poses[cur].pose)

func _mirror_pose() -> void:
	if cur < 0:
		return
	poses[cur].pose = mirrored(poses[cur].pose)
	_mark_dirty()
	_select(cur)

func _reset_pose() -> void:
	if cur < 0:
		return
	poses[cur].pose = rest()
	_mark_dirty()
	_select(cur)

func _toggle_play() -> void:
	_playing = _play_btn.button_pressed
	if _playing and cur >= 0:
		_play_t = PLAY_STEP
		_play_flip = -1.0
		_play_from = rest()
		_play_to = rest()
	elif cur >= 0:
		_apply(poses[cur].pose)

func _process(dt: float) -> void:
	if not _playing or cur < 0 or not visible:
		return
	_play_t += dt
	if _play_t >= PLAY_STEP:
		_play_t = 0.0
		_play_flip = -_play_flip
		_play_from = _play_to
		_play_to = poses[cur].pose if _play_flip > 0.0 else mirrored(poses[cur].pose)
	var k := clampf(_play_t / SNAP_TIME, 0.0, 1.0)
	k = k * k * (3.0 - 2.0 * k)
	var p := {}
	for key in KEYS:
		p[key] = lerpf(float(_play_from[key]), float(_play_to[key]), k)
	_apply(p)

# ================================================================= the figure
func _apply(pose: Dictionary) -> void:
	if not _model_ok:
		return
	var full := rest()
	for k in pose:
		full[k] = pose[k]
	var xfs := _part_transforms(full)
	for j in _part_nodes.size():
		(_part_nodes[j] as MeshInstance3D).transform = xfs[j]

func _part_kind(node: Node) -> String:
	var nm := ""
	var o: Node = node
	while o != null:
		nm += " " + String(o.name)
		o = o.get_parent()
	nm = nm.to_lower()
	if nm.contains("auge") or nm.contains("eye"): return "eyes"
	if nm.contains("kopf") or nm.contains("head"): return "head"
	if nm.contains("torso") or nm.contains("body"): return "torso"
	if nm.contains("arm"): return "arm"
	if nm.contains("bein") or nm.contains("leg"): return "leg"
	return "torso"

func _top_centroid(mesh: Mesh, xf: Transform3D, b: AABB) -> Vector3:
	var limit := b.end.y - b.size.y * 0.06
	var sum := Vector3.ZERO
	var cnt := 0
	_top_x = Vector2(INF, -INF)
	for s in mesh.get_surface_count():
		var verts = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		if verts == null:
			continue
		for v in verts:
			var w: Vector3 = xf * v
			if w.y >= limit:
				sum += w
				cnt += 1
				_top_x = Vector2(minf(_top_x.x, w.x), maxf(_top_x.y, w.x))
	if cnt == 0:
		return Vector3(b.get_center().x, b.end.y, b.get_center().z)
	return sum / cnt

func _socket_centroid(mesh: Mesh, xf: Transform3D, b: AABB, inner_is_min_x: bool) -> Vector3:
	var band := maxf(0.01, b.size.x * 0.04)
	var edge := b.position.x if inner_is_min_x else b.end.x
	var sum := Vector3.ZERO
	var cnt := 0
	for s in mesh.get_surface_count():
		var verts = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		if verts == null:
			continue
		for v in verts:
			var w: Vector3 = xf * v
			if absf(w.x - edge) <= band:
				sum += w
				cnt += 1
	if cnt == 0:
		return Vector3.INF
	var c := sum / cnt
	c.x = edge
	return c

## The game's MannequinModel.load_template, read from the game's .glb instead of its imported scene
func _load_model() -> void:
	var path := game.path_join(MODEL_FILE)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		_say("Could not read the mannequin model at %s: the preview is empty (poses still save)." % path)
		return
	var root := doc.generate_scene(state)
	if root == null:
		_say("Could not build the mannequin model from %s." % path)
		return
	var box := AABB()
	var first := true
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var xf := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != root:
			if p is Node3D:
				xf = (p as Node3D).transform * xf
			p = p.get_parent()
		var b := xf * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
		var kind := _part_kind(mi)
		var pivot := Vector3.ZERO
		if kind == "leg":
			pivot = Vector3(b.get_center().x, b.end.y, b.get_center().z)
		elif kind == "arm":
			pivot = _top_centroid(mi.mesh, xf, b)
		elif kind == "head" or kind == "eyes":
			pivot = Vector3(b.get_center().x, b.position.y, b.get_center().z)
		_parts.append({"mesh": mi.mesh, "xf": xf, "pivot": pivot, "kind": kind, "cx": b.get_center().x, "b": b, "top_x": _top_x})
	root.free()
	if _parts.is_empty() or box.size.y <= 0.0:
		_say("The mannequin model has no meshes.")
		return
	var s := HEIGHT / box.size.y
	var c := box.get_center()
	_norm_xf = Transform3D(Basis.from_scale(Vector3(s, s, s)), Vector3(-c.x, -box.position.y, -c.z) * s)
	var hip_y := -3.0
	for pt in _parts:
		if pt.kind == "leg":
			hip_y = pt.b.end.y
		if pt.kind == "arm" or pt.kind == "leg":
			pt["side"] = "L" if pt.cx > c.x else "R"
			if pt.kind == "arm":
				var out_x: float = (pt.cx - pt.pivot.x) * (1.0 if pt.side == "L" else -1.0)
				pt["rest_ang"] = atan2(out_x, pt.pivot.y - pt.b.get_center().y)
				var tx: Vector2 = pt.top_x
				pt.pivot.x = tx.x if pt.side == "L" else tx.y
				var sock := _socket_centroid(pt.mesh, pt.xf, pt.b, pt.side == "L")
				if sock.is_finite():
					pt.pivot = sock
		elif pt.kind == "head" or pt.kind == "eyes":
			pt["side"] = ""
	var head_pivot := Vector3.ZERO
	for pt in _parts:
		if pt.kind == "head":
			head_pivot = pt.pivot
	for pt in _parts:
		if pt.kind == "eyes":
			pt.pivot = head_pivot
	_hip_pivot = Vector3(c.x, hip_y, c.z)
	for pt in _parts:
		var mi2 := MeshInstance3D.new()
		mi2.mesh = pt.mesh
		_figure.add_child(mi2)
		_part_nodes.append(mi2)
	_model_ok = true

static func _rot_about(pivot: Vector3, axis: Vector3, angle: float) -> Transform3D:
	var b := Basis(axis, angle)
	return Transform3D(b, pivot - b * pivot)

## The game's MannequinModel.part_transforms: every part's transform in figure space for a pose
func _part_transforms(pose: Dictionary) -> Array:
	var out: Array = []
	var lean := _rot_about(_hip_pivot, Vector3.RIGHT, pose.lean)
	var twist := _rot_about(_hip_pivot, Vector3.UP, pose.twist)
	for pt in _parts:
		var t: Transform3D = pt.xf
		match pt.kind:
			"torso":
				t = twist * lean * t
			"head", "eyes":
				var h := _rot_about(pt.pivot, Vector3.UP, pose.headYaw) * _rot_about(pt.pivot, Vector3.BACK, pose.headTilt) \
					* _rot_about(pt.pivot, Vector3.RIGHT, pose.headNod)
				t = twist * lean * h * t
			"arm":
				var s: String = pt.side
				var swing: float = pose["arm" + s]
				var splay: float = pose["splay" + s]
				var sg := 1.0 if s == "L" else -1.0
				var align: float = pose.get("align", 0.0) * float(pt.get("rest_ang", 0.0))
				var a := _rot_about(pt.pivot, Vector3.BACK, splay * sg) * _rot_about(pt.pivot, Vector3.RIGHT, -swing) \
					* _rot_about(pt.pivot, Vector3.BACK, -align * sg)
				t = twist * lean * a * t
			"leg":
				var s2: String = pt.side
				t = _rot_about(pt.pivot, Vector3.RIGHT, -float(pose["leg" + s2])) * t
		out.append(_norm_xf * t)
	return out
