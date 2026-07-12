extends Node
## Autoload: real sfx playback (build step 10, docs/plan.md "Autoloads").
## For each sfx name, tries res://assets/audio/<name>.wav first (drop a real
## file in later without touching this script); else synthesizes a 16-bit
## signed little-endian PCM mono placeholder at boot. Public API (play,
## start_ambience) is unchanged from the step-1 stub so FXManager/MatchManager
## callers never needed to change.
##
## The loop_end trap (docs/plan.md): AudioStreamWAV.loop_end defaults to 0,
## which makes a "looping" ambience stream play once and stop — every looped
## stream built here sets loop_begin/loop_end explicitly to the total sample
## FRAME count (bytes / 2 for 16-bit mono).
##
## Crash-proofing under the dummy audio driver (headless verify/smoke runs):
## stream creation and AudioStreamPlayer.play() never touch an audio device
## directly — the engine already no-ops actual playback when the dummy driver
## is active, so nothing here needs its own headless branch.

const MIX_RATE := 22050
const POOL_SIZE := 6
const SFX_NAMES: Array[StringName] = [
	&"punch", &"kick", &"block", &"knockdown", &"round_start", &"victory"
]

var _streams: Dictionary = {} # StringName -> AudioStreamWAV
var _pool: Array[AudioStreamPlayer] = []
var _pool_index := 0
var _ambience_player: AudioStreamPlayer


func _ready() -> void:
	for sfx_name: StringName in SFX_NAMES:
		_streams[sfx_name] = _load_or_synthesize(sfx_name)

	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.name = "SfxPlayer%d" % i
		add_child(p)
		_pool.append(p)

	_ambience_player = AudioStreamPlayer.new()
	_ambience_player.name = "AmbiencePlayer"
	_ambience_player.stream = _gen_ambience()
	add_child(_ambience_player)

	var events := get_node(^"/root/GameEvents")
	events.round_state_changed.connect(_on_round_state_changed)
	events.match_ended.connect(_on_match_ended)


func play(sfx_name: StringName) -> void:
	var stream: AudioStreamWAV = _streams.get(sfx_name)
	if stream == null or _pool.is_empty():
		return
	var player := _pool[_pool_index]
	_pool_index = (_pool_index + 1) % _pool.size()
	player.stream = stream
	player.play()


func start_ambience() -> void:
	if _ambience_player != null and not _ambience_player.playing:
		_ambience_player.play()


# --- GameEvents subscriptions (docs/plan.md: FXManager covers per-hit sfx;
# AudioManager owns the match-flow cues) -------------------------------------


func _on_round_state_changed(new_state: int) -> void:
	if new_state == MatchManager.Phase.FIGHTING:
		play(&"round_start")


func _on_match_ended(_winner: Node) -> void:
	play(&"victory")


# --- loading / synthesis ----------------------------------------------------


func _load_or_synthesize(sfx_name: StringName) -> AudioStreamWAV:
	var path := "res://assets/audio/%s.wav" % sfx_name
	if ResourceLoader.exists(path):
		var loaded: Resource = load(path)
		if loaded is AudioStreamWAV:
			return loaded
	return _synthesize(sfx_name)


func _synthesize(sfx_name: StringName) -> AudioStreamWAV:
	match sfx_name:
		&"punch":
			return _to_stream(_gen_thump(0.06, 150.0))
		&"kick":
			return _to_stream(_gen_thump(0.09, 110.0))
		&"block":
			return _to_stream(_gen_block())
		&"knockdown":
			return _to_stream(_gen_knockdown())
		&"round_start":
			return _to_stream(_gen_round_start())
		&"victory":
			return _to_stream(_gen_victory())
		_:
			return _to_stream(PackedFloat32Array())


## punch/kick: a short noise-band burst layered with a low sine "thump",
## exponential decay across the whole clip.
func _gen_thump(duration: float, freq: float) -> PackedFloat32Array:
	var n := int(duration * MIX_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	for i in n:
		var t := float(i) / MIX_RATE
		var decay := exp(-(t / duration) * 6.0)
		var tone := sin(TAU * freq * t)
		var noise := randf_range(-1.0, 1.0)
		samples[i] = (tone * 0.65 + noise * 0.35) * decay
	return samples


## block: a short, high-frequency click (2 kHz tone + noise), fast decay.
func _gen_block() -> PackedFloat32Array:
	var duration := 0.04
	var n := int(duration * MIX_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	for i in n:
		var t := float(i) / MIX_RATE
		var decay := exp(-(t / duration) * 10.0)
		var tone := sin(TAU * 2000.0 * t)
		var noise := randf_range(-1.0, 1.0)
		samples[i] = (tone * 0.5 + noise * 0.5) * decay
	return samples


## knockdown: a descending pitch sweep 300 -> 80 Hz over 220 ms. Uses a phase
## accumulator (not sin(freq*t)) since the frequency changes continuously —
## direct evaluation would produce phase discontinuities every sample.
func _gen_knockdown() -> PackedFloat32Array:
	var duration := 0.22
	var n := int(duration * MIX_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / MIX_RATE
		var freq := lerpf(300.0, 80.0, t / duration)
		phase += freq / MIX_RATE
		var decay := exp(-(t / duration) * 2.0)
		samples[i] = sin(TAU * phase) * decay
	return samples


## round_start: two-tone announce, 660 Hz then 880 Hz, 120 ms each.
func _gen_round_start() -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	_append_tone(samples, 660.0, 0.12)
	_append_tone(samples, 880.0, 0.12)
	return samples


## victory: rising arpeggio, 440/554/659 Hz, 100 ms each.
func _gen_victory() -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	_append_tone(samples, 440.0, 0.1)
	_append_tone(samples, 554.0, 0.1)
	_append_tone(samples, 659.0, 0.1)
	return samples


## ~2 s of low-pass-filtered noise with a slow amplitude swell ("gentle
## waves"), set up to loop seamlessly (docs/plan.md loop_end trap).
func _gen_ambience() -> AudioStreamWAV:
	var duration := 2.0
	var n := int(duration * MIX_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var lp := 0.0
	var alpha := 0.02 ## one-pole low-pass coefficient — keeps the noise "low"/rumbly
	for i in n:
		var t := float(i) / MIX_RATE
		var raw := randf_range(-1.0, 1.0)
		lp += alpha * (raw - lp)
		# One full swell cycle across the buffer (0.5 Hz over a 2 s clip) so
		# the amplitude envelope matches up cleanly at the loop seam.
		var swell := 0.6 + 0.4 * sin(TAU * 0.5 * t / duration)
		samples[i] = lp * 0.5 * swell
	return _to_stream(samples, true)


func _append_tone(samples: PackedFloat32Array, freq: float, duration: float, amp := 0.8) -> void:
	var n := int(duration * MIX_RATE)
	var start := samples.size()
	samples.resize(start + n)
	for i in n:
		var t := float(i) / MIX_RATE
		samples[start + i] = sin(TAU * freq * t) * amp * _envelope(t, duration)


## Quick attack/release per tone segment so back-to-back tones (round_start,
## victory) don't click at the seams.
func _envelope(t: float, duration: float) -> float:
	var attack := minf(0.005, duration * 0.1)
	var release := minf(0.02, duration * 0.3)
	if t < attack:
		return t / attack
	if t > duration - release:
		return maxf(0.0, (duration - t) / release)
	return 1.0


func _to_stream(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = _samples_to_bytes(samples)
	if loop:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = samples.size() # total sample FRAMES (bytes/2 for 16-bit mono)
	else:
		stream.loop_mode = AudioStreamWAV.LOOP_DISABLED
	return stream


func _samples_to_bytes(samples: PackedFloat32Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		var v := clampf(samples[i], -1.0, 1.0)
		bytes.encode_s16(i * 2, int(round(v * 32767.0)))
	return bytes
