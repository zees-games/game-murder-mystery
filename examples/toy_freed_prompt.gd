extends RefCounted
## The HUD's use prompt for a toy freed after it was aimed at: empty, and the engine reports no error.


class ErrorCatcher extends Logger:
	var errors: Array[String] = []

	func _log_error(function: String, _file: String, _line: int, code: String,
			rationale: String, _editor_notify: bool, _error_type: int,
			_script_backtraces: Array) -> void:
		errors.append("%s %s %s" % [code, rationale, function])


static func run(toys: Object, toy: Object) -> Dictionary:
	var hud := load("res://game/mm_hud.gd") as GDScript
	var index: int = int(toy.get("index"))
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	toy.free()
	var words: String = hud.call("toy_words", toys, index)
	OS.remove_logger(catcher)
	return {"ok": words == "" and catcher.errors.is_empty(), "words": words, "errors": catcher.errors}
