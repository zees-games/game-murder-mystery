# Testing

`./game.sh test` parses every script and runs all five suites; `python3 ../murder-mystery-maps/tools/build_maps.py --check` confirms our maps are what the builder writes. On the VMs every run goes through `heavy -- …`, one suite at a time.

| Suite | What it covers |
| --- | --- |
| `examples/headless_run` | the simulation, in 24 sections: the config and its checks, the catalogue and documents, the draw (forced roles, nobody murderer twice running, shirts), the grace (no draw, no fire), drawing and holstering by the key, the stab (the draw beat, out of reach, the cooldown, behind, through a wall and a shut door, armed), a hit, a miss (the drop, the ban, who may pick it up, a dead gunner's drop), an innocent shot, blood at its stages, the round won both ways and on time, falls, joiners, progress, bot chat, bots, doors, toys, the client's view (its role, the strip, the theme, the ragdoll, the death codec, the door prompt), help and the map menu, the weapons table |
| `examples/headless_maps` | our own maps whole (validated, built, every door swung, every doorway walked, spawns clear, enough spawns and cover, toys still); then every mounted Hide & Seek, Prop Hunt and Playground map: converted, built as this kind, fits the wire, props known, spawns clear, a round starts with one murderer |
| `examples/headless_bots` | eight stand-ins play whole rounds (8 by default, two a map over `mm_mansion`, `mm_motel`, `hs_manor`, `ph_house`) and the suite holds them to bands: the murderer kills in most rounds and does not win them all, somebody fires, a dropped gun is fetched, draws are not far over stabs, the bystanders keep together and talk, nobody stays stuck |
| `examples/headless_net` | over a loopback, in two physics worlds: the codec, the join, the map; roles secret (the client is told its own and nobody else's, the murderer is a bystander to it, a holstered weapon is not seen and a drawn one is, a gun in a hand is); prediction against the server and a door; a stab crossing as a death by nobody with no spectate killer; a miss, the drop and a pickup; the round's end naming the murderer; toys; a client without the map |
| `examples/dedicated` | a real server: the module, the console (`mm_status`, `mm_maps`, cvars writing through), a round played by stand-ins, the bot quota, the map vote, `mm_roles` on the server's console |

`-- --rounds N`, `-- --first N`, `-- --map ID` (every round on one map), `-- --difficulty hard` and `MM_BOTS_TRACE=1` steer `headless_bots`; its bands are first measurements, widened only with a reason written beside them.

## Rules

- **Sections and checks are both counted**, and a suite whose counts are off exits 1: a section that aborted part-way otherwise passes.
- **Without `maps/` linked** (CI clones this repository alone), `headless_maps` checks the practice house only and `headless_bots` plays it, and both say so.
- **Force the roles in a suite** (`MmGame.forced_roles`), never set sides by hand: the draw is what tells the owner its ROLE, gives the gun and resets blood.
- **Check before stepping across a round boundary**: with intermission 0 the next round starts on the tick the last one ends.
- **Bound a server round in server ticks**, with the wall clock only as a cap for a server that stopped.
- Every claim that crosses the wire is checked on the client's copy, not the server's: a role kept secret on the server and leaked by the snapshot is a leak.

## Renders

`tools/shot.sh --view=<view>` under xvfb, with `--mm-map-ids=<id>`, `--at=x,y,z --look=x,y,z`, `--third`, `--board`, `--doors=open`, `--seconds=`. The views: `overview`, `room`, `grace`, `bystander`, `murderer`, `gunner`, `stab`, `shot`, `blood`, `end`, `ragdoll`, `door`, `spots`. Frames go to `screenshots/` (ignored); look at each one. `--headless` gives a null renderer and saves a frame of nothing, so never render without xvfb.
