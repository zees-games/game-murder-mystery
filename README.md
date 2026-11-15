Murder Mystery is a 3D multiplayer game of hidden roles. Everybody looks the same. One or two players are **murderers**. Everybody else is a **bystander**, and one or two bystanders also carry a **gun** with a single shot. Nobody knows anybody's role but their own. Find out who the murderer is before they get to you.

It is built on [Godot 4](https://godotengine.org/), the [Dot collection](https://moddingcommunity.com/co/4-dot-assets) and [TMC's gaming platform](https://moddingcommunity.com/play).

Everything in this repository is open source under the MIT license. The only closed part is the website back-end it can sign in through. If you do not want to use TMC's platform, you can plug in your own sign-in back-end.

The game was built with Claude Code and is maintained with it. It has a full automated test suite, but few real players have tried it yet, so expect rough edges. Please report what you find, and tell the maintainer if you want to help.

## How it plays

Each round starts with a short grace period (10 seconds by default). Everybody is told their own role, and only their own, and scatters. No weapon can come out yet. Then the round runs for 3 minutes by default.

- **Bystanders** carry nothing. Stay with other people, watch who wanders off alone, and keep away from anybody with something in their hand.
- **The gunner** is a bystander with a gun. One shot, then a few seconds to reload. A miss drops the gun where you stood, and you cannot pick one up again this round. Any other bystander can walk onto it and take it. Shooting an innocent bystander drops it too.
- **The murderer** carries a knife (or the weapon the server picked: cleaver, axe, bat or sword). It is put away at first and nobody can see it. Press **Q** to draw it, and everybody near you can then see it. Get somebody alone, draw, and strike at arm's length.
- **Blood.** In the last minute, blood starts to show on the murderer, and more with every kill.
- **Doors.** Press **E** at a door to open or shut it. A shut door blocks knives and bullets.
- **Toys.** Every map has things to kick, push and press.
- **Falling** off the map puts you back at a spawn point.

The bystanders win if every murderer is dead, or if the clock runs out with a murderer still alive. The murderers win if nobody else is left. At the end of the round everybody is told who the murderer was.

By default a win is worth 10 points to everyone on that side, a kill 5, shooting a murderer 15 and surviving 5. Kills, deaths, innocents shot and the rest go to your stats and the TMC leaderboards.

The murderer is picked at random, and never the same person twice in a row when someone else could be. Players who join during a round watch until the next one.

## Maps

The game ships a small practice house, so a server with no maps still works. The rest come from [murder-mystery-maps](https://github.com/zees-games/murder-mystery-maps): 3 maps made for this game and 14 converted from community maps. See that repository for the full list and credits.

| Map | What it is |
| --- | --- |
| Practice house | A small house with a kitchen, a living room and a garden with toys (built into the game) |
| Blackwood Mansion | A dark two-storey house with a hall, a library, a cellar and grounds |
| Lonely Pines Motel | A roadside motel at dusk: rooms off an outside walkway, an office, a diner and a back lot |
| Open Yard | A big grass yard with a long hall, a three-storey office tower and a pool |
| Converted maps | 14 more, for example Greenwood Estate, Airbus, Warehouse and Mountain Resort |

The maps of Hide & Seek, Prop Hunt and Playlot also work here. The game reads their map packs as they are from `maps_extra/` and starts everybody at the spawn points.

## Controls

| Key | Action |
| --- | --- |
| WASD / mouse | Move and look |
| Shift | Sprint |
| Alt | Walk quietly |
| Ctrl | Crouch |
| Space | Jump |
| Mouse 1 | Stab (murderer, weapon drawn) or shoot (with the gun) |
| Q | Draw or put away the weapon (murderer) |
| E | Open or shut a door; kick, push or press the toy you are looking at |
| V | Talk (voice, heard by people near you) |
| F | Flashlight for everybody still in the round. A lit beam can be seen by anyone who can see you, a hiding murderer included. |
| F5 | First or third person |
| G | Free camera, once you are out of the round |
| Y | Chat |
| Tab (hold) | Scoreboard |
| H | Help: the goal, the rules and every key as you have it bound |
| M | The map list (the server's owner picks the map; everyone else votes) |
| Esc | Menu: settings (every key can be rebound), help and leave |

## Getting started

You need [Godot 4.7](https://godotengine.org/download). The game uses many Dot addons, each in its own repository. The easiest way to get everything is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap), which lists this game in its project table. It clones each project and links the addons and map packs into it. Then:

```bash
cd projects/game-murder-mystery
./game.sh
```

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline against bots |
| `./game.sh online` | Start a local server and the browser client, and print the link to open |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite (`./game.sh test headless_net` for one) |
| `./game.sh shot` | Save a screenshot to `screenshots/` (`tools/shot.sh` lists the views) |
| `./game.sh help` | List all options |

## Running a server

Settings are console variables ("cvars"). Set them in the server's config, on the command line, or live from the console. Most take effect from the next round. All are listed in `game/mm_config.gd` with their defaults, and each can also be given as an option, for example `--mm-round-seconds=240` or `--mm-murderer-weapon=axe`. `--mm-map-ids=<ids>` limits a server to some maps.

| Setting | Default | What it does |
| --- | --- | --- |
| `mm_grace_seconds` | 10 | Seconds at the start with roles told and no weapons |
| `mm_round_seconds` | 180 | How long a round is played |
| `mm_players_per_murderer` | 12 | One murderer for every this many players |
| `mm_min_murderers` / `mm_max_murderers` | 1 / 2 | Fewest and most murderers (most 0 = unlimited) |
| `mm_players_per_gunner` | 12 | One gun for every this many players |
| `mm_min_gunners` / `mm_max_gunners` | 1 / 2 | Fewest and most guns (most 0 = unlimited) |
| `mm_murderer_weapon` | `knife` | `knife`, `cleaver`, `axe`, `bat` or `sword` |
| `mm_melee_range` | 0 | Metres a stab reaches (0 = the weapon's own) |
| `mm_melee_cooldown` | 0 | Seconds between stabs (0 = the weapon's own) |
| `mm_melee_cone` | 40 | Degrees either side of the aim a stab still lands |
| `mm_draw_seconds` | 0.35 | Seconds after drawing before a stab lands |
| `mm_gun_cooldown` | 3 | Seconds between shots |
| `mm_gun_range` | 120 | Metres a shot reaches |
| `mm_drop_on_miss` | 1 | A miss drops the gun |
| `mm_drop_on_innocent` | 1 | Shooting a bystander drops the gun |
| `mm_innocent_kills_shooter` | 0 | Shooting a bystander also kills the shooter |
| `mm_pickup_range` | 1.1 | Metres from a dropped gun that picks it up |
| `mm_blood_seconds` | 60 | Blood starts this long before the end (0 = never) |
| `mm_blood_stages` | 4 | Number of blood steps |
| `mm_blood_per_kill` | 1 | One step more for each kill |
| `mm_murderer_speed` | 1.05 | The murderer's speed compared with everybody else's |
| `mm_doors` | 1 | 1 = E opens and shuts doors |
| `mm_rounds_per_map` | 3 | Rounds on a map before the next one |
| `mm_max_unlag_ms` | 1000 | Most a shot may be compensated for the shooter's lag (0 = off) |
| `mm_bot_chat` | 1 | Bots say things |
| `mm_autobhop` | 0 | 1 = hold jump to keep hopping |
| `bot_quota` | 6 | Bots keep the round at this many players; each person who joins replaces one |
| `mm_vote_after` | 20 | Seconds into a map's last round before the vote opens |
| `mp_forcecamera` | 0 | Who a player who is out may watch: 0 anybody, 2 nobody (1 is own side) |
| `mp_freeroam` | 1 | 1 = a player who is out may fly a free camera |
| `mp_freeroam_speed` | 8 | Free camera speed in metres per second |

Console commands:

| Command | What it does |
| --- | --- |
| `mm_status` | The round, the map, and how many are alive |
| `mm_roles` | Who is what this round (the server's own console only) |
| `mm_maps` | The maps the server has, and any it refused (with the reason) |
| `mm_map <id>` | Play this map next |
| `mm_reload` | Read the map folder again, for the next map |
| `mm_say <text>` | Say something to everybody, as the server |
| `mm_net` | What the network code is doing |

Admin commands come from [dot-moderation](https://github.com/modcommunity/dot-moderation).

## Testing

| Suite | What it covers |
| --- | --- |
| `headless_config` | The settings and their config files |
| `headless_workbench` | The F9 workbench rows |
| `headless_mapcfg` | Per-map config files |
| `headless_run` | The game itself: draw, grace, weapon, gun and its drops, blood, winning, falls, joiners, doors, toys, bots, help and the map menu |
| `headless_maps` | The maps in full, and every Hide & Seek, Prop Hunt and Playlot map for what playing it here needs |
| `headless_bots` | Bots play whole rounds against each other |
| `headless_net` | A server and a client in one process: roles stay secret on the wire, stabs, shots, dropped guns, doors, toys |
| `dedicated` | A real server: boots, loads the game, runs its commands, a round of bots, the map vote |

[`CLAUDE.md`](CLAUDE.md) has the contributor rules and [docs/](docs/README.md) the reasoning.

## Known gaps

- Not yet tried in a browser with many people. The weapon reach, gun cooldown and blood timing are first guesses.
- The round sounds are made in code and are placeholders.

## Credits

| Asset | Author / source | License |
| --- | --- | --- |
| Furniture (72 models rebuilt with their own palette) | Kenney, Furniture Kit, via `art-src/build_props.py` (see `assets/props/furniture/CREDITS.md`) | CC0 |
| Trees, plants, rocks | Kenney, Nature Kit; colours toned down at load | CC0 |
| The two climbing trees | Made for this game in the Nature Kit's style, `tools/climb_trees.py` | CC0 |
| Players | Quaternius, [Zombie Apocalypse Kit](https://quaternius.com/packs/zombieapocalypsekit.html), skinned from Kenney's blocky kit ([kenney.nl](https://kenney.nl)), via dot-player-char | CC0 1.0 |
| Converted maps: floors, walls, ceilings, roofs | [Poly Haven](https://polyhaven.com) and [ambientCG](https://ambientcg.com) photographs, resized to 512 px (see `assets/polyhaven/License.txt`) | CC0 |
| Hand-built maps: floors, walls, roofs | Kenney, Prototype Textures under a pastel | CC0 |
| Hollow Hill's flooded cellar | ambientCG [Foam003](https://ambientcg.com/a/Foam003), tinted blue-green | CC0 1.0 |
| Glass, boards, lockers, lines | Drawn in code | None needed |
| Fog, sun, sky, snow and ambience of converted maps | Each map's own settings; sound is dot-audio's stock only | CC0 |
| Footsteps | Kenney, Impact Sounds (see `addons/dot_audio/stock/CREDITS.md`) | CC0 |
| Ambience beds | Generated by dot-audio | CC0 |
| Toys | [dot-props](https://github.com/modcommunity/dot-props), drawn in code; sounds from Kenney (Impact, Interface, Foley, Digital Audio) plus a horn made for it (see `addons/dot_props/toys/sounds/CREDITS.md`) | CC0 |
| Death sounds | Kenney, via dot-player-char | CC0 |

If you made one of these maps or assets and want it removed, open an issue.

## License

MIT. See [LICENSE](LICENSE). The Kenney art is CC0, which is public domain.
