extends RefCounted
## IMA ADPCM speech codec: 16-bit PCM -> 4 bits per sample (4:1). At 16 kHz mono that is 8 KB/s per
## speaker, small enough for a Cloudflare tunnel. Godot has no built-in voice codec, and this one is
## simple, fast in GDScript and clean for speech.
##
## The encoder keeps its predictor / step index BETWEEN packets and writes them into each packet's
## header, so the decoder starts every block in exactly the encoder's state: no restart clicks (a
## reset every 20 ms would buzz at 50 Hz).
##
## Block layout: [pred lo, pred hi, step index][N/2 bytes: two 4-bit samples each, low nibble first]

const STEP := [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80,
	88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724,
	796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428,
	4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385,
	24623, 27086, 29794, 32767]
const INDEX := [-1, -1, -1, -1, 2, 4, 6, 8]
const HEADER := 3

var pred := 0
var idx := 0

func reset() -> void:
	pred = 0
	idx = 0

## Encodes one frame of samples in -1..1 (an even count). Returns the block.
func encode_block(frame: PackedFloat32Array) -> PackedByteArray:
	var n := frame.size()
	var out := PackedByteArray()
	out.resize(HEADER + n / 2)
	out[0] = pred & 0xFF
	out[1] = (pred >> 8) & 0xFF
	out[2] = idx
	var p := pred
	var ix := idx
	var byte := 0
	for i in n:
		var sample := int(clampf(frame[i], -1.0, 1.0) * 32767.0)
		var diff := sample - p
		var sign := 0
		if diff < 0:
			sign = 8
			diff = -diff
		var step: int = STEP[ix]
		var delta := 0
		var vp := step >> 3
		if diff >= step:
			delta |= 4
			diff -= step
			vp += step
		step >>= 1
		if diff >= step:
			delta |= 2
			diff -= step
			vp += step
		step >>= 1
		if diff >= step:
			delta |= 1
			vp += step
		p = clampi(p - vp if sign != 0 else p + vp, -32768, 32767)
		delta |= sign
		ix = clampi(ix + INDEX[delta & 7], 0, 88)
		if i % 2 == 0:
			byte = delta
		else:
			out[HEADER + i / 2] = byte | (delta << 4)
	pred = p
	idx = ix
	return out

## Decodes a block written by encode_block into samples in -1..1
static func decode_block(data: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if data.size() <= HEADER:
		return out
	var p := data[0] | (data[1] << 8)
	if p >= 32768:
		p -= 65536
	var ix := clampi(data[2], 0, 88)
	var n := (data.size() - HEADER) * 2
	out.resize(n)
	for i in n:
		var b := data[HEADER + i / 2]
		var nib := (b >> 4) if i % 2 == 1 else (b & 0xF)
		var step: int = STEP[ix]
		var vp := step >> 3
		if nib & 4:
			vp += step
		if nib & 2:
			vp += step >> 1
		if nib & 1:
			vp += step >> 2
		p = clampi(p - vp if nib & 8 else p + vp, -32768, 32767)
		ix = clampi(ix + INDEX[nib & 7], 0, 88)
		out[i] = p / 32768.0
	return out
