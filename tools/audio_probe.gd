extends Node

## Under xvfb-run (never --headless, whose audio driver is Dummy): does the game make a noise?
## Bakes the bank as a client does and plays every cue from three metres in front of the
## listener, then a shot and a stab through the game's own calls.
##   xvfb-run -a godot --path . res://tools/audio_probe.tscn

const MmAudio := preload("res://game/mm_audio.gd")


func _ready() -> void:
	var audio := MmAudio.new()
	add_child(audio)
	var ready_now := audio.setup()
	var sink := audio.manager.sink as DotAudioSinkGodot
	var ok := ready_now.ok and sink != null
	print("driver=%s sink=%s" % [AudioServer.get_driver_name(), sink != null])

	for id: StringName in [MmAudio.ROUND_START, MmAudio.ARMED, MmAudio.COUNTDOWN, MmAudio.GUNSHOT, MmAudio.GUNSHOT_NEAR,
			MmAudio.STAB, MmAudio.YOU_DIED, MmAudio.GUN_PICKUP, MmAudio.ROUND_WON, MmAudio.ROUND_LOST]:
		var stream: Variant = sink.bank.get(id) if sink != null else null
		var length := (stream as AudioStream).get_length() if stream is AudioStream else 0.0
		var voice := audio.manager.play_at(id, Vector3(0, 0, -3))
		await get_tree().process_frame
		print("%s baked=%.2f s voice=%d" % [id, length, voice])
		ok = ok and length > 0.05 and voice != 0

	var shot := audio.on_shot(Vector3(0, 1, -6), false)
	var stab := audio.on_stab(Vector3(2, 1, -3), false)
	await get_tree().process_frame
	print("on_shot=%s on_stab=%s" % [shot, stab])
	ok = ok and shot and stab

	get_tree().quit(0 if ok else 1)
