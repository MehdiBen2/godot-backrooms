extends RefCounted
## Loudness matching for recorded clips. tools/measure_audio.py writes each recording's peak and
## active RMS (dBFS) to audio/clip_levels.json; gain() turns that into the linear gain that brings the
## clip to `rms_db` without its peak passing `peak_db`. Clips recorded at very different levels (the
## gasps range from -30 dB to -4 dB peak) then play at the same loudness for the same volume.

const PATH := "res://audio/clip_levels.json"

static var _levels := {}
static var _loaded := false

static func _load() -> void:
	_loaded = true
	if not FileAccess.file_exists(PATH):
		push_warning("clip_levels: %s is missing (run tools/measure_audio.py)" % PATH)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if parsed is Dictionary:
		_levels = parsed

static func has(path: String) -> bool:
	if not _loaded:
		_load()
	return _levels.has(path)

## Linear gain for `path` so its active RMS sits at `rms_db` and its peak stays under `peak_db`.
## Unmeasured clips get 1.0 (played as recorded).
static func gain(path: String, rms_db := -20.0, peak_db := -3.0) -> float:
	if not _loaded:
		_load()
	var m = _levels.get(path)
	if not (m is Dictionary):
		return 1.0
	var by_rms := rms_db - float(m.get("rms", rms_db))
	var by_peak := peak_db - float(m.get("peak", peak_db))
	return db_to_linear(minf(by_rms, by_peak))
