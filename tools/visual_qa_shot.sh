#!/usr/bin/env bash
exec bash "$(dirname "$0")/../addons/gs_game/tools/gs_game_visual_qa_shot.sh" --script tools/visual_qa.gd -- "$@"
