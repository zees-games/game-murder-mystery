extends SceneTree

## Rewrites cfg/game/game-murder-mystery/config_*/game.yml from MmConfig's fields: godot --headless --path . --script tools/cfg_templates.gd

const MmConfig := preload("../game/mm_config.gd")


func _init() -> void:
	var binder := MmConfig.make_binder(MmConfig.new())
	var files := binder.template_files()
	for path: String in files:
		var res := DotPaths.write_text("res://" + path, files[path])
		print("%s %s" % ["wrote" if res.ok else "FAILED", path])
	quit()
