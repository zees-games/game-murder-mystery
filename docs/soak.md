# Bot soak

`./game.sh soak [map] [minutes]` runs `tools/soak.tscn`: eight stand-ins (`game/mm_bots.gd`) play rounds on one map of a real `MmGame` (round 150 s, grace 8 s, 32 Hz), driven by dot-bot's `DotBotSoak` with dot-spawn's `DotSpawnWatch` for stuck and fell-out verdicts. The report is `.godot/test-logs/soak-<map>.json` and one `SOAK {...}` line; the exit code is 1 on failure. It needs the gitignored `addons/dot_spawn` link and a `godot --import`.

A bot counts as moving for the watch only in PLAY, alive, with a goal more than 1.5 m away: one standing about at its goal (loitering, a murderer waiting for a clean moment) is not stuck. There is no navigation query here, so off-nav and unreachable are off. Kills are the murderers' (a fall is a respawn, never a death) and the harness's "zero kills" check stays on after 120 s.

A bot counts as walking for the watch only when `_walk_to` ran this tick (`walk_at`): a murderer within 5 m of its target holds still and looks while its goal stays where the target was, which the first run read as stuck. "Kills" are every death by another hand (a gunner shooting a murderer counts), so the zero-kills check means no fighting at all.

Runs, 2026-10-22, seed 1, 8 bots, 2 min: mm_motel, hs_manor and ph_house pass; mm_mansion 3 min passes (p95 tick 2.9 ms, worst 196 ms is the map load, growth under 0.2%).

Found and fixed: mm_motel's trap was a bot pressed into a cabin corner between the wall and a crate, where the mesh does not reach: the nav snapped the path start across the wall and the bot pushed at the wall for 90 s (`MmBots._off_mesh_start` now walks back to where the last good path began). hs_manor and ph_house were the murderer standing still (above) and, on ph_house, murderers shot before a clean moment. `./game.sh soak MAP MIN --trace` prints each bot's position, goal and state once a second (`soak trace` lines in `.godot/test-logs/soak.log`). Other mounted maps (the rest of `maps_extra/`) are not soaked.
