extends Node

const MmPlayer := preload("mm_player.gd")

## What a player keeps from a round: the numbers only this game has (rounds as the murderer,
## kills, innocents shot, rounds survived), declared once in [method schema] and reported to
## dot-stats as DELTAS; achievements are rules over them. Stand-ins are never counted.

const CHANNEL := "mm.progress"

# --- The numbers -------------------------------------------------------------

## Rounds a player was in from the start to the end, and won.
const ROUNDS_PLAYED := &"mm.rounds_played"
const ROUNDS_WON := &"mm.rounds_won"
## Rounds drawn as the murderer, and won as one.
const MURDERER_ROUNDS := &"mm.murderer_rounds"
const MURDERER_WINS := &"mm.murderer_wins"
## Rounds started with the gun.
const GUNNER_ROUNDS := &"mm.gunner_rounds"
## Alive at the end of a round, not as the murderer.
const SURVIVED := &"mm.survived"
## Somebody killed, by whoever killed them, and the most in one round.
const KILLS := &"mm.kills"
const BEST_ROUND_KILLS := &"mm.best_round_kills"
## Killed.
const DEATHS := &"mm.deaths"
## The murderer shot; an innocent shot; a shot that hit nobody.
const HEROICS := &"mm.heroics"
const INNOCENTS := &"mm.innocents_shot"
const MISSES := &"mm.misses"
## A dropped gun picked up.
const PICKUPS := &"mm.pickups"
## A fall below the map.
const FALLS := &"mm.falls"
## A door opened or shut.
const DOORS := &"mm.doors"

signal earned(player_id: StringName, title: String, points: int)

var stats: DotStatsTracker = null
var achievements: DotAchievementTracker = null
var link: DotAchievementStatsLink = null

## The world's own dictionaries, shared. See [MmSpectate] for why not a reference to it.
var players: Dictionary = {}
var sides: Dictionary = {}

## Players present when this round began. Only they have played it.
var _in_round: Dictionary = {}

## player id -> kills this round, for [constant BEST_ROUND_KILLS].
var _round_kills: Dictionary = {}

## `func(player_id: StringName) -> String`: the durable key to file this player under, or
## "" for none. Set by the module from dot-platform; see the class note.
var durable_key_fn: Callable = Callable()

## World id -> the key their numbers are filed under, and back. Fixed at [method record]'s
## first reading for them.
var _keys: Dictionary = {}
var _ids: Dictionary = {}


# --- The documents -----------------------------------------------------------

static func ids() -> Array[StringName]:
	return [
		ROUNDS_PLAYED, ROUNDS_WON, MURDERER_ROUNDS, MURDERER_WINS, GUNNER_ROUNDS, SURVIVED, KILLS,
		BEST_ROUND_KILLS, DEATHS, HEROICS, INNOCENTS, MISSES, PICKUPS, FALLS, DOORS,
	]


## Every number, once. [b]`publish` on the ones a player page would show.[/b]
static func schema() -> DotStatsSchema:
	var out := DotStatsSchema.new()
	_add(out, ROUNDS_PLAYED, DotStatsDef.Kind.COUNTER, "Rounds played", "rounds", false)
	_add(out, ROUNDS_WON, DotStatsDef.Kind.COUNTER, "Rounds won", "rounds", true)
	_add(out, MURDERER_ROUNDS, DotStatsDef.Kind.COUNTER, "Rounds as the murderer", "rounds", true)
	_add(out, MURDERER_WINS, DotStatsDef.Kind.COUNTER, "Rounds won as the murderer", "rounds", true)
	_add(out, GUNNER_ROUNDS, DotStatsDef.Kind.COUNTER, "Rounds started with the gun", "rounds", false)
	_add(out, SURVIVED, DotStatsDef.Kind.COUNTER, "Rounds survived", "rounds", true)
	_add(out, KILLS, DotStatsDef.Kind.COUNTER, "Kills", "kills", true)
	_add(out, BEST_ROUND_KILLS, DotStatsDef.Kind.BEST, "Most kills in a round", "kills", true)
	_add(out, DEATHS, DotStatsDef.Kind.COUNTER, "Deaths", "deaths", false)
	_add(out, HEROICS, DotStatsDef.Kind.COUNTER, "Murderers shot", "murderers", true)
	_add(out, INNOCENTS, DotStatsDef.Kind.COUNTER, "Innocents shot", "people", true)
	_add(out, MISSES, DotStatsDef.Kind.COUNTER, "Shots missed", "shots", false)
	_add(out, PICKUPS, DotStatsDef.Kind.COUNTER, "Guns picked up", "guns", false)
	_add(out, FALLS, DotStatsDef.Kind.COUNTER, "Falls", "falls", false)
	_add(out, DOORS, DotStatsDef.Kind.COUNTER, "Doors opened or shut", "doors", false)
	return out


static func _add(
	out: DotStatsSchema, id: StringName, kind: DotStatsDef.Kind, display: String,
	unit: String, publish: bool
) -> void:
	var def := DotStatsDef.make(id, kind, display)
	def.unit = unit
	def.publish = publish
	out.stats.append(def)


## What a player can earn, as rules over [method schema]'s numbers.
##
## [b]Every stat read here is one [method schema] declares and this file records[/b]: an
## achievement over a stat nothing reports never unlocks and nothing errors. The suite checks
## it both ways.
static func catalogue() -> DotAchievementCatalogue:
	var made: Array[DotAchievement] = []

	made.append(_sum(&"mm.still_standing", "Still Standing", SURVIVED, 1.0, 10,
		"Survive a round.", &"mm.survivor", 1))
	made.append(_sum(&"mm.cockroach", "Cockroach", SURVIVED, 25.0, 30,
		"Survive twenty-five rounds.", &"mm.survivor", 2))
	made.append(_sum(&"mm.hero", "Hero", HEROICS, 1.0, 15,
		"Shoot the murderer.", &"mm.hero", 1))
	made.append(_sum(&"mm.sheriff", "Sheriff", HEROICS, 10.0, 40,
		"Shoot the murderer ten times.", &"mm.hero", 2))
	made.append(_sum(&"mm.first_blood", "First Blood", KILLS, 1.0, 10,
		"Kill somebody.", &"mm.killer", 1))
	made.append(_sum(&"mm.perfect_crime", "The Perfect Crime", MURDERER_WINS, 10.0, 40,
		"Win ten rounds as the murderer."))

	# A BEST: five in one round, not five over a career.
	var spree := DotAchievement.make(&"mm.spree", "Spree", [
		DotAchievementRule.make(
			BEST_ROUND_KILLS, 5.0, DotAchievementRule.Op.AT_LEAST,
			DotAchievementRule.Merge.HIGHEST
		),
	])
	spree.description = "Kill five people in one round."
	spree.points = 30
	made.append(spree)

	# Secret: earned by the thing everybody tries to avoid.
	var oops := _sum(&"mm.wrong_person", "Wrong Person", INNOCENTS, 1.0, 5,
		"Shoot somebody who did nothing.")
	oops.secret = true
	made.append(oops)

	var out := DotAchievementCatalogue.new()
	out.achievements = made
	return out


static func _sum(
	id: StringName, title: String, stat: StringName, target: float, points: int,
	description: String, series: StringName = &"", tier: int = 0
) -> DotAchievement:
	var out := DotAchievement.make(id, title, [
		DotAchievementRule.make(
			stat, target, DotAchievementRule.Op.AT_LEAST, DotAchievementRule.Merge.SUM
		),
	])
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out


# --- Building ---------------------------------------------------------------

## [param directory] empty keeps achievement progress in memory; see
## [member MmConfig.progress_directory]. [param report] is [member MmConfig.report_progress].
func setup(directory: String, report: bool) -> DotResult:
	stats = DotStatsTracker.new()
	stats.name = "Stats"
	stats.schema = schema()
	stats.report_to_backbone = report
	stats.define_on_start = report
	add_child(stats)

	var counted := stats.start()

	if not counted.ok:
		return counted.wrap("murder stats")

	achievements = DotAchievementTracker.new()
	achievements.name = "Achievements"
	achievements.catalogue = catalogue()
	achievements.report_to_backbone = report
	# Not published: a server and a client in one process — every suite here — would fight
	# over one registry name, and the link below is handed the tracker directly.
	achievements.register_as = &""

	if directory != "":
		var file_store := DotAchievementStoreFile.new()
		file_store.directory = directory
		achievements.store = file_store
	else:
		achievements.store = DotAchievementStoreMemory.new()

	add_child(achievements)

	var awarded := achievements.start()

	if not awarded.ok:
		return awarded.wrap("murder achievements")

	achievements.unlocked.connect(_on_unlocked)

	link = DotAchievementStatsLink.new()
	link.name = "StatsLink"
	link.tracker = achievements
	link.stats = stats
	add_child(link)

	return link.start().wrap("murder's stats-to-achievements link")


# --- Counting ---------------------------------------------------------------

## Files one reading for one person, and starts counting for them the first time.
##
## [b]Begun lazily, on the first number, and that is what keeps stand-ins out.[/b] A player
## is added to the world before a bridge or a client marks them a stand-in, so a check at
## join time would see every bot as a person; by the time anything is worth counting, the
## flag is set. The memory and file stores load synchronously, so the achievement tracker
## has them before the reading that follows.
func record(player_id: StringName, stat: StringName, value: float = 1.0) -> void:
	if stats == null:
		return

	var body: MmPlayer = players.get(player_id)

	if body == null or body.is_bot:
		return

	var key := _key(player_id)

	if not stats.has_player(key):
		stats.begin(key, body.display_name)
		_begin(key)

	var filed := stats.record(key, stat, value)

	if not filed.ok:
		# WARN: a number a player earned that nobody will ever see. It is a schema or a key
		# that is wrong, and it only ever happens for a reason worth looking at.
		DotLog.warn(CHANNEL, "a reading was refused", {
			"player": String(player_id), "stat": String(stat), "why": filed.error.message,
		})


## The key a player's numbers are filed under. Asked of [member durable_key_fn] once, then
## remembered; see the class note.
func _key(player_id: StringName) -> StringName:
	if _keys.has(player_id):
		return _keys[player_id]

	var key := player_id

	if durable_key_fn.is_valid():
		var durable := str(durable_key_fn.call(player_id))

		if durable != "":
			key = StringName(durable)

	_keys[player_id] = key
	_ids[key] = player_id
	return key


## Loads somebody's lifetime progress. A statement call, never assigned: the tracker's
## `begin` is a coroutine, and this is the family's pattern for starting one from code that
## is not — `await` inside, a bare call outside.
func _begin(player_id: StringName) -> void:
	var began: DotResult = await achievements.begin(String(player_id))

	if not began.ok:
		# WARN: this player will earn nothing this session, and they will not be told why.
		DotLog.warn(CHANNEL, "achievement progress could not be loaded", {
			"player": String(player_id), "why": began.error.message,
		})


## Saves somebody's progress as they go. See [method _begin].
func _end(player_id: StringName) -> void:
	var ended: DotResult = await achievements.end(String(player_id))

	if not ended.ok:
		DotLog.warn(CHANNEL, "achievement progress could not be saved", {
			"player": String(player_id), "why": ended.error.message,
		})


## Stops counting for somebody who left, and saves what they earned.
func leave(player_id: StringName) -> void:
	_in_round.erase(player_id)
	_round_kills.erase(player_id)

	var key: StringName = _keys.get(player_id, player_id)
	_keys.erase(player_id)
	_ids.erase(key)

	if stats == null or not stats.has_player(key):
		return

	var _values := stats.end(key)
	link.forget(String(key))
	_end(key)


func session_values(player_id: StringName) -> DotStatsValues:
	return stats.session_values(_keys.get(player_id, player_id)) \
		if stats != null else DotStatsValues.new()


## The key [param player_id]'s numbers are filed under. For a console command and a suite.
func filed_under(player_id: StringName) -> StringName:
	return _keys.get(player_id, player_id)


# --- What the world reports -------------------------------------------------

func on_round_began() -> void:
	_in_round.clear()
	_round_kills.clear()

	for id: StringName in players:
		_in_round[id] = true
		var body: MmPlayer = players[id]
		if int(sides.get(id, 0)) == MmPlayer.MURDERER_TEAM:
			record(id, MURDERER_ROUNDS)
		elif body.has_gun:
			record(id, GUNNER_ROUNDS)


## The round is decided for [param winner]: the murderers' wins are counted here, while the
## sides are still the round's.
func on_decided(winner: int) -> void:
	if winner != MmPlayer.MURDERER_TEAM:
		return
	for id: StringName in _in_round:
		if int(sides.get(id, 0)) == MmPlayer.MURDERER_TEAM:
			record(id, MURDERER_WINS)


## A round ended. [param winner] is a side, or 0 for a draw.
func on_round_over(winner: int) -> void:
	for id: StringName in _in_round.keys():
		if not players.has(id):
			continue

		record(id, ROUNDS_PLAYED)

		if winner > 0 and int(sides.get(id, 0)) == winner:
			record(id, ROUNDS_WON)

		var kills := int(_round_kills.get(id, 0))

		if kills > 0:
			record(id, BEST_ROUND_KILLS, float(kills))

	_in_round.clear()
	_round_kills.clear()


## Alive at the end of a round, not as the murderer.
func on_survived(player_id: StringName) -> void:
	record(player_id, SURVIVED)


## [param player_id] killed by [param by] (empty for nobody), [param how] the world's DIED_.
func on_killed(player_id: StringName, by: StringName, _how: StringName) -> void:
	record(player_id, DEATHS)

	if by == &"" or by == player_id or not players.has(by):
		return

	record(by, KILLS)
	_round_kills[by] = int(_round_kills.get(by, 0)) + 1


func on_hero(player_id: StringName) -> void:
	record(player_id, HEROICS)


func on_innocent(player_id: StringName) -> void:
	record(player_id, INNOCENTS)


func on_missed(player_id: StringName) -> void:
	record(player_id, MISSES)


func on_picked_up(player_id: StringName) -> void:
	record(player_id, PICKUPS)


func on_fell(player_id: StringName) -> void:
	record(player_id, FALLS)


func on_door(player_id: StringName) -> void:
	record(player_id, DOORS)


func _on_unlocked(player: String, achievement: DotAchievement) -> void:
	# INFO: what an admin keeps. "I did the thing and was not told" is answered here.
	DotLog.info(CHANNEL, "an achievement was unlocked", {
		"player": player, "achievement": String(achievement.id), "points": achievement.points,
	})
	# Back to the world's id: the world tells the player, and the world knows them by that.
	earned.emit(_ids.get(StringName(player), StringName(player)),
		achievement.display_name, achievement.points)


func describe() -> Dictionary:
	return {
		"tracking": stats.players().size() if stats != null else 0,
		"in_round": _in_round.size(),
		"achievements": achievements.catalogue.size() if achievements != null else 0,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if stats != null:
		out.append_array(stats.describe_lines())

	if achievements != null:
		out.append_array(achievements.describe_lines())

	return out
