# game-murder-mystery

Murder Mystery. Everybody is a bystander but one or two: the murderers carry a melee weapon they draw and put away, and kill whoever they can reach unseen; one or two bystanders also hold a gun with a single shot and a cooldown, and a miss drops it for somebody else to pick up. Nobody is told anybody's role but their own. Blood creeps onto the murderers as the clock runs down. The bystanders win if the murderers are all dead or the clock runs out; the murderers win if nobody else is left. Built from game-hide-n-seek and mg-prop-hunt with catching, taunts, beacons and disguises taken out and roles, the weapon, the gun and blood put in.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to this game. The own maps are in `maps/`, a link to [murder-mystery-maps](../murder-mystery-maps), written by its `tools/build_maps.py`; the other games' maps are mounted under `maps_extra/` and converted on load. **The detail is in [docs/](docs/README.md).** Never name the game this one is modelled on in anything public: a commit, a doc, a string a player sees.

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/design.md](docs/design.md) | roles and their secrecy, the draw, the weapon, the gun, blood, win conditions, bots, maps from other games |
| [docs/doors.md](docs/doors.md) | `mm_doors.gd`, the use key, anything that moves in a map |
| [docs/testing.md](docs/testing.md) | adding a check, believing a green run, rendering |
| [docs/history.md](docs/history.md) | a bug that "cannot be happening" |

## Layout

| Path | What |
| --- | --- |
| `game/mm_game.gd`, `mm_rules.gd` | the simulation: the draw, grace and play, the weapon, the gun and its drops, blood, falls, doors, toys, the decision; a `DotMatchRules` whose outcome is whatever `MmGame` decided |
| `game/mm_weapons.gd` | the murderer's weapons (knife, cleaver, axe, bat, sword): name, reach, cooldown and the box parts drawn in a hand |
| `game/mm_map_doc.gd`, `mm_map.gd`, `mm_doors.gd`, `mm_catalogue.gd` | what a map is (boxes, props by catalogue id, lights, doors, toys, spawns), validated, and the conversion of Hide & Seek, Prop Hunt and Playground documents; a map built; the doors; every map the server has and the built-in practice house |
| `game/mm_props.gd`, `mm_materials.gd` | the prop catalogue (`props/catalogue.json`) and each prop's collision pieces (`props/pieces.json`); surfaces |
| `game/mm_player.gd`, `mm_controller.gd` | one person (body, role, weapon drawn, gun, blood, cooldown); `DotFpsController` with the HOLD modifier |
| `game/mm_config.gd`, `mm_paths.gd` | every rule a round is played under; `rebase` for pack delivery |
| `game/mm_module.gd`, `mm_services.gd`, `mm_vote.gd`, `mm_progress.gd`, `mm_spectate.gd`, `mm_server.gd` | the `DotGameModule` (cvars, `mm_status`/`mm_roles`/`mm_maps`/`mm_map`/`mm_net`, stand-ins, delivered maps); chat/voice/moderation; the map vote; dot-stats and achievements; spectating |
| `game/net/` | the codec (HELLO, MAP, ROLE, SHOT, GUN, DOOR, TOYS…), link, player behaviour, `mm_toy_net.gd`, the bridge |
| `game/mm_client.gd`, `mm_hud.gd`, `mm_audio.gd`, `mm_figure.gd`, `mm_avatars.gd`, `mm_bindings.gd`, `mm_settings.gd`, `mm.tscn` | the client: first person, F5 for third; keys as dot-menu bindings; the Escape menu |
| `game/mm_bots.gd`, `mm_bot_chat.gd` | the stand-ins by role on dot-bot and dot-npc-ai's annotations; their canned lines |
| `props/`, `assets/props/`, `art-src/` | `kits.json`, the measured `catalogue.json` and `pieces.json`; vendored Kenney models (CC0), twenty-two furniture ones rebuilt by `art-src/build_props.py` (stock copies in `art-src/base/`, `.gdignore`d; rerun it, then `measure_props.gd -- --check`) |
| `maps/`, `maps_extra/` | links: `../murder-mystery-maps/maps`; `hide-n-seek`, `prop-hunt`, `playground` to those games' map packs |
| `examples/` | `headless_run`, `headless_maps`, `headless_bots`, `headless_net`, `dedicated` |
| `tools/` | `shot.sh` (render a view: `cover` the loading cover, `grace`, `bystander`, `murderer`, `gunner`, `stab`, `shot`, `blood`, `end`, `ragdoll`, `door`, `spots`, `overview`, `room`), `camera_check.sh`, `audio_probe`, `measure_props.gd`, `load_probe.gd` |

## Running and testing

- **Per-map rules**: `cfg/game/game-murder-mystery/dot_map/map/<name>.yml` (globs such as `mm_%.yml`; operator overrides in `cfg/server/game/...`) set the `mm_*` rules in `game/mm_map_config.gd`'s whitelist, applied on every map change and restored on the next (`DotGameMapConfig`, dot-game's docs/map-config.md). The game has no movement cvars, so the client mirrors nothing. `headless_mapcfg` checks it.

- `./game.sh soak [map] [minutes]` runs the bot soak ([soak](docs/soak.md)).
- `./game.sh` plays offline; `./game.sh online` runs a local server and browser client; `./game.sh test` parses and runs all six suites (`./game.sh test headless_net` for one). On the VMs every run goes through `heavy -- …`. [testing](docs/testing.md)
- `headless_maps` audits our own maps whole and every mounted foreign map for what conversion needs (it builds, fits the wire, spawns clear, a round starts); it needs `maps/` linked and says so when it is not.
- `headless_bots` plays whole rounds of stand-ins on four maps and holds them to bands; `-- --rounds N`, `MM_BOTS_TRACE=1`.
- After adding a model, `godot --headless --path . --script tools/measure_props.gd` rewrites both `props/` files; `-- --check` compares them.
- **Render after touching what anyone sees** (`tools/shot.sh`, under xvfb); frames go to `screenshots/` (ignored) and are looked at, not only saved.

## Rules

- **Roles are secret on the wire, not only on the screen.** TEAM and JOIN carry `MmNetBridge.public_side()` (everybody a bystander); ROLE goes to its owner alone (`_tell_role`); DEATH's `by` is always 0; the spectate camera gets no killer; there is no team chat. What is meant to be seen crosses: a weapon drawn, a gun in a hand, blood, a shot's tracer, a gun on the floor. `headless_net` checks every one. [design](docs/design.md#roles-are-secret)
- **A stab and a shot are the server's measurement** (`stab_target`: horizontal reach from the eye, a cone, nothing solid between; `shot_target`: a ray to the first wall). A client sends movement and three buttons (`USE`, `ATTACK`, `HOLSTER` = `BUTTON_USER_0..2`), nothing a kill could come from.
- **No weapon in the grace**: `set_weapon_drawn` refuses with a line, and `attack_now` needs PLAY, the cooldown, and `draw_seconds` since the draw.
- **A miss drops the gun** (`drop_on_miss`) at the shooter's feet, and they may not pick one up again this round (`gun_banned`); a murderer never may. A drop below the map goes to a spawn.
- **Shooting a bystander** drops the gun too (`drop_on_innocent`) and, with `innocent_kills_shooter`, kills the shooter.
- **Blood** is `MmGame._advance_blood`: none until `blood_seconds` before the end, then `blood_stages` steps to the whole at the buzzer, plus one a kill with `blood_per_kill`. It is 0..7 on the wire (`net_blood`), everybody's.
- **A fall is a respawn**, gun kept, never a death; a joiner during PLAY is benched (watching) until the next draw.
- **The draw**: murderers by `DotTeamRotation` RANDOM over a history (nobody twice running when anybody else can be), gunners at random from the rest. `forced_roles` overrides it for a suite or an operator; it is empty in play.
- **A bot knows of a person only by its own eyes and ears** (`MmBots._sees`, the deaths it saw or heard); a murderer bot knows its fellow murderers and nothing else. Never hand a bot the server's truth about roles.
- People do not collide with people.
- The client's platform layer (cover, settings, console, Tab, M, pointer, input block) is dot-game's `DotGameClient`, `MmClient.platform`; a suite waits for `platform.is_shown()` and presses Tab through `settings.menu.handle_event`.
- **Holding still is the `HOLD` modifier in the movement state**, never a timer the game checks, so the client predicts it exactly.
- **A READY before the player is seated is kept** (`_ready_unseated` in the bridge) and answered by `add_player`; `headless_net` sends it first (armed). [history](docs/history.md)
- Players and bots are dot-player-char's people (`MmFigure`); the shirt is a colour per person, never a side colour, since sides are secret.
- **Toys** and **doors** are as in game-hide-n-seek: toys paired across the wire by index (TOYS after MAP; mirrors registered on TOYS whether the map is built or not); door state is `(open, since, flip)` and only a `DOOR` use is sent. [doors](docs/doors.md)
- **Maps from other games are converted, not copied**: `MmMapDoc` reads `hideseek_map`, `prophunt_map` and `playground_map` (`FOREIGN_KINDS`), pools their spawns into `players` and marks `imported_from`. Mount a pack under `maps_extra/<game>`; never copy its files in.
- The HUD follows the menu's theme and HUD size (`MmHud.follow_menu`); `headless_run` checks a theme change reaches the clock and the lines.
- **H is help** (`MmSettings._fill_help` writes the goal and rules) and **M is the map list** (`MmGame.map_rows()`, `change_map_now()`); nothing in `MmBindings` may default to either. `headless_run` checks both.
- **Delivery**: no `class_name` in `game/`; every own `res://` path through `MmPaths.rebase()`. Maps are their own pack, named by the server owner's map config and fetched by `MmModule._add_delivered_maps`; the game's own pack carries only `mm_practice`.
- `mm_roles` lists who is what, and answers only the server's own console.
- `project.godot` carries no comments (the editor drops them). Gravity is `MmConfig.gravity`, written onto the world's own physics space.
- `MmEvent.MAX_BODY` holds the largest MAP (`MmEvents.MAP_BYTES`); `headless_net` checks it (armed).
- The dot-game API used is its committed one; the platform reports the client's cover to the server (docs/design.md, "Still loading").

## Not yet done

1. **Put it live.** No remote, nothing pushed. dot-server-deploy has no content entries for `murder` or `murder_maps`, and dot-bootstrap's `projects.tsv` does not list this repository or murder-mystery-maps, so neither is linked or deployed by the tools yet.
2. **Lag compensation is off** (`enable_lag_compensation = false`): a shot is measured against where people are on the server's tick, not where the shooter saw them. dot-net has it; it wants a browser test with real latency first.
3. **Play it with people**: the weapon reach, the gun cooldown, the grace and the blood timing are numbers only play settles.
