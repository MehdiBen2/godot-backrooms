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
	# The classic Level 0 look: strong even fill so nothing is truly in shadow, yellow walls under neutral-white
	# panels, clear air with only a little depth falloff, and very little contact shadow: the place looks too clean
	# and too evenly lit, which is what makes it uncanny.
	"classic": {
		# (2026-10 "clean office" pass, after a reference still: a well-kept office lit evenly by recessed panels, filmed
		# on a clean digital camera. Exposed right, not blown out: only the panels themselves clip. The yellow is in the
		# walls, not the light: a near-neutral warm fill, so the ceiling stays a pale grey-beige and the carpet beige.)
		# the even fill is the base of it: the grid GI (grid_gi.gd) lifts it near the lamps and lets it fall away
		# between them and down a long hall, so the place isn't one flat level everywhere
		"ambient_energy": 0.7, "ambient_color": Color(0.42, 0.39, 0.27),
		"gi": 0.45, "gi_tint": Color(1.0, 0.86, 0.55),  # how much bounce, and its colour: off yellow walls and beige carpet
		"exposure": 1.02, "tonemap_white": 4.5,       # mid-tones sit in the middle; highlights roll off late and softly
		"glow_threshold": 1.0,                        # the panels bloom; the walls right under them only just
		# a real soft halo round every lit panel, as a camera sees an LED panel, without fogging the whole frame
		"glow_intensity": 1.05, "glow_bloom": 0.04, "glow_wide": 0.38,
		"ssao_intensity": 1.4,                        # the soft darkening where the walls meet the ceiling and in corners
		# the far end of a long hall goes a touch darker and flatter, not paler: depth without fog
		"haze": Color(0.36, 0.33, 0.2),
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
