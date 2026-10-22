# Bot soak

`./game.sh soak [map] [minutes]` runs `tools/soak.tscn`: eight stand-ins (`game/mm_bots.gd`) play rounds on one map of a real `MmGame` (round 150 s, grace 8 s, 32 Hz), driven by dot-bot's `DotBotSoak` with dot-spawn's `DotSpawnWatch` for stuck and fell-out verdicts. The report is `.godot/test-logs/soak-<map>.json` and one `SOAK {...}` line; the exit code is 1 on failure. It needs the gitignored `addons/dot_spawn` link and a `godot --import`.

A bot counts as moving for the watch only in PLAY, alive, with a goal more than 1.5 m away: one standing about at its goal (loitering, a murderer waiting for a clean moment) is not stuck. There is no navigation query here, so off-nav and unreachable are off. Kills are the murderers' (a fall is a respawn, never a death) and the harness's "zero kills" check stays on after 120 s.

First run, 2026-10-22, seed 1, 8 bots. mm_mansion 3 min passes (p95 tick 2.9 ms, worst 196 ms is the map load, object and memory growth under 0.2%). 2 min each on the others:

- mm_motel: fails, a bot (u907) stuck for 83 s by the watch and 91 s by the bot's own `longest_stuck`: a real trap, not loitering.
- hs_manor: fails, u900 stuck 17.5 s by the watch (the bot's own measure says 1 s).
- ph_house: fails, u904 stuck 29.5 s by the watch (the bot's own measure 0) and zero kills in 120 s, so a murderer that never got a clean moment, or a goal it could not reach.

Left as findings, not fixed: where in motel the bot sits (`MM_BOTS_TRACE=1`, `headless_bots -- --map mm_motel`), whether the hs_manor and ph_house watch verdicts are bots turning on the spot at a door, and the ph_house murderer. Other mounted maps (the rest of `maps_extra/`) are not soaked.
