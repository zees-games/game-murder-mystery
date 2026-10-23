extends DotFxBlood
## Blood from the SHOT and DEATH events every client already gets, so the server sends nothing extra.


## A shot that hit somebody ended at [param to]: blood on the first surface behind it.
func on_shot_hit(from: Vector3, to: Vector3, reach: float = 3.0) -> Node3D:
	return splat_behind(from, to, reach, 0.8)


## A stab killed somebody standing at [param feet]: blood on the floor under them.
func on_stab(feet: Vector3) -> Node3D:
	return splat_below(feet, 4.0, 0.5, 0.8)
