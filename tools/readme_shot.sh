#!/usr/bin/env bash
# The README screenshots, 1280x720 on a real GPU (the name matches gpu.sh's tools/*_shot.sh rule, so
# `heavy -- tools/readme_shot.sh` renders on staging02/staging, never llvmpipe). Frames land in screenshots/readme/.
# Prints the renderer line of each run: check it names a GPU before trusting a frame.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots/readme
run() { # name, then shot.sh arguments
	local name="$1"; shift
	tools/shot.sh --renderer="${README_RENDERER:-forward_plus}" --name="$name" --out="res://screenshots/readme/${name}.png" "$@" 2>&1 \
		| grep -E 'Vulkan|OpenGL API|ERROR' | head -3
}
run role-bystander --view=grace
run role-murderer --view=murderer --seconds=2
run role-gunner --view=gunner --seconds=2
run stab --view=stab --seconds=0.6
run body --view=ragdoll --seconds=1.2
run round-end --view=end --seconds=2
run scoreboard --view=bystander --board
run map --view=overview --mm-map-ids=mm_mansion
run door --view=door
ls screenshots/readme
