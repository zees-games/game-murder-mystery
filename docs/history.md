# History

Kept because each could come back.

## This game

- **A ROLE lost between two rounds in `headless_net`**: the suite cleared what it had heard once the round number went up, but the owner's ROLE can arrive on the same tick the new round starts, so the clear wiped it and the "told its own role" check failed for a role that had been sent. `_into_play` clears before it calls `_decide`. Clear a suite's record before the event that fills it, never after.

## Inherited from game-hide-n-seek, still true here

The maps, doors, bots' walking and the net bridge came from game-hide-n-seek; these stories are about that code and still apply.

- **A check made after intermission 0 had already redrawn the round**: check before the step that crosses a round boundary.
- **`dedicated` failed one run in three once doors were in**: a wall-clock bound, with stand-ins taking most of the round to open a garden door. Server rounds are bounded in server ticks.
- **Two doorways nobody could use** (a sofa in one, a fence across another), found by `headless_maps` the moment there were doors. It walks every doorway of our maps; a foreign map's fix goes to its own repository.
- **Every building's floor striped with the grass under it**: both tops at y 0. Found by rendering; a floor sits above the ground it stands on.
- **A bot frozen in mid-air beside an open door**: beside the wall and the panel at once, the controller's slide gave up every tick. Fixed in dot-player-controller (`_split_leg`, `_resolve_planes`); a suite round where a bot never moves is the first sign.
- **Bots pressed into the corner behind an open door for half a minute**: the navigation mesh is baked without doors, so a path ran straight through an open panel, and a step aside and back counted as moving, so the unstick never gave up. Bots walk round an open panel's free edge (`MmBots._door_detour`), shut one with no room round it, and give a place up after circling the same door twice or being stuck three times within 1.5 m. Three broad fixes (shutting sooner, a wider mesh radius, every path through a doorway's middle) each made it worse; judge a bot change on many seeds, never on the worst one.
- **A READY that overtook the seat was dropped (2026-10-12).** Through a lossy link a client's READY can reach the server before the seat it answers; `_admit` found no player and nothing asked again, so the client never got a world. Loopback and WebSocket order the two, so `headless_net` sends the READY before the seat on purpose.
- **Q and the click did nothing in solo play (2026-10-20).** `MmBots.drive` set `wants_attack` and `wants_holster` false for every player that was not a live bot, the person included. Offline the client writes those fields in its physics tick and the world reads them later in the same tick, with the bots' drive in between, so the knife was never drawn and never swung (a server was unaffected: the bridge sets them just before the hands). `headless_run`'s client section now holds the real `mm_holster` action through the client and checks the knife is drawn and in the first-person hand. The client's keyboard actions (use, holster) also no longer wait for the pointer capture (`_key_held`), which a browser grants only on a click.
