## Sound: the pre-rendered game sounds (assets/sounds, rendered from the browser version's synth code)
## played through a small pool of voices, each with its own pan and low-pass so distant or blocked
## sounds are muffled the same way the browser version did it.
class_name Sfx
extends Node

const DIR := "res://assets/sounds/"
const VOICES := 16

var info := {}              # name -> manifest entry
var streams := {}           # name -> Array[AudioStreamWAV]
var voices: Array[AudioStreamPlayer] = []
var voice_bus: Array[int] = []
var voice_busy: Array[float] = []    # seconds until the voice is free again (reserved voices: INF)
var loops := {}             # name -> {player, bus, target, cur, tau, lp_target, lp_cur, lp_tau}
var master_vol := 0.8

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	info = JSON.parse_string(FileAccess.get_file_as_string(DIR + "sounds.json"))
	for k in info:
		var list: Array[AudioStreamWAV] = []
		for f in info[k].files:
			var s: AudioStreamWAV = load(DIR + f)
			if info[k].loop:
				s.loop_mode = AudioStreamWAV.LOOP_FORWARD
				s.loop_begin = 0
				s.loop_end = int(info[k].loop_end[0])
			list.append(s)
		streams[k] = list
	_setup_buses()
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = AudioServer.get_bus_name(voice_bus[i])
		add_child(p)
		voices.append(p)
		voice_busy.append(0.0)
	# ambient loops (start silent)
	_loop("rain_hiss_loop", "RainHiss")
	_loop("rain_body_loop", "RainBody")
	_loop("wind_loop", "Wind")
	_loop("drone_loop", "Drone")

func _setup_buses() -> void:
	var comp := AudioEffectCompressor.new()
	comp.threshold = -14.0
	comp.ratio = 4.0
	comp.attack_us = 3000.0
	comp.release_ms = 250.0
	AudioServer.add_bus_effect(0, comp)
	for n in ["RainHiss", "RainBody", "Wind", "Drone"]:
		var b := _add_bus(n)
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = 20000.0
		AudioServer.add_bus_effect(b, lp)
	for i in VOICES:
		var b := _add_bus("Voice%d" % i)
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = 18000.0
		AudioServer.add_bus_effect(b, lp)
		AudioServer.add_bus_effect(b, AudioEffectPanner.new())
		voice_bus.append(b)

func _add_bus(n: String) -> int:
	var b := AudioServer.bus_count
	AudioServer.add_bus(b)
	AudioServer.set_bus_name(b, n)
	AudioServer.set_bus_send(b, "Master")
	return b

func set_master(v: float) -> void:
	master_vol = v
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(0.0001, 0.95 * v)))

func _loop(name: String, bus: String) -> void:
	var p := AudioStreamPlayer.new()
	p.stream = streams[name][0]
	p.bus = bus
	p.volume_db = -80.0
	add_child(p)
	p.play()
	loops[name] = {player = p, bus = AudioServer.get_bus_index(bus), target = 0.0, cur = 0.0, tau = 0.6, lp_target = 20000.0, lp_cur = 20000.0, lp_tau = 0.3}

## Ease a loop's volume (linear, before the manifest gain) and optional low-pass toward new targets.
func loop_to(name: String, vol: float, tau: float, lp := -1.0, lp_tau := 0.3) -> void:
	var L: Dictionary = loops[name]
	L.target = vol
	L.tau = tau
	if lp > 0.0:
		L.lp_target = lp
		L.lp_tau = lp_tau

func _process(dt: float) -> void:
	for i in VOICES:
		if voice_busy[i] > 0.0 and voice_busy[i] < INF:
			voice_busy[i] -= dt
	for name in loops:
		var L: Dictionary = loops[name]
		L.cur += (L.target - L.cur) * (1.0 - exp(-dt / maxf(L.tau, 0.01)))
		L.lp_cur += (L.lp_target - L.lp_cur) * (1.0 - exp(-dt / maxf(L.lp_tau, 0.01)))
		var g: float = L.cur * float(info[name].gain[0])
		(L.player as AudioStreamPlayer).volume_db = linear_to_db(maxf(g, 0.00001))
		var lp := AudioServer.get_bus_effect(L.bus, 0) as AudioEffectLowPassFilter
		lp.cutoff_hz = clampf(L.lp_cur, 80.0, 20000.0)

func _free_voice() -> int:
	var best := -1
	var least := INF
	for i in VOICES:
		if voice_busy[i] == INF:
			continue
		if voice_busy[i] <= 0.0 and not voices[i].playing:
			return i
		if voice_busy[i] < least:
			least = voice_busy[i]
			best = i
	return best

## Play a one-shot. vol is the browser version's linear volume for that call; variant -1 picks one at random.
func play(name: String, vol: float, pan := 0.0, lp := 18000.0, variant := -1, pitch := 1.0) -> int:
	if not streams.has(name) or vol < 0.0005:
		return -1
	var i := _free_voice()
	if i < 0:
		return -1
	var list: Array = streams[name]
	var k := variant if variant >= 0 else randi() % list.size()
	k = clampi(k, 0, list.size() - 1)
	var p := voices[i]
	p.stop()
	p.stream = list[k]
	p.pitch_scale = pitch
	p.volume_db = linear_to_db(vol * float(info[name].gain[k]))
	_voice_fx(i, pan, lp)
	p.play()
	voice_busy[i] = float(info[name].durations[k]) / pitch + 0.05
	return i

func _voice_fx(i: int, pan: float, lp: float) -> void:
	(AudioServer.get_bus_effect(voice_bus[i], 0) as AudioEffectLowPassFilter).cutoff_hz = clampf(lp, 80.0, 18000.0)
	(AudioServer.get_bus_effect(voice_bus[i], 1) as AudioEffectPanner).pan = clampf(pan, -1.0, 1.0)

## A looping positional sound (car alarm, fire) that keeps its voice until released.
func hold(name: String) -> int:
	var i := _free_voice()
	if i < 0:
		return -1
	var p := voices[i]
	p.stop()
	p.stream = streams[name][0]
	p.volume_db = -80.0
	p.pitch_scale = 1.0
	_voice_fx(i, 0.0, 18000.0)
	p.play()
	voice_busy[i] = INF
	return i

func hold_update(i: int, name: String, vol: float, pan: float, lp: float) -> void:
	if i < 0:
		return
	voices[i].volume_db = linear_to_db(maxf(vol * float(info[name].gain[0]), 0.00001))
	_voice_fx(i, pan, lp)

func release(i: int) -> void:
	if i < 0:
		return
	voices[i].stop()
	voice_busy[i] = 0.0

## Freeze or resume everything (pause menu, app in the background).
func pause_all(on: bool) -> void:
	for p in voices:
		p.stream_paused = on
	for name in loops:
		(loops[name].player as AudioStreamPlayer).stream_paused = on

func stop_all() -> void:
	for i in VOICES:
		voices[i].stop()
		voice_busy[i] = 0.0
