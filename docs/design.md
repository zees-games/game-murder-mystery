# The design

The family's fifth asymmetric game, and the first where **nobody knows the sides**. Buses, deathrun, prop hunt and hide and seek all put the sides on the shirt; here a round is a room of people who look alike, one or two of whom are killers, and the whole game is reading behaviour: who wandered off alone, who drew something, who has blood on them, who was standing over the body. So the design's first rule is that nothing the server sends gives a role away, and its second is that everything a person could honestly see is sent.

Built from game-hide-n-seek (maps, doors, toys, the net bridge, the HUD and menus) and mg-prop-hunt (the weapon plumbing), with catching, the blindfold, taunts, beacons and disguises taken out. Where a comment says another game found something, the line was kept because it is still true here.

## A round

1. **The draw** (`MmGame._draw_roles`, at the round's start): `config.murderers_for(n)` murderers by dot-team's `DotTeamRotation` RANDOM over `murderer_history`, so nobody is the murderer twice running while anybody else can be; then `gunners_for(n)` gunners at random from the rest. Both counts are `players_per_*` with a min and a max, and never so many murderers that nobody is left. Every player gets a shirt colour of their own (`MmPlayer.shirt`), never a side colour.
2. **The grace** (`grace_seconds`, default 10): everybody is told their own role and the HUD shouts it; nobody can draw a weapon (`set_weapon_drawn` refuses with "You cannot draw your knife yet.") or fire. People scatter.
3. **Play** (`round_seconds`, default 180): the murderers stalk, the gunners watch, everybody else tries to stay in company.
4. **The decision** (`_check_round`, every tick): bystanders win when no murderer is alive; murderers win when nobody else is; at the buzzer the bystanders win if any of them is alive. The sentence always ends by naming the murderers ("; Ada was the murderer"), the one moment a role becomes public (`revealed`).

## Roles are secret

What decides it: a client that drew every field it was sent would still not know who the murderer is.

- **TEAM and JOIN carry `public_side()`**, which is BYSTANDERS for anybody in the round. On the client every other person is a bystander, so the scoreboard, the spectate list and the chat can not leak a role by grouping.
- **ROLE goes to its owner alone** (`MmNetBridge._tell_role`, on `role_drawn` and again to a joiner or a reconnect mid-round): the side, whether they hold the gun, and the weapon id. The client keeps it as `local_role`, adopts it for itself only, and forgets it at the round's end.
- **DEATH's `by` is always 0**, and the spectate view is sent no killer: a dead player's camera does not turn to the murderer. The dead are told how (`STABBED`, `SHOT`) because a body on the floor tells everybody that much anyway.
- **No team chat**; voice is proximity by default. A murderer pair coordinates the way people in a room would.
- **What is seen, crosses**: `net_armed` (a weapon drawn, or the gun, in a hand), `net_blood`, the SHOT tracer with who fired it, the GUN on the floor and its pickup. These are the clues the game is played on.
- **The operator's console** may list roles (`mm_roles`); a player's chat command may not.
- **Bots are held to the same**: a stand-in knows another's weapon only by seeing it drawn (`MmBots._sees`), a death only when it saw or heard it, and the killer only when it saw the stab.

## The weapon

`MmWeapons` is a table (knife, cleaver, axe, bat, sword): a name, a reach, a cooldown, and the boxes a figure draws in a hand. The server owner picks one with `murderer_weapon` (`mm_murderer_weapon`); `melee_range` and `melee_cooldown`, when above 0, override the weapon's own.

- **Holstered by default, drawn with Q** (`HOLSTER_BUTTON`). Drawn, it is in the hand for everybody to see; a murderer bot draws only when nobody else is looking.
- **A stab is a measurement** (`stab_target`): the nearest living body within reach of the eye measured flat (so a crouch or a step does not change it), inside `melee_cone`, with nothing solid between (`_clear_between`, the same shapes the walls are). A swing at nobody still costs the cooldown and is still seen.
- **`draw_seconds` after the draw** before a stab lands, so a drawn-and-stabbed-in-one-tick is not a thing.

## The gun

- **One shot, then `gun_cooldown`.** The ray goes to the first wall (`_wall_along`) and hits the first standing capsule within `HIT_RADIUS` of it (`shot_target`).
- **A miss drops it** (`drop_on_miss`) at the shooter's feet, and the shooter is `gun_banned` for the round. Somebody else may walk onto it and pick it up (`pickup_range`, `may_pick_up`): a living bystander without one, not banned. A murderer can never hold the gun.
- **Shooting a bystander** counts as an innocent (`MmProgress.INNOCENTS`), drops the gun too (`drop_on_innocent`) and, with `innocent_kills_shooter`, kills the shooter.
- **A dead gunner drops it** where they fell; a gun dropped below the map goes to a spawn, since a gun nobody can reach is a round with no gun.
- **The hero**: a gunner who kills a murderer gets `hero_points` and `HEROICS`.

## Blood

`_advance_blood` per tick: none until `blood_seconds` before the buzzer, then rising in `blood_stages` steps to the whole of it at the buzzer, and one stage more for each kill with `blood_per_kill`. It is drawn by `MmFigure` as dark patches on the shirt and hands, 0..7 on the wire. Blood is the clock's way of breaking a stalemate: a murderer who waited too long is marked.

## Falls and joiners

- A fall off the map respawns the person at a spawn point, gun kept: it is never a death, since a death nobody caused would be read as a murder.
- A joiner during PLAY is benched (watching) until the next draw; a joiner during the grace gets a bystander's role.

## Bots

`MmBots` on dot-bot (`DotBotNav`, the shared walking code) and dot-npc-ai's annotations (the places they wander to):

- **Bystanders keep company**: walk towards the nearest knot of living people and loiter there, repicking every few seconds; run from anybody they saw draw or saw standing over a body; fetch a gun they can see on the floor.
- **Gunners hunt the suspicious**: suspicion is what they saw (a weapon drawn, blood, the nearest person to a body that fell in view); past `SURE` they turn and fire when dot-bot's aim is on target.
- **Murderers stalk**: pick somebody with nobody else within `ALONE`, walk up at the crowd's pace, draw only when no third person can see it, stab at arm's length; late in the round they stop waiting for a clean moment.
- **They talk** (`bot_chat`): canned lines from `mm_bot_chat.gd`, rationed per bot and for everybody.

## Maps from other games

The game plays its own maps (`mm_practice` built in; `mm_mansion` and `mm_motel` from murder-mystery-maps) and every Hide & Seek, Prop Hunt and Playground map mounted under `maps_extra/<game>`. `MmMapDoc.import` reads each foreign kind: Hide & Seek and Prop Hunt documents share this format's boxes, props, doors, toys and lights, so only their spawns are pooled into `players`; a Playground document's boxes are renamed (`material`, `colour`, `turn`) and its single spawn is ringed. A converted document carries `imported_from`, and `headless_maps` checks each one builds, fits the wire and starts a round. Nothing is copied: a fix to a foreign map is made in its own repository.

## Not done yet

- **Lag compensation is off**: shots are measured on the server's present, not the shooter's past.
- **dot-server-deploy and dot-bootstrap do not know this game yet** (no content entries; not in `projects.tsv`).
- **`DotGameClient`**: the client is still `MmClient` on dot-game's committed API; it moves when API 8 is committed.
- **Tuning with people**: reach, cooldowns, the grace and the blood are first guesses.

## Still loading

A seat whose client is still behind its loading cover cannot see, so the server does not let it be killed or drawn a role. `MmGame.harm_gate` (filled by `MmModule` from dot-game's `can_peer_be_harmed`, unset offline so every bot suite is unchanged) is asked by the combat resolver's `adjust`, the one place every stab, shot and slain shooter passes, and by `stab_target` and `shot_target`, so a swing or a bullet goes past a covered seat and costs a gunner no innocent. An admin's slay or slap carries `context.admin` and passes; a fall is a respawn and passes. The draw (`_draw_roles`) picks murderers and gunners among loaded seats and falls back to everybody when too few are loaded. `MmClient` is not on `DotGameClient`, so it calls `DotGameClient.report_cover` from its own gate's `opened` and `closed`. `examples/dedicated` checks it over a real socket; `tools/render_cover` renders the cover and the frames after it lifts (`screenshots/`).
