# Murder Mystery

This is a game to demonstrate the capabilities of the [**Dot collection**](https://moddingcommunity.com/co/4-dot-assets) built on-top of [Godot 4](https://godotengine.org/) and [TMC's gaming platform](https://moddingcommunity.com/play). In this 3D game everybody looks the same, and one or two of them are **murderers**. Everybody else is a **bystander**, and one or two bystanders also have a **gun** with a single shot. Nobody knows anybody's role but their own: find out who it is before they get to you.

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## How it plays
Each round starts with a short **grace**. Everybody is told their own role, and only their own, and scatters; no weapon can come out yet. Then the round has 3 minutes.

- **Bystanders** carry nothing. Stay with other people, watch who wanders off alone and who you last saw near a body, and keep away from anybody with something in their hand.
- **The gunner** is a bystander with a gun. One shot, then a few seconds to reload. **A miss drops the gun** on the floor where you stood, and you cannot pick one up again this round; any other bystander can walk onto it and take it. Shoot an innocent bystander and you drop it too.
- **The murderer** carries a knife (or whatever weapon the server picked: a cleaver, an axe, a bat, a sword). It is put away by default and nobody can see it; press **Q** to draw it and everybody near you can. Get somebody alone, draw, and strike at arm's length.
- **Blood.** In the last minute, blood starts to show on the murderer, and more with every kill. A murderer who waited too long is marked.
- **Doors.** Press **E** at a door to open or shut it. A shut door is a wall, to a knife as much as to a bullet.
- **Toys.** Every map has things to kick, push and press, from the family's toys.
- **Falling** off the map puts you back at a spawn point.

The bystanders win if every murderer is dead or the clock runs out with any of them alive. The murderers win if nobody else is left. At the end of the round everybody is told who the murderer was. Winning is worth 10 points to everyone on that side, a kill 5, shooting the murderer 15 and surviving 5. Kills, deaths, heroics, innocents shot, guns picked up and the rest go to your stats and the leaderboards on TMC.

The murderer is drawn at random, never the same person twice running when somebody else can be. Somebody who joins while a round is being played watches until the next one.

## Maps
Three maps are this game's own: a small practice house built into the game, and two from [murder-mystery-maps](../murder-mystery-maps):

| Map | What it is |
| --- | --- |
| **The practice house** | A small house with a kitchen, a living room and a garden with toys |
| **Blackwood Mansion** | A dark two-storey house with a hall, a library, a cellar and grounds round it |
| **Lonely Pines Motel** | A roadside motel at dusk: rooms off an outside walkway, an office, a diner and a back lot |

Every Hide & Seek, Prop Hunt and Playground map is playable too: the game reads those games' map packs as they are, mounted under `maps_extra/`, and starts everybody at their spawn points.

## Controls

| Key | Action |
| --- | --- |
| **WASD** / mouse | Move and look |
| **Shift** | Sprint |
| **Ctrl** | Crouch |
| **Space** | Jump |
| **Mouse 1** | Stab (murderer, weapon drawn) or shoot (with the gun) |
| **Q** | Draw or put away the weapon (murderer) |
| **E** | Open or shut a door; kick, push or press the toy you are looking at |
| **V** | Talk (voice, heard by the people near you) |
| **F5** | First or third person |
| **Tab** | Scoreboard (hold) |
| **H** | Help: the goal, the rules and every key as you have it bound |
| **M** | The map list (the server's owner changes the map; anybody else votes) |
| **Esc** | Menu: settings (every key above can be rebound), help, and leave |

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The game is built from many Dot addons, each in its own repository; symlink each one listed in `.gitignore` into `addons/`, `../murder-mystery-maps/maps` into `maps/`, and the other games' map packs into `maps_extra/hide-n-seek`, `maps_extra/prop-hunt` and `maps_extra/playground`. [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap) does not know this game yet.

`game.sh` does everything else:

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline against bots |
| `./game.sh online` | Start a local server and the browser client, and print the link to open |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite (`./game.sh test headless_net` for one) |
| `./game.sh shot` | Save a screenshot to `screenshots/`. `tools/shot.sh` lists the views |
| `./game.sh help` | All of the options |

## Running a server
Settings are cvars. Set them in the server's config, on the command line, or live from the console. Most of them take effect from the next round.

```
mm_grace_seconds 10            // seconds at the start with roles told and no weapons
mm_round_seconds 180           // how long a round is played
mm_players_per_murderer 12     // one murderer for every this many players
mm_min_murderers 1             // never fewer
mm_max_murderers 2             // never more
mm_players_per_gunner 12       // one gun for every this many players
mm_min_gunners 1
mm_max_gunners 2
mm_murderer_weapon knife       // knife, cleaver, axe, bat or sword
mm_melee_range 0               // metres a stab reaches (0 = the weapon's own)
mm_melee_cooldown 0            // seconds between stabs (0 = the weapon's own)
mm_melee_cone 40               // degrees either side of the aim a stab still lands
mm_draw_seconds 0.35           // seconds after drawing before a stab lands
mm_gun_cooldown 3              // seconds between shots
mm_gun_range 120               // metres a shot reaches
mm_drop_on_miss 1              // a miss drops the gun
mm_drop_on_innocent 1          // shooting a bystander drops the gun
mm_innocent_kills_shooter 0    // shooting a bystander kills the shooter too
mm_pickup_range 1.1            // metres from a gun on the floor that picks it up
mm_blood_seconds 60            // blood starts this long before the end (0 never)
mm_blood_stages 4              // in this many steps
mm_blood_per_kill 1            // and a step more for each kill
mm_murderer_speed 1.05         // the murderer's speed against everybody else's
mm_bot_chat 1                  // bots say things
mm_doors 1                     // 1 = E opens and shuts doors
mm_rounds_per_map 3            // rounds on a map before the next one
mm_spectate_camera 0           // deprecated, sets mp_forcecamera
mp_forcecamera 0               // who somebody who is out may watch: 0 anybody, 2 nobody (1, own side, is anybody here)
mp_freeroam 1                  // 1 = whoever is out may fly a free camera (G)
mp_freeroam_speed 8            // metres a second; Sprint is faster, Walk slower
mm_autobhop 0                  // 1 = hold jump to keep hopping
bot_quota 6                    // players a round is kept at with bots; each person who joins replaces one
mm_vote_after 20               // seconds into a map's last round before the vote opens
```

`--mm-map-ids=<ids>` limits a server to some maps, and every setting in `game/mm_config.gd` can be given the same way (`--mm-round-seconds=240`, `--mm-murderer-weapon=axe`).

Console commands:

| Command | |
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
| `headless_run` | The game itself: the draw, the grace, the weapon, the gun and its drops, blood, winning, falls, joiners, doors, toys, bots, help and the map menu |
| `headless_maps` | Our maps in full, and every Hide & Seek, Prop Hunt and Playground map for what playing it here needs |
| `headless_bots` | Bots play whole rounds against each other; who kills, who shoots, who wins |
| `headless_net` | A server and a client in one process: roles stay secret on the wire, a stab, a shot, a dropped gun, doors, toys |
| `dedicated` | A real server: boots, loads the game, runs its commands, a round of bots, the map vote |

[`CLAUDE.md`](CLAUDE.md) has the rules and [docs/](docs/README.md) the reasoning.

## Not done yet
- Shots are not lag-compensated: you aim at where somebody was on your screen, the server measures where they are.
- The game is not in dot-bootstrap or dot-server-deploy yet, so it is not deployed anywhere.
- Not yet tried in a browser with people; the weapon reach, the gun cooldown and the blood timing are first guesses.
- The round sounds are made in code and are placeholders.

## Credits
The furniture is Kenney's Furniture Kit (CC0); ten of its models (plant, chairs, island, desk, bookcase, carton, bedside table, bin) are rebuilt for this game with their own palette and added parts by `art-src/build_props.py`, credited in `assets/props/furniture/CREDITS.md`. The trees, plants and rocks his Nature Kit (the two climbing trees are this game's own, made in that kit's style by `tools/climb_trees.py`, CC0 like it), the players are the family's people from Quaternius' [Zombie Apocalypse Kit](https://quaternius.com/packs/zombieapocalypsekit.html) (CC0 1.0, credited in dot-player-char), chosen by the blocky kit's skins ([kenney.nl](https://kenney.nl), CC0). The Nature Kit's colours are toned down when the game loads them. The converted maps' floors, walls, ceilings and roofs are CC0 photographs from [Poly Haven](https://polyhaven.com) and [ambientCG](https://ambientcg.com), resized to 512 px (diffuse and normal only), each credited with its URL and author in `assets/polyhaven/License.txt`; the hand-built maps' remaining floors, walls and roofs are Kenney's Prototype Textures under a pastel; glass, boards, lockers and lines are drawn in code, and Hollow Hill's flooded cellar is ambientCG's [Foam003](https://ambientcg.com/a/Foam003) (CC0 1.0) tinted blue-green. The converted maps' fog, sun, sky, snow and ambience come from each map's document (`environment`, `weather`, `ambience`, `ambience_indoor`); the sound is dot-audio's CC0 stock only. Each kit's licence is next to its files. Footsteps are Kenney's Impact Sounds and the ambience beds are generated by dot-audio, both CC0 and shipped in dot-audio (`addons/dot_audio/stock/CREDITS.md`). The toys are [dot-props](https://github.com/modcommunity/dot-props)' (drawn in code; their sounds are Kenney's CC0 Impact, Interface, Foley and Digital Audio sounds plus a horn made for it, listed in `addons/dot_props/toys/sounds/CREDITS.md`), and the death sounds are dot-player-char's (Kenney, CC0).

## License
MIT. See [LICENSE](LICENSE). The Kenney art is CC0, which is public domain.
