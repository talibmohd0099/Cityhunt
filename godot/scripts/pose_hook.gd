## Runs its owner's per-frame pose tweaks after the walk cycle has been applied to the skeleton
## (the beast's hunch and jaw, the player's flashlight arm).
class_name PoseHook
extends SkeletonModifier3D

var fn: Callable

func _process_modification_with_delta(delta: float) -> void:
	if fn.is_valid():
		fn.call(delta)
