extends SceneTree
## Prints survivor_anim.gd's STRIKES table: where each heel comes down in each moving clip of the suit,
## as fractions of the clip. A strike is a foot coming down to within 15% of its lift off its lowest point,
## having been above half of it. Rerun after changing the clips and paste the output over STRIKES.
## godot --headless --path . --script res://tools/measure_strikes.gd

const CLIPS := ["walk", "walk_back", "strafe_l", "strafe_r", "run", "run_back", "run_strafe_l", "run_strafe_r",
		"crouch_walk", "crouch_walk_back", "crouch_strafe_l", "crouch_strafe_r"]
const SAMPLES := 192

func _initialize() -> void:
	var suit: Node3D = (load("res://models/player/survivor.glb") as PackedScene).instantiate()
	root.add_child(suit)
	var ap: AnimationPlayer = suit.find_children("*", "AnimationPlayer", true, false)[0]
	var sk: Skeleton3D = suit.find_children("*", "Skeleton3D", true, false)[0]
	var feet := [sk.find_bone("L_Foot"), sk.find_bone("R_Foot")]
	for clip in CLIPS:
		if not ap.has_animation(clip):
			continue
		var a := ap.get_animation(clip)
		ap.play(clip)
		ap.speed_scale = 0.0
		var ys := [[], []]
		for i in SAMPLES:
			ap.seek(a.length * i / SAMPLES, true)
			ap.advance(0.0)
			await process_frame
			for f in 2:
				ys[f].append(sk.get_bone_global_pose(feet[f]).origin.y)
		var strikes := []
		for f in 2:
			var lo: float = ys[f].min()
			var hi: float = ys[f].max()
			var up := false
			for k in SAMPLES * 2:                  # twice round, so a strike across the loop point counts
				var i := k % SAMPLES
				var y: float = (ys[f][i] - lo) / maxf(hi - lo, 1e-4)
				if y > 0.5:
					up = true
				elif up and y < 0.15:
					up = false
					if k >= SAMPLES:
						strikes.append(snappedf(i / float(SAMPLES), 0.001))
		strikes.sort()
		print("\"%s\": %s," % [clip, str(strikes)])
	quit()
