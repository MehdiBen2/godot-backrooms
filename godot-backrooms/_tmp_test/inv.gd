extends Node3D
const Inv := preload("res://scripts/UI/inventory/inventory.gd")
var shots := "C:/Users/alhyu/AppData/Local/Temp/claude/c--Users-alhyu-Documents-GitHub-godot-backrooms/d1f99a5f-dc78-4136-ad62-0566f5b964b6/scratchpad/inv/"
class FakePlayer extends Node3D:
	var battery := 72.0
	var stamina := 55.0
	var sanity := 38.0
	var exhausted := false
	var grid_down := false
	var dead := false
func _ready() -> void:
	var env := WorldEnvironment.new(); env.environment = Environment.new(); env.environment.background_mode = Environment.BG_COLOR; env.environment.background_color = Color(0.3,0.28,0.16)
	add_child(env)
	var cam := Camera3D.new(); add_child(cam); cam.position = Vector3(0, 1.6, 3)
	var box := MeshInstance3D.new(); box.mesh = BoxMesh.new(); add_child(box)
	var layer := CanvasLayer.new(); add_child(layer)
	var inv = Inv.new(); layer.add_child(inv)
	inv.player = FakePlayer.new(); add_child(inv.player)
	inv.add_item("battery", "AA Battery Pack", "A shrink-wrapped pair of high-discharge industrial AA cells, fully compatible with standard T.S.R.A. field flashlights.", 3, "BAT", 6, "res://models/aa_batteries.glb")
	inv.add_item("flash", "Camera Flash Speedlight", "High-voltage xenon speedlight.", 1, "FLSH", 3, "res://models/camera_flash.glb")
	inv.add_item("tape", "Reflective Hazard Tape", "Retroreflective chevron ribbon.", 2, "TAPE", 4, "res://scripts/World/props/tape_roll.gd")
	inv.add_item("cable_spool", "Equipment Cable Spool", "Shielded cabling.", 1, "CBL", 1, "res://scripts/World/props/cable_roll.gd")
	inv.add_lore("n1", "Kestrel Survey Log, Day 3", "Count of rooms on the east loop: 41. Count on the return pass: 40.")
	Archive.discover("mannequin")
	await get_tree().create_timer(0.3).timeout
	inv.set_shown(true)
	await get_tree().create_timer(1.6).timeout
	for tab in ["ITEMS", "DOSSIER", "ENTRIES", "PAPERS", "CLEARANCE"]:
		inv.select_tab(tab)
		await get_tree().create_timer(1.3).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(shots + tab + ".png")
	inv.pages.DOSSIER.scroll_box.scroll_vertical = 0
	inv.select_tab("DOSSIER")
	await get_tree().create_timer(1.0).timeout
	inv.pages.DOSSIER.scroll_box.scroll_vertical = 900
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(shots + "DOSSIER_2.png")
	get_tree().quit()
