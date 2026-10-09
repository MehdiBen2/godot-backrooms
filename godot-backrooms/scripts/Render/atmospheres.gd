extends RefCounted
## THE LOOKS (render engine v2). Every atmosphere a level can be in, in one place: tune the look here.
## level_lighting.gd blends the live environment between them as you walk (and render_engine.gd picks the camera
## that films each one: the bodycam in Dim and Liminal, the camcorder in Classic, on "auto").
##
##   DIM       the base look, and the one you made: main.tscn's WorldEnvironment as you tuned it in the editor.
##             It is not written here on purpose: it is read off that environment at run time (level_lighting.gd
##             _blend_env), so editing it in the editor stays the way to change it. Dark, warm, foggy halls.
##   LIMINAL   an empty place in the middle of the night with every light left on (the Liminal zone, or a level
##             with "atmosphere": "liminal"): flat, pale, the far end of a hall dissolving into haze.
##   CLASSIC   the famous Level 0 look (the Classic zone, or "atmosphere": "classic"): yellow walls, beige carpet, a
##             drop ceiling with recessed panels, evenly lit, exposed right, clear air, only the panels clip.
##
## Keys are what _blend_env reads from the environment: ambient_energy / ambient_color (fill light), exposure and
## tonemap_white (the camera's metering), glow_* (bloom), ssao_intensity, and haze (what the distance fades to).

const LOOKS := {
	# THE CLASSIC OFFICE, rebuilt from scratch: a real office under recessed fluorescent panels. What makes it read as
	# a photograph rather than a render:
	#   - the panels are the only real light sources; they are HDR (well above 1.0), so they bloom: a tight halo
	#     round each diffuser, wider out, rather than a veil over the room;
	#   - the room is lit by its own bounce (grid_gi.gd): near the panels the walls and floor are bright, between
	#     them and down the halls it falls off, so there are pools of light and darker gaps;
	#   - the ambient fill is low, so shadows stay shadows;
	#   - exposed to keep the walls and carpet in their own colour; only the panels clip to white;
	#   - the far end of a hall fades into the dim, slightly warm air of the room, not into a yellow haze.
	"classic": {
		"ambient_energy": 0.32, "ambient_color": Color(0.4, 0.37, 0.27),   # a low, warm bounce floor: gaps stay dim
		"gi": 0.4, "gi_tint": Color(1.0, 0.9, 0.7),                        # the bounce's strength and tint (yellow walls, beige carpet)
		"exposure": 1.0, "tonemap_white": 2.0,                             # ACES: mid-tones in the middle, highlights roll off
		"glow_threshold": 1.0,                                             # only the HDR panels bloom
		"glow_intensity": 0.75, "glow_bloom": 0.1, "glow_wide": 0.45,      # a soft halo round each panel, wider with distance
		"ssao_intensity": 1.2,                                             # contact darkening where walls meet the ceiling and in corners
		"haze": Color(0.3, 0.28, 0.2),                                     # the far halls fade into dim room air
	},
	# It sits under "classic": the base look blends toward it first (liminal_mix), and a Classic / Bright zone
	# takes over from there.
	"liminal": {
		"ambient_energy": 0.65, "ambient_color": Color(0.31, 0.3, 0.25),    # pale, washed-out fill: shadows go grey, not black
		"exposure": 1.1, "tonemap_white": 2.4,        # a touch bright, highlights rolled off softly
		"glow_threshold": 1.0, "glow_intensity": 0.85,
		"glow_bloom": 0.06, "glow_wide": 0.35,        # a faint dreamy halo round the tubes
		"ssao_intensity": 1.8,                        # flat fluorescent light: little contact shadow
		"haze": Color(0.3, 0.29, 0.23),               # the distance fades to this
		"fog": 0.2,                                   # share of the fog left: you see a long way, but not the end
		"gi": 0.38, "gi_tint": Color(0.96, 0.93, 0.8),   # paler bounce: the liminal halls are less yellow
		"light": Color(0.95, 0.98, 0.9),              # cool fluorescent white with a hint of green
	},
}
