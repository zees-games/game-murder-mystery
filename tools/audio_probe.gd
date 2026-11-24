extends GSAudioProbe

const MmAudio := preload("res://game/mm_audio.gd")

## Under xvfb-run (never --headless, whose audio driver is Dummy): does the game make a noise? Bakes the bank as a client does and plays every cue from three metres in front of the listener, then a shot and a stab through the game's own calls.
##   xvfb-run -a godot --path . res://tools/audio_probe.tscn


func _make_audio() -> Node:
	return MmAudio.new()


func _cue_ids() -> Array[StringName]:
	return [MmAudio.ROUND_START, MmAudio.ARMED, MmAudio.COUNTDOWN, MmAudio.GUNSHOT, MmAudio.GUNSHOT_NEAR,
			MmAudio.STAB, MmAudio.YOU_DIED, MmAudio.GUN_PICKUP, MmAudio.ROUND_WON, MmAudio.ROUND_LOST]


func _after_cues(_sink: Object) -> bool:
	var shot: bool = audio.call("on_shot", Vector3(0, 1, -6), false)
	var stab: bool = audio.call("on_stab", Vector3(2, 1, -3), false)
	await get_tree().process_frame
	report("on_shot=%s on_stab=%s" % [shot, stab])
	return shot and stab
