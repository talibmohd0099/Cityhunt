## Engine, siren and rain loops plus the one-shot sounds. The rain and crash sounds come from Lost City;
## the engine, siren and whoosh are made by tools/getaway/make_sounds.py.
class_name GameAudio
extends Node

const DIR := "res://assets/sounds/"
## Loop length in frames (the Lost City rain files carry one extra guard frame after the loop).
const LOOPS := {engine_loop = 88200, siren_loop = 264600, rain_hiss_loop = 110250, rain_body_loop = 121275}

var loops := {}      # name -> AudioStreamPlayer
var shots: Array[AudioStreamPlayer] = []
var next_shot := 0

func _ready() -> void:
	for name in LOOPS:
		var s: AudioStreamWAV = load(DIR + name + ".wav")
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = LOOPS[name]
		var p := AudioStreamPlayer.new()
		p.stream = s
		p.volume_db = -80.0
		add_child(p)
		p.play()
		loops[name] = p
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		shots.append(p)
	set_loop("rain_hiss_loop", 0.16)
	set_loop("rain_body_loop", 0.35)

## Sets a loop's loudness (0..1) and optionally its pitch.
func set_loop(name: String, vol: float, pitch := 1.0) -> void:
	var p: AudioStreamPlayer = loops[name]
	p.volume_db = linear_to_db(max(vol, 0.0001))
	p.pitch_scale = pitch

func play(name: String, vol := 1.0, pitch := 1.0) -> void:
	var p := shots[next_shot]
	next_shot = (next_shot + 1) % shots.size()
	p.stream = load(DIR + name + ".wav")
	p.volume_db = linear_to_db(max(vol, 0.0001))
	p.pitch_scale = pitch
	p.play()
