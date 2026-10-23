extends SceneTree

## Smallest distance between two starts in a batch of players, on every map, under each
## strategy: `godot --headless --path . --script tools/spawn_spread.gd [-- players]`.

const MmMap := preload("../game/mm_map.gd")
const MmMapDoc := preload("../game/mm_map_doc.gd")


func _init() -> void:
	var players := 10
	var args := OS.get_cmdline_user_args()

	if args.size() > 0:
		players = int(args[0])

	for strategy in ["map", "spread"]:
		var rules := DotSpawnRules.new()
		rules.strategy = strategy
		var worst_all := INF
		var sum := 0.0
		var n := 0

		for path in DirAccess.get_files_at("res://maps"):
			if not path.ends_with(".json"):
				continue

			var parsed := MmMapDoc.parse_json(FileAccess.get_file_as_string("res://maps/" + path))

			if not parsed.ok:
				continue

			var map := MmMap.new()
			map.doc = parsed.value
			var worst := INF

			for offset in range(0, 64, 3):
				var spots := map.spawn_batch("players", players, rules, offset)
				var least := INF

				for i in range(spots.size()):
					for j in range(i + 1, spots.size()):
						least = minf(least, (spots[i][0] as Vector3).distance_to(spots[j][0]))

				worst = minf(worst, least)
				sum += least
				n += 1

			worst_all = minf(worst_all, worst)
			print("%s %s worst-offset min pair %.1f" % [strategy, path, worst])
			map.free()

		print("%s: worst %.1f, mean of per-batch min %.1f" % [strategy, worst_all, sum / maxf(n, 1)])

	quit()
