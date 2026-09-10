class_name RoomVoice
extends Node

## The client half of voice: a microphone, a codec, a jitter buffer per speaker, and a key.
##
## [b]dot-voice does the work and this decides three things[/b] — where a captured frame
## goes, where an arriving one comes from, and what opens the gate. Everything else
## (resampling, encoding, sequencing, concealment, one buffer per speaker) is
## [DotVoiceManager]'s, and none of it is worth a second copy in a lobby.
##
## [b]Push to talk, and it is a hot mic by default nowhere.[/b] A lobby is somewhere people
## leave a tab open, and voice activation on an open tab is a room full of somebody's
## television. The gate is still there — [member DotVoiceConfig.push_to_talk] is a
## setting, not a constant — and this simply does not turn it off for them.
##
## [b]It degrades to nothing rather than to an error.[/b] A headless run, a browser that
## refused microphone permission, and a machine with no sound card all end up here with
## [member available] false and everything else working. That matters more than it looks:
## [method DotVoiceSourceMicrophone.is_supported] exists because `AudioServer` reports a
## working sound card when there is none — in a headless run `get_mix_rate()` is 44100 and
## `get_input_device_list()` is `["Default"]`, and only `get_driver_name()` says `"Dummy"`.
## A capability check built on any of the others passes on a machine with no audio at all,
## and the symptom is a capture that returns silence for ever with nothing reporting a
## problem.

const CHANNEL := "room.voice"

## Held to talk. `V` rather than a modifier, because a modifier plus WASD is a chord and
## somebody walking and talking is the ordinary case here rather than the awkward one.
const KEY_TALK := KEY_V


## Whether somebody is talking, either way. What the interface draws.
signal talking_changed(talking: bool)

## Somebody else started or stopped. [param speaker] is their peer id.
signal speaker_changed(speaker: int, speaking: bool)


## Whether a microphone was actually found. False in every headless run.
var available: bool = false

## Why not, when [member available] is false. Shown rather than swallowed.
var unavailable_reason: String = ""

var manager: DotVoiceManager = null

## Where a captured frame goes. Set by [RoomClient].
var send_fn: Callable = Callable()

## Whether playback goes into a buffer instead of an audio device.
##
## [b]This is what makes the whole voice path checkable.[/b] `DotVoiceSinkPlayer` needs an
## `AudioStreamPlayer` and a mixer, neither of which exists in a headless run — so without
## a buffer sink the receiving half is the one part of this game nothing can ever run, and
## a wire that decoded to nothing would look exactly like a wire that worked. dot-voice
## put [DotVoiceSource] and [DotVoiceSink] behind an interface for precisely this and says
## so; this is the consumer that takes it up.
##
## Set automatically when [method setup] is told there is no capture — the same condition
## that means there is no audio device at all.
var buffered_playback: bool = false

## speaker -> the [DotVoiceSinkBuffer] holding what they said, when buffered.
var _buffers: Dictionary = {}

var _talking: bool = false


## Builds the manager and, when there is a microphone, opens it.
##
## [b]Not fatal without one.[/b] Playback is set up either way: a person who cannot talk
## can still hear, which is most of the value and all of the value on a machine with an
## output and no input.
func setup(enable_capture: bool = true) -> DotResult:
	manager = DotVoiceManager.new()
	manager.name = "Voice"
	manager.config = RoomServices.voice_config()
	# [b]The config comes from the same file the server's does.[/b] A sample rate or a
	# frame length that differs between two peers is a stream of packets the router
	# refuses for being the wrong length — counted, and said to nobody. Same argument as
	# the room's size, and [method DotVoiceConfig.format_fingerprint] exists because of it.
	manager.config_file = ""
	manager.register_service = false
	manager.positional_playback = false
	manager.send_fn = _send
	add_child(manager)

	manager.speaker_changed.connect(_on_speaker_changed)

	buffered_playback = not enable_capture

	if buffered_playback:
		manager.sink_factory = _make_buffer_sink

	var supported := DotVoiceSourceMicrophone.is_supported()
	available = supported.ok

	if not available:
		unavailable_reason = supported.error.message
		DotLog.info(CHANNEL, "no microphone; listening only", {
			"why": unavailable_reason,
		})
		return DotResult.success(false)

	if not enable_capture:
		return DotResult.success(false)

	var opened := manager.start_capture()

	if not opened.ok:
		available = false
		unavailable_reason = opened.error.message
		DotLog.warn(CHANNEL, "the microphone would not open; listening only", {
			"why": unavailable_reason,
		})
		return DotResult.success(false)

	return DotResult.success(true)


## The talk key, off the same event stream everything else uses.
##
## [b]Edge triggered on both edges, and the release is the one that matters.[/b] A gate
## opened by a key-down and never closed is an open microphone for the rest of the
## session — which is the failure people actually report, and they report it as "everyone
## could hear me" rather than as a bug.
func handle_event(event: InputEvent) -> bool:
	if not (event is InputEventKey) or event.is_echo():
		return false

	var key := event as InputEventKey

	if key.keycode != KEY_TALK:
		return false

	set_talking(key.pressed)
	return true


func set_talking(pressed: bool) -> void:
	if manager == null or not available or _talking == pressed:
		return

	_talking = pressed
	manager.set_talking(pressed)
	talking_changed.emit(pressed)


## Everything goes quiet: the window lost focus, the chat box took the keyboard, the
## client disconnected.
##
## [b]Called from every one of those, because the key-up will not arrive.[/b] A browser
## tab that loses focus mid-word never delivers the release, and the microphone stays open
## on a tab nobody is looking at.
func release() -> void:
	set_talking(false)


func is_talking() -> bool:
	return _talking


## How loud the microphone is right now, 0 to 1. For a level meter.
func input_level() -> float:
	return manager.input_level() if manager != null and available else 0.0


## Everybody currently being heard.
func active_speakers() -> PackedInt64Array:
	return manager.active_speakers() if manager != null else PackedInt64Array()


## A frame off the wire. Handed straight to the manager, which owns the jitter buffers.
func receive(payload: PackedByteArray) -> void:
	if manager != null:
		manager.receive(payload)


## Stops hearing somebody, on this machine only.
##
## [b]A local mute, and it is deliberately not a request to the server.[/b] "I do not want
## to hear this person" is a client's business and needs no round trip; "this person may
## not speak" is a moderator's and is [DotModerationManager]'s. A client asking a server
## to stop sending somebody's voice to *everybody* is not muting anybody.
func set_local_mute(speaker: int, muted: bool) -> void:
	if manager != null:
		manager.set_local_mute(speaker, muted)


func is_locally_muted(speaker: int) -> bool:
	return manager != null and manager.is_locally_muted(speaker)


## A sink that keeps what it is given, for a run with no audio device.
func _make_buffer_sink(speaker: int) -> DotVoiceSink:
	var sink := DotVoiceSinkBuffer.new()
	_buffers[speaker] = sink
	return sink


## How loud a speaker has been, when playback is buffered. Zero otherwise.
##
## [b]An amplitude rather than a frame count, on purpose.[/b] A count says the packets
## arrived; this says they decoded to something. dot-voice's own suite makes the same
## distinction and it is the difference between "the wire works" and "you can hear them".
func heard_rms(speaker: int) -> float:
	var sink: Variant = _buffers.get(speaker)
	return (sink as DotVoiceSinkBuffer).rms() if sink is DotVoiceSinkBuffer else 0.0


func _send(bytes: PackedByteArray) -> void:
	if send_fn.is_valid():
		send_fn.call(bytes)


func _on_speaker_changed(speaker: int, speaking: bool) -> void:
	speaker_changed.emit(speaker, speaking)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("voice        %s" % (
		"talking" if _talking else ("ready" if available else "no microphone")
	))

	if not available and unavailable_reason != "":
		out.append("             %s" % unavailable_reason)

	if manager != null:
		out.append_array(manager.describe_lines())

	return out
