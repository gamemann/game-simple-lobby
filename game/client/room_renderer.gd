extends Node2D

const RoomContent := preload("../room_content.gd")
const RoomOccupant := preload("../room_occupant.gd")
const RoomProps := preload("../room_props.gd")
const RoomWorld := preload("../room_world.gd")

## Draws the room and everybody in it.
##
## [b]Ships no art.[/b] dot-ui ships no art and dot-2d draws nothing; this follows both.
## Everything here is a rectangle, a circle or a string, which is what makes the whole
## game a pack small enough to be worth downloading and what stops a lobby needing an
## artist before it can be stood in.
##
## It reads the world and never writes to it. A renderer that nudged a position would be a
## renderer that fought the interpolator, and the symptom is a stutter nobody can locate.

## The room this draws. Set by [RoomClient].
var world: RoomWorld = null

## Which occupant is the local one, so they can be marked. Zero before the hello.
var local_occupant_id: int = 0

## What people have put in the room. Null on a client that has not been told yet.
##
## [b]Read from the same object the simulation collides against.[/b] A renderer with its
## own list of props is a client drawing a bench the server is not simulating — and the
## symptom is not a missing bench, it is a player corrected out of a space that looks
## empty. This game has already made that argument about the furniture; this is the same
## argument about the half of the level that people place.
var props: RoomProps = null

## occupant id -> the avatar rows the server sent: `slot`, `part`, `colour`.
##
## [b]Ids and colours, and nothing else.[/b] dot-user-avatar's whole claim is that an
## avatar is a bounded document a server validates without loading a part, and this is the
## client end of that: a lobby that ships no art draws the ids as shapes, and a deployment
## with content resolves them through [DotAvatarCatalogue] instead. Neither end downloads
## anything to know whether an avatar is legal.
var avatars: Dictionary = {}

@export_group("Palette")

@export var floor_colour: Color = Color(0.10, 0.11, 0.14, 1.0)
@export var grid_colour: Color = Color(1.0, 1.0, 1.0, 0.045)
@export var wall_colour: Color = Color(0.35, 0.62, 0.85, 0.85)

## The furniture's fill. Lighter than the floor and much darker than a person, so a
## pillar reads as part of the room rather than as somebody standing very still.
@export var furniture_colour: Color = Color(0.21, 0.23, 0.29, 1.0)
@export var name_colour: Color = Color(0.93, 0.94, 0.96, 1.0)
@export var bubble_colour: Color = Color(0.96, 0.97, 0.99, 0.94)
@export var bubble_text_colour: Color = Color(0.08, 0.09, 0.11, 1.0)

## Font used for names and bubbles. Godot's default when unset.
var _font: Font = null
var _font_size: int = 14


func _ready() -> void:
	_font = ThemeDB.fallback_font
	_font_size = ThemeDB.fallback_font_size


func _process(_delta: float) -> void:
	# Redrawn every frame rather than on a signal. Everybody in the room is moving under
	# an interpolator that produces a new position on every frame and emits nothing, so
	# there is no signal to redraw on — and a lobby with sixty-four circles in it is not
	# where a frame budget goes.
	queue_redraw()


func _draw() -> void:
	if world == null or world.arena == null:
		return

	var bounds := world.arena.bounds

	draw_rect(bounds, floor_colour, true)
	_draw_grid(bounds)
	_draw_furniture()
	# Under the walls and over the built-in furniture: a placed prop is a thing standing
	# in the room, and the room's edge is still the room's edge.
	_draw_props()
	draw_rect(bounds, wall_colour, false, 3.0)

	var now := Time.get_ticks_msec()

	# Sorted by Y so somebody standing in front of somebody else is drawn in front. Cheap
	# at this population, and the alternative — an arbitrary dictionary order — makes two
	# overlapping people flicker past each other every time the dictionary rehashes.
	var occupants := world.roster()
	occupants.sort_custom(
		func(a: RoomOccupant, b: RoomOccupant) -> bool:
			return a.position().y < b.position().y
	)

	for occupant in occupants:
		_draw_occupant(occupant, now)

	for occupant in occupants:
		# A second pass, so a bubble is never covered by somebody who happens to be
		# standing lower down. Speech is the one thing in this room that must be readable.
		if occupant.has_bubble(now):
			_draw_bubble(occupant, now)


## The furniture, from the same list the simulation collides against.
##
## [b]Read from [RoomContent] rather than laid out here.[/b] A renderer with its own copy
## of the level is a client that draws a room the server is not simulating — and the
## symptom is not a missing pillar, it is a player being corrected out of a space that
## looks empty. This family has shipped the same class of bug twice with a world extent.
##
## Drawn under the grid lines' colour and over the floor, so the furniture reads as part
## of the room rather than as objects sitting on it. A lobby's landmarks should look
## built in.
func _draw_furniture() -> void:
	for piece in RoomContent.furniture():
		var centre := Vector2(piece.x, piece.y)

		draw_circle(centre, piece.z, furniture_colour)
		draw_arc(centre, piece.z, 0.0, TAU, 48, wall_colour, 2.0)


## Everything people have put in the room.
##
## [b]Drawn from the definition, exactly as its collision is derived from it.[/b] A rug
## has a radius of zero and is drawn flat and wide; everything else is drawn at the radius
## it is actually collided against, so what a player walks around is what they can see.
## The alternative — a decorative size and a separate collision size — is the one thing
## this file's own doc comment says a renderer must not do.
func _draw_props() -> void:
	if props == null:
		return

	for entry in props.placements().values():
		var placement: Dictionary = entry
		var def: DotPropDef = placement["def"]
		var at: Vector2 = placement["at"]
		var colour := RoomProps.colour_of(def)
		var radius := RoomProps.radius_of(def)

		if radius <= 0.0:
			# [b]Something you walk over, and it has to LOOK like it.[/b] The first
			# version drew these at a fixed size, filled at a third opacity with a solid
			# rim — and a picture showed a rug that read as a dark disc of exactly the
			# weight the furniture has, and a sign the size of a bollard. Nothing about
			# that was visible in any assertion: the radius was zero, the obstacle list
			# was right, and both ends agreed.
			#
			# So: no shadow, no rim, a much fainter fill, and a dotted edge — three cues
			# that all say floor. The size comes from the definition, because a rug and a
			# sign are not the same size and only the catalogue knows.
			var flat := RoomProps.footprint_of(def)

			draw_circle(at, flat, Color(colour, 0.20))

			# Drawn as separated arcs rather than a ring: a continuous outline is what a
			# solid thing has, and it is the single strongest cue that something is in
			# the way.
			for step in range(12):
				var from := float(step) * TAU / 12.0
				draw_arc(at, flat, from, from + TAU / 22.0, 4, Color(colour, 0.5), 1.5)

			continue

		draw_circle(at + Vector2(0.0, radius * 0.3), radius * 0.95, Color(0, 0, 0, 0.22))
		draw_circle(at, radius, colour)
		draw_arc(at, radius, 0.0, TAU, 40, colour.darkened(0.35), 2.0)


func _draw_grid(bounds: Rect2) -> void:
	var step := RoomContent.FLOOR_GRID
	var x := ceilf(bounds.position.x / step) * step

	while x < bounds.end.x:
		draw_line(Vector2(x, bounds.position.y), Vector2(x, bounds.end.y), grid_colour, 1.0)
		x += step

	var y := ceilf(bounds.position.y / step) * step

	while y < bounds.end.y:
		draw_line(Vector2(bounds.position.x, y), Vector2(bounds.end.x, y), grid_colour, 1.0)
		y += step


func _draw_occupant(occupant: RoomOccupant, _now: int) -> void:
	var at := occupant.position()
	var radius := occupant.state.radius
	var colour := occupant.colour()

	# A soft shadow, so a circle on a flat floor reads as a person standing on it rather
	# than as a hole in it.
	draw_circle(at + Vector2(0.0, radius * 0.35), radius * 0.95, Color(0, 0, 0, 0.25))
	draw_circle(at, radius, colour)

	# Which way they are facing, as a notch. The only thing that makes a circle feel like
	# somebody rather than a token — and it comes free: the motor already tracks facing.
	var facing := Vector2.RIGHT.rotated(occupant.state.facing)
	draw_circle(at + facing * radius * 0.55, radius * 0.26, colour.lightened(0.55))

	_draw_avatar(occupant, at, radius)

	if occupant.id == local_occupant_id:
		# A ring rather than a different colour, because the colour is how everybody else
		# recognises you and changing it for one viewer means no two people see the same
		# room.
		draw_arc(at, radius + 5.0, 0.0, TAU, 32, Color(1, 1, 1, 0.85), 2.0)

	var text := occupant.display_name

	if text == "":
		return

	var width := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x
	var baseline := at + Vector2(-width * 0.5, -radius - 10.0)

	# Drawn twice, offset, rather than with an outline: the room's floor is dark and a
	# name can also cross somebody's bright circle, and a one-pixel shadow is legible on
	# both without a font resource the pack would have to carry.
	draw_string(
		_font, baseline + Vector2(1, 1), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, Color(0, 0, 0, 0.7)
	)
	draw_string(
		_font, baseline, text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, name_colour
	)


## Somebody's avatar, on top of the circle that is them.
##
## [b]This ships no art, so a part id becomes a shape.[/b] That is not a placeholder for
## something better: a lobby drawing a hat as a coloured arc and a deployment drawing it
## as a mesh are reading the same document, and the whole point of dot-user-avatar is that
## the document is the thing that travels. The slot decides where it goes and the id
## decides nothing at all here — which is honest, and is why a part this build has never
## heard of still draws as *something* rather than vanishing.
##
## Three slots are understood. Anything else is drawn as a small mark beside the head, so
## a player wearing something from a newer catalogue is visibly wearing something.
func _draw_avatar(occupant: RoomOccupant, at: Vector2, radius: float) -> void:
	var rows: Variant = avatars.get(occupant.id)

	if not (rows is Array):
		return

	for value in (rows as Array):
		var row: Dictionary = value
		var tint: Color = row.get("colour", Color.WHITE)

		match String(row.get("slot", "")):
			"hat":
				# An arc across the top of the head, thick enough to read at this size.
				draw_arc(
					at, radius * 0.86, PI * 1.15, PI * 1.85, 20, tint, radius * 0.28
				)
			"face":
				draw_circle(at + Vector2(-radius * 0.22, -radius * 0.12), radius * 0.12, tint)
				draw_circle(at + Vector2(radius * 0.22, -radius * 0.12), radius * 0.12, tint)
			"badge":
				draw_circle(at + Vector2(radius * 0.55, radius * 0.45), radius * 0.24, tint)
			_:
				draw_circle(at + Vector2(0.0, -radius * 1.05), radius * 0.16, tint)


func _draw_bubble(occupant: RoomOccupant, now: int) -> void:
	var text := occupant.bubble_text
	var size := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size)
	var padding := Vector2(8.0, 5.0)
	var at := occupant.position()
	var box := Rect2(
		at + Vector2(-size.x * 0.5 - padding.x, -occupant.state.radius - 30.0 - size.y),
		size + padding * 2.0
	)

	# Fades out over its last half second rather than vanishing. A bubble that disappears
	# between two frames reads as a message that was deleted.
	var remaining := float(occupant.bubble_until_ms - now)
	var alpha := clampf(remaining / 500.0, 0.0, 1.0)

	draw_rect(box, Color(bubble_colour, bubble_colour.a * alpha), true)
	draw_string(
		_font,
		box.position + padding + Vector2(0.0, size.y * 0.78),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		_font_size,
		Color(bubble_text_colour, alpha)
	)
