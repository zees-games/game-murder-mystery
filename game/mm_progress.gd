extends GSStatsPlayerProgress

const MmPlayer := preload("mm_player.gd")

## What a player keeps from a round: the numbers only this game has (rounds as the murderer,
## kills, innocents shot, rounds survived), declared once in [method schema] and reported to
## gs-stats as DELTAS; achievements are rules over them. Stand-ins are never counted.

## The published skill figure the site orders by (gs-stats' GSStatsRank).
const RANK_SCORE := &"rank_score"

# The numbers

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

## The world's own side dictionary, shared. See [MmSpectate] for why not a reference to it.
var sides: Dictionary = {}

## player id -> kills this round, for [constant BEST_ROUND_KILLS].
var _round_kills: Dictionary = {}


# The documents

static func ids() -> Array[StringName]:
	return [
		ROUNDS_PLAYED, ROUNDS_WON, MURDERER_ROUNDS, MURDERER_WINS, GUNNER_ROUNDS, SURVIVED, KILLS,
		BEST_ROUND_KILLS, DEATHS, HEROICS, INNOCENTS, MISSES, PICKUPS, FALLS, DOORS,
	]


## Every number, once. [b]`publish` on the ones a player page would show.[/b]
static func schema() -> GSStatsSchema:
	var out := GSStatsSchema.new()
	add_def(out, ROUNDS_PLAYED, GSStatsDef.Kind.COUNTER, "Rounds played", "rounds", false)
	add_def(out, ROUNDS_WON, GSStatsDef.Kind.COUNTER, "Rounds won", "rounds", true)
	add_def(out, MURDERER_ROUNDS, GSStatsDef.Kind.COUNTER, "Rounds as the murderer", "rounds", true)
	add_def(out, MURDERER_WINS, GSStatsDef.Kind.COUNTER, "Rounds won as the murderer", "rounds", true)
	add_def(out, GUNNER_ROUNDS, GSStatsDef.Kind.COUNTER, "Rounds started with the gun", "rounds", false)
	add_def(out, SURVIVED, GSStatsDef.Kind.COUNTER, "Rounds survived", "rounds", true)
	add_def(out, KILLS, GSStatsDef.Kind.COUNTER, "Kills", "kills", true)
	add_def(out, BEST_ROUND_KILLS, GSStatsDef.Kind.BEST, "Most kills in a round", "kills", true)
	add_def(out, DEATHS, GSStatsDef.Kind.COUNTER, "Deaths", "deaths", false)
	add_def(out, HEROICS, GSStatsDef.Kind.COUNTER, "Murderers shot", "murderers", true)
	add_def(out, INNOCENTS, GSStatsDef.Kind.COUNTER, "Innocents shot", "people", true)
	add_def(out, MISSES, GSStatsDef.Kind.COUNTER, "Shots missed", "shots", false)
	add_def(out, PICKUPS, GSStatsDef.Kind.COUNTER, "Guns picked up", "guns", false)
	add_def(out, FALLS, GSStatsDef.Kind.COUNTER, "Falls", "falls", false)
	add_def(out, DOORS, GSStatsDef.Kind.COUNTER, "Doors opened or shut", "doors", false)
	var _rank := GSStatsRank.declare(out, RANK_SCORE, "Rank score")
	var _shots := GSStatsShots.declare(out)
	return out


## What a player can earn, as rules over [method schema]'s numbers. [b]Every stat read here is one [method schema]
## declares and this file records[/b]: an achievement over a stat nothing reports never unlocks and nothing errors.
## The suite checks it both ways.
static func catalogue() -> GSAchievementCatalogue:
	var made: Array[GSAchievement] = []

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
	var spree := GSAchievement.make(&"mm.spree", "Spree", [
		GSAchievementRule.make(
			BEST_ROUND_KILLS, 5.0, GSAchievementRule.Op.AT_LEAST,
			GSAchievementRule.Merge.HIGHEST
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

	var out := GSAchievementCatalogue.new()
	out.achievements = made
	return out


static func _sum(
	id: StringName, title: String, stat: StringName, target: float, points: int,
	description: String, series: StringName = &"", tier: int = 0
) -> GSAchievement:
	var out := GSAchievement.make(id, title, [
		GSAchievementRule.make(
			stat, target, GSAchievementRule.Op.AT_LEAST, GSAchievementRule.Merge.SUM
		),
	])
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out


# Building

func _label() -> String:
	return "murder"


func _make_schema() -> GSStatsSchema:
	return schema()


func _make_catalogue() -> Object:
	return catalogue()


func _rank_stat() -> StringName:
	return RANK_SCORE


func _rank_terms() -> Array:
	return [
		{"stat": String(ROUNDS_WON), "weight": 3.0},
		{"stat": String(MURDERER_WINS), "weight": 2.0},
		{"stat": String(SURVIVED), "weight": 1.0},
		{"stat": String(KILLS), "weight": 1.0},
		{"stat": String(HEROICS), "weight": 3.0},
		{"stat": String(INNOCENTS), "weight": -3.0},
		{"stat": String(DEATHS), "weight": -0.5},
	]


func _setup_feed(target: GSStatsEventFeed) -> void:
	super(target)
	target.name_of = func(id: Variant) -> String:
		var body: MmPlayer = players.get(StringName(str(id)))
		return body.display_name if body != null else ""
	target.is_bot = func(id: Variant) -> bool:
		var body: MmPlayer = players.get(StringName(str(id)))
		return body != null and body.is_bot


## A rank term moved: file the rank on the lifetime baseline plus this session.
func _after_record(player_id: StringName, key_id: StringName, stat: StringName, filed: GSResult) -> void:
	if filed.ok and stat != RANK_SCORE and rank != null and rank.terms.any(func(t: Dictionary) -> bool: return str(t["stat"]) == String(stat)):
		var _s := rank.publish_lifetime(player_id, stats.session_values(key_id), stats.schema)


func _on_leave(player_id: StringName) -> void:
	_round_kills.erase(player_id)


# What the world reports

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

	report_kill(by, player_id, String(_how))

	_round_kills[by] = int(_round_kills.get(by, 0)) + 1


func on_hero(player_id: StringName) -> void:
	record(player_id, HEROICS)


func on_innocent(player_id: StringName) -> void:
	record(player_id, INNOCENTS)


## One gun shot for Accuracy (the gun is a hitscan of this game's own, so no gs-combat `shot_resolved` carries it).
func on_shot(player_id: StringName, landed: bool) -> void:
	if feed != null:
		var _filed := feed.report_shot_outcome(player_id, "gun", landed)


func on_missed(player_id: StringName) -> void:
	record(player_id, MISSES)


func on_picked_up(player_id: StringName) -> void:
	record(player_id, PICKUPS)


func on_fell(player_id: StringName) -> void:
	record(player_id, FALLS)


func on_door(player_id: StringName) -> void:
	record(player_id, DOORS)
