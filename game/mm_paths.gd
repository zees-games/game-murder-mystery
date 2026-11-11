extends RefCounted

## Where this game's own files are, wherever this copy lives. A delivered pack mounts under
## `res://dot_cloud/<id>/<version>/`, so [method rebase] roots a path at this script's directory,
## and anything holding such a path is a `static var`, never a `const`.

const _SELF := preload("mm_paths.gd")


## This game's content root: `res://` built in, the mount prefix delivered.
static func root() -> String:
	# Through [Resource], because a const-preloaded script is typed as its own class and
	# `resource_path` is not reachable on that — "Cannot find member resource_path in
	# base res://…". The cast costs nothing and is the only spelling that compiles.
	var here: Resource = _SELF
	return here.resource_path.get_base_dir().get_base_dir()


## Moves one `res://` path onto [method root]. Anything that is not a `res://` path comes back untouched, so it is safe
## around a value that may be absolute or `user://`. Format specifiers survive: only the prefix is replaced, so
## `rebase("res://textures/%s.png") % name` works as it read before.
static func rebase(path: String) -> String:
	return rebase_onto(path, root())


## [method rebase], against a root given rather than discovered. [b]This split lets the mounted case be TESTED from a
## build[/b]: built in, [method root] is `res://`, so every property of [method rebase] that matters only in a pack is a
## tautology and a suite asserting them passes whatever the body says (101 passed with the idempotence bug put back).
static func rebase_onto(path: String, here: String) -> String:
	if not path.begins_with("res://"):
		return path

	# Idempotent: the publisher rewrites `res://` strings in scenes and resources but not in
	# scripts, so a path may already carry the mount prefix and rebasing it again doubles it.
	# Built in, [param here] is `res://` and the path comes back unchanged.
	if path.begins_with(here):
		return path

	return here.path_join(path.substr(6))
