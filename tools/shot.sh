#!/usr/bin/env bash
# Render the game and look at it. The check no assertion in this repository makes.
#
#   tools/shot.sh --view=overview --mm-map-ids=mm_mansion         # a map, from above
#   tools/shot.sh --view=room --at=0,1.7,-6 --look=0,1,-14 --mm-map-ids=mm_motel
#   tools/shot.sh --view=cover                                    # the loading cover, before it lifts
#   tools/shot.sh --view=grace                                    # the grace: roles told, weapons away
#   tools/shot.sh --view=bystander                                # a bystander's eyes, in play
#   tools/shot.sh --view=murderer                                 # the murderer, weapon drawn
#   tools/shot.sh --view=murderer --mm-murderer-weapon=axe --third         # another weapon, from behind
#   tools/shot.sh --view=gunner                                   # a bystander with the gun
#   tools/shot.sh --view=stab --seconds=0.6                       # a stab, 0.6 s into the fall
#   tools/shot.sh --view=shot                                     # the gun fired: the tracer
#   tools/shot.sh --view=blood --seconds=4                        # the murderer with 4 of 7 blood
#   tools/shot.sh --view=end                                      # the round's end, the murderer named
#   tools/shot.sh --view=ragdoll --seconds=0.6                    # a stand-in slain, its body 0.6 s into the fall
#   tools/shot.sh --view=spots --mm-map-ids=hs_manor              # where the stand-ins wander, from above
#   tools/shot.sh --view=door                                     # at a door: the use-key prompt
#   tools/shot.sh --view=bystander --board                        # with the Tab scoreboard open
#   tools/shot.sh --view=room --doors=open --at=... --look=...    # every door open (or shut)
#   tools/shot.sh --view=overview --out=res://screenshots/x.png   # any --mm-* is the game's config
#   tools/shot.sh --view=overview --renderer=forward_plus         # another renderer (default: the project's, gl_compatibility)
#
# xvfb-run because this needs a rendering context: `--headless` gives a null renderer and saves
# a frame of nothing, which is worse than no screenshot because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots

view="bystander"
seconds="3"
out=""
config=("--mm-warmup-seconds=0" "--mm-grace-seconds=3" "--mm-intermission-seconds=0")
extra=()
engine=()

for arg in "$@"; do
    case "$arg" in
        --view=*)    view="${arg#*=}" ;;
        --seconds=*) seconds="${arg#*=}" ;;
        --out=*)     out="${arg#*=}" ;;
        --renderer=*) engine=(--rendering-method "${arg#*=}") ;;
        --mm-*)      config+=("$arg") ;;
        --at=*|--look=*|--third|--board|--name=*|--doors=*|--pick=*|--place=*) extra+=("$arg") ;;
        *)           echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

name="$view"
for e in "${extra[@]}"; do
    case "$e" in --name=*) name="${e#*=}" ;; esac
done
[ -n "$out" ] || out="res://screenshots/${name}.png"

exec xvfb-run -a -s "-screen 0 1280x720x24" "${GODOT:-godot}" --path . "${engine[@]}" --resolution 1280x720 \
    res://tools/shot.tscn -- "--seconds=$seconds" "--view=$view" "--out=$out" "${extra[@]}" "${config[@]}"
