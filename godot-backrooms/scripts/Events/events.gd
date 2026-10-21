extends "res://scripts/Events/events_audio.gd"
## Event director (js/game/events.js + eventDefs.js). Decides WHEN something happens and WHICH
## event fits the moment: tension builds while things are quiet (faster when you stand still,
## walk in the dark or have low sanity), then a weighted pick among events that are off cooldown
## and pass their own when()/score(). Events use later() / watch() / on_clear().
##
## Dev keys: F1 random event, F6 mannequin room + bacteria, F7 power cut, F8 preacher whisper,
## F9 stop all events.

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	scares = get_parent().get_node("Scares")
	nav = GridNav.new(level)
	_define_events()
	_build_banner()
	reset()

# ---------------------------------------------------------------- definitions
func define(def: Dictionary) -> void:
	var d := {"weight": 1.0, "cooldown": 180.0, "duration": 10.0, "intensity": 0.5,
		"when": Callable(), "score": Callable()}
	d.merge(def, true)
	events.append(d)

func _define_events() -> void:
	define({"name": "powerCut", "weight": 1.5, "cooldown": 1440.0, "duration": POWER_CUT_SECONDS + 5.0, "intensity": 1.0,
		"when": func(_c): return level.lit.size() > 0,
		# hits hardest when you're relying on the tubes, not your own light
		"score": func(c): return (1.4 if c.dark else 1.0) * (1.3 if c.battery < 25.0 else 1.0),
		"run": _event_power_cut})
	define({"name": "preacherWhisper", "weight": 2.0, "cooldown": 360.0, "duration": 12.0, "intensity": 0.5,
		"when": func(c): return c.since_last > 60.0,
		"score": func(c): return 1.0 + minf(1.0, c.still / 10.0),
		"run": func(): _event_preacher(-1)})
	define({"name": "wallKnock", "weight": 1.6, "cooldown": 240.0, "duration": 9.0, "intensity": 0.45,
		"when": func(c): return c.since_last > 30.0,
		"score": func(c): return (1.4 if c.still > 3.0 else 1.0) * (1.3 if c.dark else 1.0),
		"run": _event_wall_knock})
	define({"name": "breathBehind", "weight": 1.0, "cooldown": 420.0, "duration": 6.0, "intensity": 0.6,
		"when": func(c): return c.still > 2.0 and c.dark and c.sanity < 80.0,
		"run": _event_breath_behind})
	define({"name": "redAlert", "weight": 1.8, "cooldown": 420.0, "duration": 28.0, "intensity": 0.8,
		"when": func(c): return level.lit.size() > 0 and c.since_last > 45.0,
		"score": func(c): return 1.0 + 0.4 * c.tension,
		"run": _event_red_alert})
	define({"name": "emergencyPulse", "weight": 1.4, "cooldown": 360.0, "duration": 29.0, "intensity": 0.7,
		"when": func(c): return level.lit.size() > 0 and c.since_last > 45.0,
		"score": func(c): return (1.3 if c.still > 3.0 else 1.0) * (1.2 if c.sanity < 70.0 else 1.0),
		"run": _event_emergency_pulse})
	define({"name": "lightsOut", "weight": 1.5, "cooldown": 300.0, "duration": 22.0, "intensity": 0.75,
		"when": func(c): return level.lit.size() > 0,
		"score": func(c): return (1.3 if c.dark else 1.0),
		"run": _event_lights_out})
	define({"name": "oneLamp", "weight": 1.4, "cooldown": 400.0, "duration": 22.0, "intensity": 0.85,
		"when": func(c): return level.lit.size() > 6 and c.since_last > 45.0,
		"score": func(c): return (1.3 if c.dark else 1.0) * (1.2 if c.still > 3.0 else 1.0),
		"run": _event_one_lamp})
	define({"name": "deadAir", "weight": 1.3, "cooldown": 420.0, "duration": 13.0, "intensity": 0.85,
		"when": func(c): return c.since_last > 40.0,
		"score": func(c): return (1.4 if c.still > 4.0 else 1.0),
		"run": _event_dead_air})
	define({"name": "machineVoice", "weight": 1.4, "cooldown": 240.0, "duration": 12.0, "intensity": 0.5,
		"when": func(c): return c.since_last > 30.0,
		"run": _event_machine_voice})
	define({"name": "ghostRoster", "weight": 0.9, "cooldown": 600.0, "duration": 8.0, "intensity": 0.4,
		"when": func(c): return c.since_last > 40.0,
		"run": _event_ghost_roster})
	define({"name": "humRises", "weight": 1.1, "cooldown": 420.0, "duration": 24.0, "intensity": 0.6,
		"when": func(c): return level.lit.size() > 0 and c.since_last > 40.0,
		"run": _event_hum_rises})
	define({"name": "partyWall", "weight": 1.0, "cooldown": 600.0, "duration": 62.0, "intensity": 0.5,
		"when": func(c): return c.since_last > 45.0,
		"run": _event_party_wall})
	define({"name": "phoneRing", "weight": 1.1, "cooldown": 540.0, "duration": 40.0, "intensity": 0.5,
		"when": func(c): return c.since_last > 40.0,
		"run": _event_phone_ring})
	define({"name": "houndPacing", "weight": 1.1, "cooldown": 480.0, "duration": 60.0, "intensity": 0.6,
		"when": func(c): return c.since_last > 40.0,
		"run": _event_hound_pacing})
	define({"name": "wallFootsteps", "weight": 1.2, "cooldown": 360.0, "duration": 20.0, "intensity": 0.5,
		"when": func(c): return c.since_last > 35.0,
		"score": func(c): return (1.3 if c.dark else 1.0) * (1.2 if c.still > 3.0 else 1.0),
		"run": _event_wall_footsteps})
	define({"name": "run", "weight": 0.8, "cooldown": 720.0, "duration": 28.0, "intensity": 1.0,
		"when": func(c): return level.lit.size() > 10 and c.since_last > 60.0,
		"run": _event_run})
	define({"name": "itHeardYou", "weight": 1.1, "cooldown": 480.0, "duration": 34.0, "intensity": 0.6,
		"when": func(c): return c.since_last > 40.0,
		"run": _event_it_heard_you})
	define({"name": "sayYourName", "weight": 0.8, "cooldown": 900.0, "duration": 10.0, "intensity": 0.7,
		"when": func(c): return c.since_last > 60.0,
		"run": _event_say_your_name})
	define({"name": "answerBack", "weight": 1.0, "cooldown": 420.0, "duration": 46.0, "intensity": 0.5,
		"when": func(c): return c.since_last > 40.0,
		"run": _event_answer_back})
	define({"name": "yourOwnVoice", "weight": 1.0, "cooldown": 600.0, "duration": 12.0, "intensity": 0.7,
		"when": func(c): return c.since_last > 60.0 and not Voice.my_clips.is_empty(),
		"run": _event_your_own_voice})
	define({"name": "doorbell", "weight": 1.0, "cooldown": 480.0, "duration": 12.0, "intensity": 0.4,
		"when": func(c): return c.since_last > 30.0,
		"run": _event_doorbell})
	define({"name": "lookTogether", "weight": 0.8, "cooldown": 900.0, "duration": 20.0, "intensity": 0.8,
		"when": func(c): return c.since_last > 60.0,
		"run": _event_look_together})
	define({"name": "soundsToAvoid", "weight": 1.0, "cooldown": 600.0, "duration": 18.0, "intensity": 0.6,
		"when": func(c): return c.since_last > 40.0,
		"run": _event_sounds_to_avoid})
	define({"name": "countdown", "weight": 0.7, "cooldown": 900.0, "duration": 95.0, "intensity": 0.3,
		"when": func(c): return c.since_last > 40.0,
		"run": _event_countdown})
