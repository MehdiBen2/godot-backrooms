extends RefCounted
## The sound-effect buffer pool: every clip a scare can fire, loaded ahead of time so the first scream
## never waits on the disk. warm() queues paths on ResourceLoader's worker threads when a level starts;
## get() hands back the resident stream (blocking only if its load is still in flight, a plain load()
## if it was never warmed). The pool holds a reference to each stream, so they stay in memory for the
## whole run instead of dropping out of the resource cache between scares.

static var streams := {}                     # path -> AudioStream (null when the file does not exist)
static var pending := {}                     # path -> true while a threaded load is in flight

## Every recording the scare system can play on a whim (the rest load with the node that owns them)
static func scare_paths() -> Array:
	var paths := [
		"res://audio/entity/scream.mp3", "res://audio/entity/mannequin_whisper.mp3",
		"res://audio/events/preacher.mp3", "res://audio/tape_rip.wav",
	]
	for n in range(1, 31):
		paths.append("res://audio/entity/entity_%d.wav" % n)
	return paths

## Start loading `paths` in the background (already-pooled or missing ones are skipped)
static func warm(paths: Array) -> void:
	for path: String in paths:
		if streams.has(path) or pending.has(path):
			continue
		if not ResourceLoader.exists(path):
			streams[path] = null
		elif ResourceLoader.load_threaded_request(path, "AudioStream") == OK:
			pending[path] = true

static func get_stream(path: String) -> AudioStream:
	if streams.has(path):
		return streams[path]
	var s: AudioStream = null
	if pending.has(path):
		pending.erase(path)
		s = ResourceLoader.load_threaded_get(path) as AudioStream
	elif ResourceLoader.exists(path):
		s = load(path) as AudioStream
	streams[path] = s
	return s
