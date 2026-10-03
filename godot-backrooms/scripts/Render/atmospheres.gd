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
##   CLASSIC   the found-footage look (the famous camcorder tape; the Classic zone, or "atmosphere": "classic"):
##             flat, evenly lit, overexposed mono-yellow, a bright ceiling, clear air, highlights that clip.
##
## Keys are what _blend_env reads from the environment: ambient_energy / ambient_color (fill light), exposure and
## tonemap_white (the camera's metering), glow_* (bloom), ssao_intensity, and haze (what the distance fades to).

const LOOKS := {
	# The Kane Pixels look (2026-10 pass): everything here leans further toward that footage than before. Strong
	# even fill so nothing is truly in shadow, a camera that is overexposed and clips early (white tubes, bright
	# walls), a washed-out mono-yellow, a soft glow round the tubes, and very little contact shadow: the place
	# looks flat and too bright, which is what makes it uncanny.
	"classic": {
		# (pulled back a step after the first Kane pass: the ceiling read as one flat glowing sheet, too bright to be real)
		"ambient_energy": 0.88, "ambient_color": Color(0.45, 0.4, 0.19),    # washed-out yellow fill: shadows stay soft and shallow
		"exposure": 1.24, "tonemap_white": 2.2,       # overexposed, and the highlights clip sooner: blown-out tubes and walls
		"glow_threshold": 1.0,                        # the panels and the brightest wall right under them bleed
		# a soft halo round the tubes, but still no bloom-everything: the far panels bunched up near the horizon
		# merged into one glowing band across the ceiling when the bloom was high
		"glow_intensity": 1.2, "glow_bloom": 0.03, "glow_wide": 0.42,
		"ssao_intensity": 0.8,                        # flat fluorescent light: only a faint darkening in the corners
		# the distance washes out to a pale yellow wall tone rather than going dark
		"haze": Color(0.5, 0.45, 0.22),
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
		"light": Color(0.95, 0.98, 0.9),              # cool fluorescent white with a hint of green
	},
}
