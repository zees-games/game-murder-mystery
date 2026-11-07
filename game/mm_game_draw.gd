extends "mm_game_gun.gd"

## The draw of a round: who is a murderer, who holds the gun, who wears which shirt.

## player id -> &"murderer", &"gunner" or &"bystander": roles the next draws hand out instead
## of drawing them. Empty in play. With any entry, gunners are only the ones named.
var forced_roles: Dictionary = {}


## The murderers of this round out of the sorted `keys`: the rotation's draw, or `forced_roles`.
func _draw_murderers(keys: Array[StringName]) -> Array[StringName]:
	var want := config.murderers_for(keys.size())
	# Seats behind a loading cover are not drawn while enough others can be: a murderer that
	# cannot see would sit out the round. If too few are loaded, everybody is a candidate.
	var loaded: Array[StringName] = []

	for id in keys:
		if can_be_harmed(id):
			loaded.append(id)

	var candidates := loaded if loaded.size() >= want else keys
	var picked: Dictionary = DotTeamRotation.pick(
		candidates, want, DotTeamRotation.Mode.RANDOM, murderer_history, _round_seed, {}
	)
	var murderers: Array[StringName] = []

	for id: StringName in picked["picked"]:
		murderers.append(id)

	if not forced_roles.is_empty():
		murderers.clear()
		for id: StringName in keys:
			if forced_roles.get(id, &"") == &"murderer":
				murderers.append(id)
		# Nobody forced to be one: the draw's, less anybody forced to be something else.
		if murderers.is_empty():
			for id: StringName in picked["picked"]:
				if not forced_roles.has(id):
					murderers.append(id)

	return murderers


## The gunners out of the people who are not murderers (`rest`), at random from `stream`.
func _draw_gunners(count: int, rest: Array[StringName], stream: DotRandomStream) -> Array[StringName]:
	var gunners: Array[StringName] = []
	var pool := rest.duplicate()
	var loaded_pool: Array[StringName] = []

	for id in pool:
		if can_be_harmed(id):
			loaded_pool.append(id)

	if loaded_pool.size() >= config.gunners_for(count, rest.size()):
		pool = loaded_pool

	if not forced_roles.is_empty():
		for id in rest:
			if forced_roles.get(id, &"") == &"gunner":
				gunners.append(id)
				pool.erase(id)
			elif forced_roles.has(id):
				pool.erase(id)

	for _i in range(maxi(config.gunners_for(count, rest.size()) - gunners.size(), 0)):
		if pool.is_empty() or not forced_roles.is_empty():
			break
		gunners.append(pool.pop_at(stream.next_range_i(0, pool.size() - 1)))

	return gunners


## A shuffled palette of shirts, so no two share one until there are more people than colours.
func _shirt_palette(stream: DotRandomStream) -> Array[int]:
	var palette: Array[int] = []

	for i in range(SHIRTS.size()):
		palette.append(i)

	for i in range(palette.size() - 1, 0, -1):
		var j := stream.next_range_i(0, i)
		var swap := palette[i]
		palette[i] = palette[j]
		palette[j] = swap

	return palette
