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


## Moves one `res://` path onto [method root].
##
## Anything that is not a `res://` path comes back untouched, so this is safe to wrap
## around a value that may already be absolute or may be a `user://` path.
##
## Format specifiers survive: only the prefix is replaced, so
## `rebase("res://textures/%s.png") % name` works exactly as it read before.
static func rebase(path: String) -> String:
	return rebase_onto(path, root())


## [method rebase], against a root given rather than discovered.
##
## [b]This split exists so the mounted case can be TESTED from a build.[/b] Built in,
## [method root] is `res://` and every `res://` path is already under it — so every
## property of [method rebase] that matters only in a pack is a tautology here, and a suite
## asserting them passes whatever the body says. Breaking the idempotence below and
## re-running the suite proved it: 101 passed, 0 failed, with the bug that cost a boot put
## back. A check that cannot fail is the family's own worst kind, and this is the only
## spelling that gives the suite a real mount prefix to work against.
static func rebase_onto(path: String, here: String) -> String:
	if not path.begins_with("res://"):
		return path

	# Idempotent: the publisher rewrites `res://` strings in scenes and resources but not in
	# scripts, so a path may already carry the mount prefix and rebasing it again doubles it.
	# Built in, [param here] is `res://` and the path comes back unchanged.
	if path.begins_with(here):
		return path

	return here.path_join(path.substr(6))
