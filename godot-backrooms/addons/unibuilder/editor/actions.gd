@tool
class_name UBActions
extends RefCounted
## Action registry: every editing action's id, label, tooltip, valid mode, and
## optional `params` schema. The toolbar builds its buttons from this list and
## shows them per mode; plugin.run_action() implements the ids. Adding an
## action takes one op file, one entry here, and one run_action branch.
##
## Params schema: {key, label, type: "float"|"int"|"bool", min, max, step,
## default}. Bool params skip min/max/step and render as a checkbox. An
## optional `requires` hides the row until the params it depends on are set
## (grammar in UBAdjustPanel.param_visible). A parameterised action runs at
## once with its current values, then the adjust panel lets the user tweak
## them live. `default` is a literal, or "step" (the snap step) / "quarter"
## (a quarter of it). Values the user sets persist with the grid settings.


static func list() -> Array[Dictionary]:
	return [

		{"id": "weld", "label": "Weld", "mode": UBSelection.Mode.VERTEX,
			"tooltip": "Weld vertices",
			"params": [{"key": "threshold", "label": "Threshold", "type": "float",
				"min": 0.0001, "max": 1.0, "step": 0.0001, "default": 0.001}]},
		{"id": "collapse", "label": "Collapse", "mode": UBSelection.Mode.VERTEX,
			"tooltip": "Collapse vertices"},
		{"id": "split", "label": "Split", "mode": UBSelection.Mode.VERTEX,
			"tooltip": "Split vertices"},
		{"id": "connect", "label": "Connect", "mode": UBSelection.Mode.VERTEX,
			"tooltip": "Connect vertices"},
		{"id": "fill_hole_v", "label": "Fill", "mode": UBSelection.Mode.VERTEX,
			"tooltip": "Fill hole"},

		{"id": "extrude_edges", "label": "Extrude", "mode": UBSelection.Mode.EDGE,
			"tooltip": "Extrude edges",
			"params": [{"key": "distance", "label": "Distance", "type": "float",
				"min": 0.001, "max": 64.0, "step": 0.001, "default": "step"}]},
		{"id": "bridge", "label": "Bridge", "mode": UBSelection.Mode.EDGE,
			"tooltip": "Bridge edges"},
		{"id": "connect_edges", "label": "Connect", "mode": UBSelection.Mode.EDGE,
			"tooltip": "Connect edges"},
		{"id": "insert_loop", "label": "Loop", "mode": UBSelection.Mode.EDGE,
			"tooltip": "Insert edge loop",
			"params": [{"key": "cuts", "label": "Cuts", "type": "int",
				"min": 1, "max": 16, "step": 1, "default": 1}]},
		{"id": "subdiv_edges", "label": "Subdiv", "mode": UBSelection.Mode.EDGE,
			"tooltip": "Subdivide edges",
			"params": [{"key": "segments", "label": "Segments", "type": "int",
				"min": 2, "max": 16, "step": 1, "default": 2}]},
		{"id": "bevel", "label": "Bevel", "mode": UBSelection.Mode.EDGE,
			"tooltip": "Bevel edges (Ctrl+B)",
			"params": [{"key": "amount", "label": "Amount", "type": "float",
				"min": 0.001, "max": 64.0, "step": 0.001, "default": "quarter"},
				{"key": "segments", "label": "Segments", "type": "int",
				"min": 1, "max": 8, "step": 1, "default": 1},
				{"key": "smooth", "label": "Smooth", "type": "bool", "default": false}]},
		{"id": "fill_hole", "label": "Fill", "mode": UBSelection.Mode.EDGE,
			"tooltip": "Fill hole"},
		{"id": "holes", "label": "Holes", "mode": UBSelection.Mode.EDGE,
			"tooltip": "Select holes"},
		{"id": "insert_vert", "label": "InsVert", "mode": UBSelection.Mode.EDGE,
			"tooltip": "Insert vertex"},

		{"id": "extrude", "label": "Extrude", "mode": UBSelection.Mode.FACE,
			"tooltip": "Extrude faces",
			"params": [{"key": "distance", "label": "Distance", "type": "float",
				"min": 0.001, "max": 64.0, "step": 0.001, "default": "step"}]},
		{"id": "inset", "label": "Inset", "mode": UBSelection.Mode.FACE,
			"tooltip": "Inset faces (Ctrl+B)",
			"params": [{"key": "amount", "label": "Amount", "type": "float",
				"min": 0.001, "max": 64.0, "step": 0.001, "default": "quarter"},
				{"key": "equal", "label": "Equal", "type": "bool", "default": false}]},
		{"id": "cut", "label": "Cut", "mode": UBSelection.Mode.FACE,
			"tooltip": "Cut tool"},
		{"id": "subdiv_faces", "label": "Subdiv", "mode": UBSelection.Mode.FACE,
			"tooltip": "Subdivide faces",
			"params": [{"key": "segments", "label": "Segments", "type": "int",
				"min": 2, "max": 16, "step": 2, "default": 2}]},
		{"id": "similar", "label": "Similar", "mode": UBSelection.Mode.FACE,
			"tooltip": "Select similar"},
		{"id": "coplanar", "label": "Coplanar", "mode": UBSelection.Mode.FACE,
			"tooltip": "Select coplanar"},
		{"id": "merge", "label": "Merge", "mode": UBSelection.Mode.FACE,
			"tooltip": "Merge faces"},
		{"id": "duplicate", "label": "Dup", "mode": UBSelection.Mode.FACE,
			"tooltip": "Duplicate faces"},
		{"id": "flip_edge", "label": "FlipEdge", "mode": UBSelection.Mode.FACE,
			"tooltip": "Flip face edge"},
		{"id": "detach", "label": "Detach", "mode": UBSelection.Mode.FACE,
			"tooltip": "Detach faces"},
		{"id": "delete", "label": "Delete", "mode": UBSelection.Mode.FACE,
			"tooltip": "Delete faces (Del)"},
		{"id": "flip", "label": "Flip", "mode": UBSelection.Mode.FACE,
			"tooltip": "Flip normals"},
	]
