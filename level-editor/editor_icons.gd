extends RefCounted
## The level editor's icons: small line drawings, written as SVG (a 24 x 24 box, drawn in one colour) and turned
## into textures on demand, tinted, at twice the size they are shown so they stay sharp at any UI scale.
## icon("door", colour) gives one; ICONS lists every name. Object types are drawn by their shape (for_type).

const ICONS := {
	# tools
	"select": '<path d="M5 3l13 9.2-5.4 1.1 3.3 6.4-2.6 1.3-3.3-6.5L5 17.6z" fill="{c}" stroke="none"/>',
	"area": '<rect x="3.5" y="3.5" width="17" height="17" rx="1" stroke-dasharray="3 2.4"/><path d="M8 12h8M12 8v8" stroke-width="1.2"/>',
	"wall": '<rect x="4" y="4" width="16" height="16" rx="1.5" fill="{c}" fill-opacity="0.9" stroke="none"/><path d="M4 10h16M4 15h16M10 4v6M14 10v5M10 15v5" stroke="#000" stroke-opacity="0.35" stroke-width="1"/>',
	"floor": '<rect x="4" y="4" width="16" height="16" rx="1"/><path d="M4 9.3h16M4 14.6h16M9.3 4v16M14.6 4v16" stroke-width="1"/>',
	"pit": '<rect x="4" y="4" width="16" height="16" rx="1"/><path d="M7.5 7.5h9v9h-9z" fill="{c}" stroke="none"/><path d="M4 4l3.5 3.5M20 4l-3.5 3.5M4 20l3.5-3.5M20 20l-3.5-3.5" stroke-width="1"/>',
	"brush": '<path d="M19.5 3.5l1.5 1.5-9.5 9.5-1.5-1.5z"/><path d="M9.6 13.1c-2.6-.1-4.3 1.6-4.3 3.9 0 1.6-1 2.5-2.1 3.1 3.8.8 8-.5 8.4-4.6"/>',
	"rect": '<rect x="4" y="5.5" width="16" height="13" rx="1"/><circle cx="4" cy="5.5" r="1.6" fill="{c}"/><circle cx="20" cy="18.5" r="1.6" fill="{c}"/>',
	"fill": '<path d="M4.5 11.5l6.5-6.5 7.5 7.5-6.5 6.5z"/><path d="M11 5L8.7 2.7"/><path d="M19.3 15.2c1.1 1.7 1.7 2.7 1.7 3.4a1.7 1.7 0 01-3.4 0c0-.7.6-1.7 1.7-3.4z" fill="{c}" stroke="none"/>',
	"magnet": '<path d="M6 4v8a6 6 0 0012 0V4h-4v8a2 2 0 01-4 0V4z"/><path d="M6 8h4M14 8h4"/>',
	"rotate": '<path d="M19.5 12a7.5 7.5 0 11-2.2-5.3"/><path d="M19.5 3.5v4.2h-4.2"/>',
	"align": '<path d="M4 3.5v17"/><rect x="7.5" y="6.5" width="12" height="4" rx="1"/><rect x="7.5" y="13.5" width="8" height="4" rx="1"/>',
	"undo": '<path d="M9 5.5L4 10.5l5 5"/><path d="M4 10.5h10.5a5.5 5.5 0 010 11H11"/>',
	"redo": '<path d="M15 5.5l5 5-5 5"/><path d="M20 10.5H9.5a5.5 5.5 0 000 11H13"/>',
	"zoom_in": '<circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.3 15.3L20.5 20.5M7.5 10.5h6M10.5 7.5v6"/>',
	"zoom_out": '<circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.3 15.3L20.5 20.5M7.5 10.5h6"/>',
	"fit": '<path d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5"/><rect x="8.5" y="8.5" width="7" height="7" rx="1" stroke-width="1.2"/>',
	"cube": '<path d="M12 2.8l8.2 4.6v9.2L12 21.2l-8.2-4.6V7.4z"/><path d="M3.8 7.4l8.2 4.6 8.2-4.6M12 12v9.2"/>',
	"play": '<path d="M7 4.3v15.4L19.5 12z" fill="{c}" stroke="none"/>',
	"play_here": '<path d="M4.5 4.5v11l8.8-5.5z" fill="{c}" stroke="none"/><path d="M17.5 21s-4-3.6-4-6.6a4 4 0 018 0c0 3-4 6.6-4 6.6z"/><circle cx="17.5" cy="14.3" r="1.3" fill="{c}"/>',
	"save": '<path d="M5 3.5h11.5l3 3V20.5H5z"/><path d="M8.5 3.5v5h7v-5M8.5 20.5v-6.5h7v6.5"/>',
	"eye": '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
	"eye_off": '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" stroke-opacity="0.5"/><path d="M4 4l16 16"/>',
	"layers": '<path d="M12 3.5l9 4.5-9 4.5L3 8z"/><path d="M3 12l9 4.5 9-4.5M3 16l9 4.5 9-4.5"/>',
	"list": '<path d="M9 6h11M9 12h11M9 18h11"/><circle cx="4.8" cy="6" r="1.2" fill="{c}"/><circle cx="4.8" cy="12" r="1.2" fill="{c}"/><circle cx="4.8" cy="18" r="1.2" fill="{c}"/>',
	"folder": '<path d="M3 6.5h6.5l2 2H21v11H3z"/>',
	"sliders": '<path d="M4 7h9M17 7h3M4 17h4M12 17h8"/><circle cx="15" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
	"ceiling": '<path d="M3 4.5h18M12 4.5v4"/><path d="M7.5 13a4.5 4.5 0 019 0z"/><path d="M12 16v3M8 16.5l-1.5 2M16 16.5l1.5 2" stroke-width="1.3"/>',
	"floorview": '<path d="M2.5 19.5h19"/><path d="M5 19.5l3.5-7h7l3.5 7"/><path d="M12 12.5V4M9 7l3-3 3 3"/>',
	"generate": '<path d="M11 3l1.7 4.7L17.4 9.4l-4.7 1.7L11 15.8 9.3 11.1 4.6 9.4l4.7-1.7z"/><path d="M18 14.5l.9 2.4 2.4.9-2.4.9-.9 2.4-.9-2.4-2.4-.9 2.4-.9z"/>',
	"search": '<circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.3 15.3L20.5 20.5"/>',
	"plus": '<path d="M12 5v14M5 12h14"/>',
	"minus": '<path d="M5 12h14"/>',
	"trash": '<path d="M4.5 7h15M9.5 7V4h5v3M6.5 7l1 13.5h9l1-13.5M10 11v6M14 11v6"/>',
	"copy": '<rect x="8.5" y="8.5" width="12" height="12" rx="1.5"/><path d="M15.5 8.5V3.5h-12v12h5"/>',
	"rename": '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M13.5 6.5l4 4"/>',
	"up": '<path d="M12 19V5M6 11l6-6 6 6"/>',
	"down": '<path d="M12 5v14M6 13l6 6 6-6"/>',
	"floor_up": '<path d="M3.5 19.5h17M3.5 15.5h17"/><path d="M12 12V3.5M8.5 7L12 3.5 15.5 7"/>',
	"floor_down": '<path d="M3.5 4.5h17M3.5 8.5h17"/><path d="M12 12v8.5M8.5 17l3.5 3.5 3.5-3.5"/>',
	"repeat": '<path d="M4 6h16M4 12h16M4 18h16" stroke-width="1.2"/><path d="M18 3v18" stroke-dasharray="2 2"/>',
	"acoustics": '<path d="M3 12h2.5l2-5.5 3 11 3-14 3 13 2-6.5 1.5 2H21"/>',
	"scatter": '<rect x="3.5" y="4" width="6" height="6" rx="1"/><rect x="14" y="3" width="6.5" height="6.5" rx="1"/><rect x="8" y="14" width="7" height="7" rx="1"/>',
	"grid": '<path d="M3.5 9h17M3.5 15h17M9 3.5v17M15 3.5v17"/>',
	"texture": '<rect x="3.5" y="3.5" width="17" height="17" rx="1.5"/><path d="M3.5 15l5-5 4 4 3-3 5 5"/><circle cx="15.5" cy="8" r="1.6"/>',
	"zones": '<rect x="3.5" y="3.5" width="10" height="10" rx="1" fill="{c}" fill-opacity="0.35"/><rect x="10.5" y="10.5" width="10" height="10" rx="1" fill="{c}" fill-opacity="0.65"/>',
	"paint": '<path d="M5 4h12v5H5z"/><path d="M17 6.5h2.5v5H11v3"/><rect x="9.5" y="14.5" width="3" height="6" rx="1"/>',
	"objects": '<circle cx="7" cy="7" r="3.2"/><rect x="13.5" y="3.8" width="6.5" height="6.5" rx="1"/><path d="M7 14l3.8 6.5H3.2z"/><path d="M14 14h6v6h-6z" stroke-dasharray="2 1.5"/>',
	"hint": '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v6M12 7.5v.5"/>',
	"onion": '<rect x="3.5" y="7.5" width="13" height="13" rx="1" stroke-dasharray="2.4 1.8"/><rect x="7.5" y="3.5" width="13" height="13" rx="1"/>',
	# objects
	"thin_wall": '<path d="M3.5 12h17" stroke-width="3.4"/>',
	"half_wall": '<path d="M3.5 12h17" stroke-width="3.4" stroke-dasharray="2.4 1.6"/>',
	"corner": '<path d="M6 4v14h14" stroke-width="3"/>',
	"arc": '<path d="M4 20A16 16 0 0120 4" stroke-width="3"/>',
	"spline": '<path d="M3 17c4-10 7 2 10-6s5-5 8-6" stroke-width="2.6"/><circle cx="3" cy="17" r="1.8" fill="{c}"/><circle cx="12.6" cy="11.4" r="1.8" fill="{c}"/><circle cx="21" cy="5" r="1.8" fill="{c}"/>',
	"pillar": '<rect x="7" y="7" width="10" height="10" fill="{c}" fill-opacity="0.85"/>',
	"column": '<circle cx="12" cy="12" r="5.6" fill="{c}" fill-opacity="0.85"/>',
	"arch": '<path d="M3.5 21V11a8.5 8.5 0 0117 0v10"/><path d="M8 21v-9a4 4 0 018 0v9"/>',
	"door": '<path d="M3 20.5h18"/><path d="M6.5 20.5v-16h9v16"/><circle cx="13" cy="12.5" r="1" fill="{c}"/>',
	"squeeze": '<rect x="3" y="4" width="8" height="16" fill="{c}" fill-opacity="0.6"/><rect x="13" y="4" width="8" height="16" fill="{c}" fill-opacity="0.6"/>',
	"stairs_up": '<path d="M3 20h4v-4h4v-4h4V8h4"/><path d="M14 3.5h5.5V9"/>',
	"stairs_down": '<path d="M3 4h4v4h4v4h4v4h4"/><path d="M14 20.5h5.5V15"/>',
	"flight": '<path d="M2.5 20.5h4v-3.5h4v-3.5h4V10h4V6.5h3"/><path d="M5 9l4-4M9 5H5.5M9 5v3.5" stroke-width="1.3"/>',
	"spiral": '<circle cx="12" cy="12" r="2.3" fill="{c}"/><path d="M12 3a9 9 0 11-9 9"/><path d="M12 3v6.7M21 12h-6.7M5.6 18.4l4.8-4.8M18.4 18.4l-4.8-4.8" stroke-width="1.1"/>',
	"platform": '<path d="M2.5 10h19v3.2h-19z" fill="{c}" fill-opacity="0.7"/><path d="M5 13.2v7.3M19 13.2v7.3M2.5 10V5.5M21.5 10V5.5M2.5 5.5h19M8.5 5.5V10M15.5 5.5V10" stroke-width="1.3"/>',
	"window": '<rect x="4" y="5" width="16" height="15" rx="1"/><path d="M12 5v15M4 12h16"/><path d="M15 2l.8 1.6M19 1.6l-1 1.5M21.6 4.5l-1.6.7" stroke-width="1.2"/>',
	"water": '<path d="M2.5 8.5c2-1.6 3.2-1.6 4.8 0s3.2 1.6 4.8 0 3.2-1.6 4.8 0 3 1.6 4.6 0"/><path d="M2.5 13.5c2-1.6 3.2-1.6 4.8 0s3.2 1.6 4.8 0 3.2-1.6 4.8 0 3 1.6 4.6 0"/><path d="M2.5 18.5c2-1.6 3.2-1.6 4.8 0s3.2 1.6 4.8 0 3.2-1.6 4.8 0 3 1.6 4.6 0"/>',
	"pool": '<path d="M3 8.5h18v11.5H3z"/><path d="M5.5 14.5c1.5-1.1 2.6-1.1 4 0s2.6 1.1 4 0 2.6-1.1 4 0"/><path d="M14.5 3v9M18 3v9M14.5 5.5H18M14.5 8.5H18" stroke-width="1.2"/>',
	"trigger": '<rect x="3.5" y="3.5" width="17" height="17" stroke-dasharray="3 2"/><path d="M13.2 5.5l-5.4 7.2h4.4l-1.2 5.8 5.4-7.2H12z" fill="{c}" stroke="none"/>',
	"prop": '<path d="M12 3l8.2 4.6v9L12 21.2l-8.2-4.6v-9z"/><path d="M3.8 7.6l8.2 4.6 8.2-4.6M12 12.2v9" stroke-width="1.1"/>',
	# markers
	"spawn": '<circle cx="12" cy="7" r="3.2"/><path d="M5.5 21v-2.5a6.5 6.5 0 0113 0V21"/>',
	"exit": '<path d="M14 4h6v16h-6"/><path d="M3.5 12h11M11 8.5l3.5 3.5-3.5 3.5"/>',
	"entity": '<path d="M12 3c-4.5 0-7 3-7 7 0 3 1.5 4.5 3 5.5V20h8v-4.5c1.5-1 3-2.5 3-5.5 0-4-2.5-7-7-7z"/><circle cx="9.3" cy="10.5" r="1.5" fill="{c}"/><circle cx="14.7" cy="10.5" r="1.5" fill="{c}"/>',
	"tv": '<rect x="3" y="6.5" width="18" height="12" rx="1.5"/><path d="M8.5 3l3.5 3.5L15.5 3M8 21h8"/>',
	"drop_hole": '<ellipse cx="12" cy="15.5" rx="8.5" ry="4"/><path d="M12 3v8.5M8.5 8l3.5 3.5L15.5 8"/>',
}

## Object type -> icon, by its object_types.json shape (or name)
const BY_SHAPE := {"slab": "thin_wall", "corner": "corner", "arc": "arc", "spline": "spline", "pillar": "pillar",
	"column": "column", "zone": "trigger", "platform": "platform", "flight": "flight", "spiral": "spiral", "window": "window",
	"water": "water", "pool": "pool"}
const BY_TYPE := {"half_wall": "half_wall", "arch": "arch", "door": "door", "squeeze_gap": "squeeze",
	"stairs_up": "stairs_up", "stairs_down": "stairs_down"}

static var _cache := {}

## Icon `name` drawn in `col`, `px` pixels square as shown (the texture is twice that)
static func icon(name: String, col: Color, px := 20) -> ImageTexture:
	var key := "%s|%s|%d" % [name, col.to_html(), px]
	if _cache.has(key): return _cache[key]
	var hex := "#" + col.to_html(false)
	var body: String = str(ICONS.get(name, ICONS.prop)).replace("{c}", hex)
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="%s" stroke-opacity="%.3f" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">%s</svg>' % [hex, col.a, body]
	var img := Image.new()
	if img.load_svg_from_string(svg, px * 2.0 / 24.0) != OK:
		img = Image.create(px * 2, px * 2, false, Image.FORMAT_RGBA8)
		img.fill(col)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex

## The icon for an object type (its info: object_types.json entry)
static func for_type(t: String, info: Dictionary) -> String:
	if BY_TYPE.has(t): return BY_TYPE[t]
	if info.has("model"): return "prop"
	return BY_SHAPE.get(str(info.get("shape", "")), "prop")
