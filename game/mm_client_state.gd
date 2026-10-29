extends Node

## The constants, exports and state of [code]mm_client.gd[/code]. Path-based base, no class_name.

const MmAudio := preload("mm_audio.gd")
const MmBindings := preload("mm_bindings.gd")
const MmBlood := preload("mm_blood.gd")
const MmFigure := preload("mm_figure.gd")
const MmKillcamBodies := preload("mm_killcam_bodies.gd")
const MmSettings := preload("mm_settings.gd")
const MmServices := preload("mm_services.gd")
const MmNetBridge := preload("net/mm_net_bridge.gd")

const MmConfig := preload("mm_config.gd")
const MmGame := preload("mm_game.gd")
const MmHud := preload("mm_hud.gd")
const MmPaths := preload("mm_paths.gd")
const MmPlayer := preload("mm_player.gd")
const MmWeapons := preload("mm_weapons.gd")
const MmWeaponIcons := preload("mm_weapon_icons.gd")


const CHANNEL := "mm.client"

## How far behind a player the camera hangs in third person.
const CHASE_BACK := 3.0
const CHASE_UP := 0.8

@export var config_file: String = "user://cfg/murder.json"
@export var force_offline: bool = false

## How many stand-ins an offline round gets.
@export_range(0, 12, 1) var offline_bots: int = 6

var game: MmGame = null
var player: MmPlayer = null
var camera: Camera3D = null

## Keeps the screen covered, and the local body and the input still, until the level, the
## player and the camera are all in. It is [member DotGameClient.gate].
var gate: DotLoadGate = null

## dot-game's client platform: the cover, settings and menu, console, HUD theme, Tab, M, the
## pointer and the input block. See [DotGameClient].
var platform: DotGameClient = null
var hud: MmHud = null

## The final killcam ([DotKillcamHost]); null without dot-replay API 6.
var killcam: DotKillcamHost = null
var board: DotMenuScoreboard = null
var chat: DotGameChatClient = null
var audio: MmAudio = null
var settings: MmSettings = null

## The player's console (the platform's).
var console: DotConsoleController = null

var net: DotNetManager = null
var bridge: MmNetBridge = null
var link: Node = null
## Asks a server whether this player may edit it (sv_workbench_remote); null offline.
var workbench_remote: DotGameWorkbenchRemoteClient = null
## The tuning panel's host: F9 solo or hosting, the admin's remote panel on a server that allows it.
var workbench: DotGameWorkbench = null

## Whether the camera hangs behind the player. F5 swaps it.
var third_person: bool = false

var _offline: bool = true
var _sampler: DotFpsSampler = null
var _watch_id: int = -1
## The spectator's free camera while roaming, and the mouse motion not yet turned into a look.
var _free_cam: DotSpectatorFreeCam = null
var _roam_look: Vector2 = Vector2.ZERO
var _arm: DotCameraBoom = null
var _fade: DotCameraFade = null
var _rig_height: float = 0.0
var _started_msec: int = Time.get_ticks_msec()

## The last whole second of the grace a beep was played for.
var _beeped: int = -1


## Where the dead lie: dot-player-char's ragdolls under the game's (the server's) rules.
var ragdolls: DotPlayerRagdolls = null


## Blood on the wall behind a shot or the floor under a stab (see mm_blood.gd).
var blood: MmBlood = null


## The board's two groups. Not the sides: who is the murderer is the round's secret.
const BOARD_ALIVE := 1


const BOARD_OUT := 3


var _portraits: Dictionary = {}


## What is in your own hand, in first person: the gun, or the weapon drawn. Rebuilt when it
## changes; nothing in third person, where the figure holds it.
var _view_model: Node3D = null


var _view_model_of: String = ""


var _swing_at: float = -10.0


var _swings_seen: int = 0


## Every gun on the floor, drawn turning slowly where it lies (`MmGame.gun_drops`, the server's
## and every client's alike).
var _gun_nodes: Dictionary = {}
