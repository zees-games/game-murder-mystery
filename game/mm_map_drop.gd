extends RefCounted

## Maps handed to Murder Mystery outside the game: a map document (`.json` of kind `murder_map`, or another game's it imports) or a folder holding
## some, dragged onto the window, dropped on the executable or named by `--map-path=<path>`, through gs-map's
## GSMapDropIntake (API 30). Solo only: each document is checked as the catalogue checks one ([method
## MmMapDoc.parse_json]), copied to `user://maps/<id>.json` (read on every start) and joins the open catalogue at once,
## so M offers it. Anything else (a converted BSP folder, a zip, a text file) is refused out loud with what the game
## takes. A shared document acceptor in gs-map would replace this file (nightly map-drop-games-1).

const MmConfig := preload("mm_config.gd")
const MmMapDoc := preload("mm_map_doc.gd")

const CHANNEL := "mm.map_drop"
## gs-map's API level with GSMapDropIntake. Older builds take no dropped maps.
const NEEDS_LEVEL := 30
const INTAKE_SCRIPT := "res://addons/gs_map/core/gs_map_drop_intake.gd"
## What the refusal says this game takes.
const TAKES := "a Murder Mystery map (.json of kind murder_map, or a hideseek, prophunt or playlot map) or a folder of them"
## The document kinds a drop may hold: this game's, and the ones [method MmMapDoc.parse_json] imports.
const KINDS := [MmMapDoc.KIND] + MmMapDoc.FOREIGN_KINDS
## Options gs-core reads whose next argument is their value (never read as a dropped path).
const VALUE_FLAGS := ["--config"]
## [method MmConfig.cli_prefix]: `--mm-<key> <value>`.
const CONFIG_PREFIX := "--mm-"


## The intake, a child of [param host] watching its window, adding to [param game]'s catalogue; every result is said
## line by line through [param say] (`func(line: String)`), and the paths on this process's command line are handled
## once, deferred. Null, with a warning, on gs-map older than API 30.
static func attach(host: Node, game: Node, say: Callable) -> Node:
	var intake := make(game)
	if intake == null:
		return null
	intake.connect(&"handled", func(result: Dictionary) -> void:
		for line in lines(result):
			say.call(line))
	host.add_child(intake)
	(func() -> void: var _taken: Dictionary = intake.call(&"take_cmdline")).call_deferred()
	return intake


## A GSMapDropIntake whose one acceptor takes this game's documents into [param game]'s catalogue.
static func make(game: Node) -> Node:
	if GSAddonApi.build_level("gs_map") < NEEDS_LEVEL or not ResourceLoader.exists(INTAKE_SCRIPT):
		GSLog.warn(CHANNEL, "dropped maps are off: this build's gs-map is older than API %d" % NEEDS_LEVEL)
		return null
	var intake: Node = load(INTAKE_SCRIPT).new()
	intake.name = "MapDrop"
	var flags: PackedStringArray = intake.get(&"value_flags")
	flags.append_array(PackedStringArray(VALUE_FLAGS))
	intake.set(&"value_flags", flags)
	var config := MmConfig.new()
	intake.set(&"config_prefixes", PackedStringArray([CONFIG_PREFIX]))
	intake.set(&"option_takes_value", func(_prefix: String, stem: String) -> bool: return bool(intake.call(&"config_takes_value", config, stem)))
	intake.call(&"add_acceptor", TAKES, func(path: String, into: String) -> Dictionary:
		return accept(path, into, game, int(intake.get(&"search_depth"))))
	return intake


## The acceptor: [code]{}[/code] when [param path] holds no document of [constant KINDS] (the intake then refuses it),
## else [code]{added, errors}[/code]. [param depth] folders down at most (0 is no limit).
static func accept(path: String, into: String, game: Node, depth: int) -> Dictionary:
	var files := documents_in(path, depth)
	if files.is_empty():
		return {}
	var errors := PackedStringArray()
	var added: Array[Dictionary] = []
	var catalogue: Object = game.get(&"catalogue") if game != null else null
	if catalogue == null or not bool(game.get(&"authoritative")):
		errors.append("%s: dropped maps play in solo only" % path.rstrip("/").get_file())
		return {"added": added, "errors": errors}
	var made := DirAccess.make_dir_recursive_absolute(into)
	if made != OK:
		errors.append("%s: cannot make %s (%s)" % [path.rstrip("/").get_file(), into, error_string(made)])
		return {"added": added, "errors": errors}
	for file in files:
		var text := FileAccess.get_file_as_string(file)
		var parsed := MmMapDoc.parse_json(text, file.get_file())
		if not parsed.ok:
			errors.append("%s: %s %s" % [file.get_file(), parsed.error.message, parsed.error.detail])
			continue
		var doc: Dictionary = parsed.value
		var id := str(doc["id"])
		var target := into.path_join(id + ".json")
		if (catalogue.get(&"maps") as Dictionary).has(StringName(id)) and not (catalogue.get(&"dropped") as Dictionary).has(StringName(id)) \
				and not FileAccess.file_exists(target):
			errors.append("%s: %s is already one of this game's maps" % [file.get_file(), id])
			continue
		var out := FileAccess.open(target, FileAccess.WRITE)
		if out == null:
			errors.append("%s: cannot write %s (%s)" % [file.get_file(), target, error_string(FileAccess.get_open_error())])
			continue
		out.store_string(text)
		out.close()
		catalogue.call(&"add_dropped", doc, target)
		added.append({"id": id, "name": str(doc.get("name", id)), "path": target})
	return {"added": added, "errors": errors}


## [param path] itself when it is a document of [constant KINDS], or every one in the folder [param path] and its
## folders [param depth] down (0 is no limit), sorted by name.
static func documents_in(path: String, depth: int) -> PackedStringArray:
	var out := PackedStringArray()
	if FileAccess.file_exists(path):
		if _is_document(path):
			out.append(path)
	elif DirAccess.dir_exists_absolute(path):
		_collect(path.rstrip("/"), depth if depth > 0 else -1, out)
	return out


static func _collect(dir: String, left: int, out: PackedStringArray) -> void:
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for file in files:
		if _is_document(dir.path_join(file)):
			out.append(dir.path_join(file))
	if left == 0:
		return
	var subs := DirAccess.get_directories_at(dir)
	subs.sort()
	for sub in subs:
		if not sub.begins_with(".") and sub != "__MACOSX":
			_collect(dir.path_join(sub), left - 1 if left > 0 else -1, out)


static func _is_document(file: String) -> bool:
	if file.get_extension().to_lower() != "json":
		return false
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
	return data is Dictionary and KINDS.has(str((data as Dictionary).get("kind", "")))


## What to show for an intake result: the maps added, then what was refused and why.
static func lines(result: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var names := PackedStringArray()
	for entry: Variant in result.get("added", []):
		if entry is Dictionary:
			names.append(str((entry as Dictionary).get("name", (entry as Dictionary).get("id", "?"))))
	if not names.is_empty():
		out.append("Added %s. Press M to play it." % ", ".join(names))
	var errors: PackedStringArray = result.get("errors", PackedStringArray())
	if not errors.is_empty():
		out.append("Could not add: %s" % "; ".join(errors))
	return out
