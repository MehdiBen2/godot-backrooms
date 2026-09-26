extends "res://scripts/entities/bacteria/bacteria_base.gd"
## THE BACTERIA, layer 2: getting around. A breadth-first flow field toward its goal (grid_nav.gd),
## steering that cuts corners it can see past, and the choice of where to go next when nothing is
## pulling it: somewhere it hasn't been for a while, a junction, near what last caught its interest,
## and after a long quiet, near you.

var flow := PackedInt32Array()
var reach := PackedInt32Array()
var goal := Vector3.ZERO
var goal_key := -1
var flow_timer := 0.0
var goal_reachable := true
var visited := {}
var roam_clock := 0.0
var prune_timer := 0.0
var interest := {"x": 0.0, "z": 0.0, "at": -1e9}

func _setup_nav() -> void:
	nav = GridNav.new(level)
	n = nav.n
	flow.resize(n * n)
	reach.resize(n * n)

func blocked(cx: int, cz: int) -> bool:
	return nav.blocked(cx, cz)

func set_goal(x: float, z: float) -> void:
	goal = Vector3(x, 0.0, z)
	var gx := GridNav.cell(x)
	var gz := GridNav.cell(z)
	if not blocked(gx, gz):
		return
	var best := INF
	for ox in range(-2, 3):
		for oz in range(-2, 3):
			if blocked(gx + ox, gz + oz):
				continue
			var wx := (gx + ox) * CELL
			var wz := (gz + oz) * CELL
			var d := Vector2(wx - x, wz - z).length()
			if d < best:
				best = d
				goal = Vector3(wx, 0.0, wz)

func at_goal(within := 0.9) -> bool:
	return Vector2(goal.x - global_position.x, goal.z - global_position.z).length() < within or not goal_reachable

# Direction to walk: straight at the goal when it's in view, otherwise the farthest visible cell
# a few steps down the flow field (smooth corners)
func steer(delta: float) -> Vector3:
	var p := global_position
	var gx := GridNav.cell(goal.x)
	var gz := GridNav.cell(goal.z)
	var key := gx * n + gz
	flow_timer -= delta
	if key != goal_key or flow_timer <= 0.0:
		goal_key = key
		flow_timer = 0.5
		goal_reachable = nav.bfs(gx, gz, flow)
	if Vector2(goal.x - p.x, goal.z - p.z).length() < 10.0 and nav.clear_line(p.x, p.z, goal.x, goal.z):
		return Vector3(goal.x - p.x, 0.0, goal.z - p.z)
	var x := GridNav.cell(p.x)
	var z := GridNav.cell(p.z)
	var have := false
	var bx := 0.0
	var bz := 0.0
	for step in 4:
		var here := flow[x * n + z] if (x >= 0 and z >= 0 and x < n and z < n) else -1
		var nx := -1
		var nz := -1
		var best: float = INF if here < 0 else float(here)
		for o in GridNav.NEIGHBOURS:
			var ax: int = x + o.x
			var az: int = z + o.y
			if ax < 0 or az < 0 or ax >= n or az >= n:
				continue
			var v := flow[ax * n + az]
			if v >= 0 and v < best:
				best = v
				nx = ax
				nz = az
		if nx < 0:
			break
		x = nx
		z = nz
		var wx := x * CELL
		var wz := z * CELL
		if step == 0 or nav.clear_line(p.x, p.z, wx, wz):
			bx = wx
			bz = wz
			have = true
		else:
			break
	if not have:
		return Vector3(goal.x - p.x, 0.0, goal.z - p.z)
	return Vector3(bx - p.x, 0.0, bz - p.z)

func vkey(x: int, z: int) -> int:
	return x * n + z

func mark_visited() -> void:
	var gx := GridNav.cell(global_position.x)
	var gz := GridNav.cell(global_position.z)
	for ox in range(-2, 3):
		for oz in range(-2, 3):
			visited[vkey(gx + ox, gz + oz)] = roam_clock
	prune_timer -= 1.0
	if prune_timer <= 0.0:
		prune_timer = 300.0
		for k in visited.keys():
			if roam_clock - visited[k] > 400.0:
				visited.erase(k)

func note_interest(x: float, z: float) -> void:
	interest.x = x
	interest.z = z
	interest.at = roam_clock

# Best of a handful of candidate spots 4-20 cells away, scored on how long since it last went
# there, whether it's a junction, and how close it is to what interests it. `who`: where the one it
# hunts is (after a long quiet it drifts toward them).
func roam_spot(who := Vector3.INF) -> bool:
	var p := global_position
	if not nav.bfs(GridNav.cell(p.x), GridNav.cell(p.z), reach):
		return false
	var options: Array = []
	for x in range(1, n - 1):
		for z in range(1, n - 1):
			var d := reach[x * n + z]
			if d >= 4 and d <= 20:
				options.append(x * n + z)
	if options.is_empty():
		return false
	var menace := since_encounter > MENACE_TIME and who.is_finite()
	var interest_fresh: bool = roam_clock - interest.at < 70.0
	var best := -1
	var best_score := -INF
	for i in 16:
		var k: int = options[rng.randi() % options.size()]
		var gx := k / n
		var gz := k % n
		var wx := gx * CELL
		var wz := gz * CELL
		var since: float = roam_clock - visited.get(vkey(gx, gz), -200.0)
		var score := minf(1.0, since / 150.0) * 2.0 + rng.randf() * 0.4
		var open := 0
		for o in GridNav.NEIGHBOURS:
			if not blocked(gx + o.x, gz + o.y):
				open += 1
		if open >= 3:
			score += 0.35
		if interest_fresh:
			score += maxf(0.0, 1.0 - Vector2(wx - interest.x, wz - interest.z).length() / (10.0 * CELL)) * 1.6
		if menace:
			score += maxf(0.0, 1.0 - Vector2(wx - who.x, wz - who.z).length() / (9.0 * CELL)) * 1.2
		if reach[k] < 6:
			score -= 0.4
		if score > best_score:
			best_score = score
			best = k
	set_goal((best / n) * CELL, (best % n) * CELL)
	return true

# A random reachable floor spot between min_cells and max_cells of path away, optionally close to `near`
func pick_spot(min_cells: int, max_cells: int, near = null, near_cells := 0.0) -> bool:
	var p := global_position
	if not nav.bfs(GridNav.cell(p.x), GridNav.cell(p.z), reach):
		return false
	var options: Array = []
	for x in range(1, n - 1):
		for z in range(1, n - 1):
			var d := reach[x * n + z]
			if d < min_cells or d > max_cells:
				continue
			if near != null and Vector2(x * CELL - near.x, z * CELL - near.z).length() > near_cells * CELL:
				continue
			options.append(x * n + z)
	if options.is_empty():
		return false
	var k: int = options[rng.randi() % options.size()]
	set_goal((k / n) * CELL, (k % n) * CELL)
	return true
