extends DotGameNetLink

## This game's link: the shared skeleton in [DotGameNetLink], plus the names that are its own.

const MmNetLink := preload("mm_net_link.gd")

const CHANNEL := "mm.link"

## The node name both ends must use. It is the routing, so it is a constant.
const NODE_NAME := &"HideSeek"


func _init() -> void:
	channel = CHANNEL


static func attached_to(_parent: Node, p_bridge: Node, server: bool) -> MmNetLink:
	var link := MmNetLink.new()
	link.bridge = p_bridge
	link.is_server = server
	return link
