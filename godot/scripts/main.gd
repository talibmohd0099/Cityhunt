## Entry point: starts the game, or the test bed when run with --testbed (or the older --chars / --bare test flags).
extends Node3D

func _ready() -> void:
	var test := false
	for a in OS.get_cmdline_user_args():
		if a == "--testbed" or a.begins_with("--chars") or a == "--bare" or a.begins_with("--bare="):
			test = true
	var n: Node = load("res://scripts/testbed.gd").new() if test else Game.new()
	add_child(n)
