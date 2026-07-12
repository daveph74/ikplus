class_name InputBuffer
extends RefCounted
## ~130 ms (8-tick) press buffer. Presses are recorded every tick (including
## during hit-stop and hit-stun — buffering through freezes is what makes
## follow-ups feel good) and consumed only when the fighter can act.

const WINDOW_TICKS := 8

var _entries: Array[Dictionary] = []


func push(action: StringName, tick: int) -> void:
	_entries.append({"action": action, "tick": tick})


## Oldest still-fresh press, or &"" — stale entries are discarded.
func pop_valid(now_tick: int) -> StringName:
	while not _entries.is_empty():
		var e: Dictionary = _entries.pop_front()
		if now_tick - int(e["tick"]) <= WINDOW_TICKS:
			return e["action"]
	return &""
