extends RefCounted

## Every constant the room is made of, in one file both ends read.
##
## [b]Nothing here may be configured per peer.[/b] The room's size is quantised into the
## wire format, the palette decides what colour a stranger is on your screen, and the
## walk speed is what a client predicts with — three values that are silently catastrophic
## when two machines disagree and produce no error on either. dot-2d-hungry learned the
## first one the expensive way: a client holding a different arena rectangle derives every
## crumb somewhere else, from the right seed, so the ids match, the counts match, and
## nothing is where anybody says it is.
##
## A server that wants a different room ships a different pack. It does not send numbers.

## Half-width and half-height of the room, in world units.
##
## Small on purpose. A lobby is a place you can see all of at once — a room you have to
## walk across to find out who is in it is a room where the roster is the only thing
## anybody reads.
const ROOM_EXTENT := Vector2(900.0, 560.0)

## The room, as a rectangle. What [Dot2DArena] is given and what positions are clamped to.
static func bounds() -> Rect2:
	return Rect2(-ROOM_EXTENT, ROOM_EXTENT * 2.0)


## How big a person is.
const OCCUPANT_RADIUS := 22.0

## Simulation rate. Matched by the module against `sv_tickrate`, loudly, because a
## mismatch is a room that runs at the wrong speed with nothing in the log about it.
const TICK_RATE := 60

## Snapshots a second.
##
## Lower than a shooter's, deliberately: nobody is being shot at. Twenty people at
## [constant Dot2DNetSync.estimated_bits] is about 250 bytes a snapshot, so 15 Hz is under
## 4 kB/s to everybody in the room — which matters, because every one of them is on a
## WebSocket where a snapshot cannot be dropped and a slow client stalls the ones behind
## it.
const SNAPSHOT_RATE := 15

## Longest display name kept. Also the wire's bound.
const NAME_BYTES := 32

## People in one room.
##
## The number that makes "everybody is always relevant" affordable — see
## [RoomBridge._build_occupant_entity]. Past this a lobby needs interest management and
## stops being a lobby.
const MAX_OCCUPANTS := 64


## How a person moves.
##
## Top-down and direct: WASD or a drag, no momentum to speak of, no aim. A lobby is a
## place you walk about in while you read the chat, and anything with inertia makes
## standing still a skill.
static func tunables() -> Dot2DTunables:
	var t := Dot2DTunables.new()
	t.mode = Dot2DTunables.Mode.TOPDOWN
	t.max_speed = 260.0
	# High enough that a tap moves you and a release stops you inside two ticks. Sliding
	# to a halt in a chat room reads as lag rather than as physics.
	t.acceleration = 3200.0
	t.friction = 3000.0
	t.turn_authority = 1.0
	# The pointer drives movement on a touchscreen, and does not on a desktop: see
	# [RoomInput], which fills `move` from keys and `aim`/`reach` from a drag. Both end up
	# in the same command and the motor reads whichever is set.
	t.follow_aim = false
	t.bounce_off_walls = false
	return t


## The colour a person is drawn in, derived from their id.
##
## [b]Derived, not assigned and not replicated.[/b] A colour that travelled would be one
## more thing to get out of step on a rejoin, and a colour a server chose would have to be
## remembered across a game change. Two people in one room can collide on a hue; nobody
## has ever minded, and the name is drawn above them anyway.
##
## The multiplier is a large odd number so consecutive session ids — which is exactly what
## a dedicated server hands out — land far apart on the wheel rather than in a gradient.
static func colour_for(id: int) -> Color:
	var hue := float((absi(id) * 2654435761) % 360) / 360.0
	return Color.from_hsv(hue, 0.55, 0.95)


## The floor's grid spacing. Drawn, and nothing else: the room has no cells.
const FLOOR_GRID := 80.0


## The furniture, as circles: x and y are the centre, z is the radius.
##
## [b]This is the room's LEVEL, and it is here rather than in the renderer for the reason
## at the top of this file.[/b] An obstacle a client draws and does not collide with is a
## client whose prediction disagrees with the server on every tick a player walks into
## it — and an obstacle the server has and the client does not is worse, because the
## player is corrected out of a space that looks empty. Both ends read this list and both
## ends resolve it in [method RoomWorld.simulate_occupant], which is the one function a
## client replays.
##
## [b]Circles rather than rectangles, and it is not laziness.[/b] Pushing a walker out of
## a circle is one normalise and one multiply, is exact, and has no corner case; pushing
## one out of a rectangle has four, and the one where somebody is exactly on a diagonal
## is the one that puts them inside. A lobby does not need square furniture badly enough
## to pay for that.
##
## [b]A packed array of Vector3 rather than an array of dictionaries[/b], because this is
## read on every occupant on every tick on both ends: a dictionary lookup per field per
## obstacle per person is the sort of thing that is free at four people and is not at
## sixty-four.
##
## The layout: a big central island so the room has a middle to walk around rather than
## across, four pillars marking the quarters so "by the north-west pillar" means
## something, and two benches off to one side. Nothing here is decoration — every one of
## them is a thing to stand behind, and a lobby where everybody stands in one place is a
## lobby where the roster is the only thing anybody reads.
static func furniture() -> PackedVector3Array:
	var out := PackedVector3Array([
		# The island. Big enough to walk round and small enough to see over.
		Vector3(0.0, 0.0, 150.0),

		# The quarters. Placed on a rectangle rather than a circle so the room reads as
		# a room: four points on a circle in a rectangular space look like a mistake.
		Vector3(-460.0, -280.0, 46.0),
		Vector3(460.0, -280.0, 46.0),
		Vector3(-460.0, 280.0, 46.0),
		Vector3(460.0, 280.0, 46.0),

		# Two benches by the east wall, far enough apart to stand between.
		Vector3(700.0, -110.0, 60.0),
		Vector3(700.0, 110.0, 60.0),

		# --- The partition, and the wing behind it ---------------------------
		#
		# [b]The room had one space in it, and one space is one conversation.[/b]
		# dot-chat gives a channel a radius so that somebody across the room is not
		# in your conversation, and in a single open hall that radius is either the
		# whole room or an invisible line across the middle of it. A wall people walk
		# round is the same rule made visible: step through the doorway and you are
		# out of earshot of the hall, which is a thing a player can see a reason for.
		#
		# Six posts on the WALL_X line, overlapping by 20 units each so there is no
		# hairline gap between two tangent circles for a walker to be squeezed
		# through by the resolve. The pair either side of the middle are the door
		# posts and the DOORWAY_SPAN between them is the only way across.
		# The north end of the partition stops NORTH_GATE_Y short of the north wall,
		# and the gap is the second way through. See NORTH_GATE_Y.
		Vector3(WALL_X, NORTH_GATE_Y, POST_RADIUS),
		Vector3(WALL_X, -300.0, POST_RADIUS),
		Vector3(WALL_X, -140.0, POST_RADIUS),
		Vector3(WALL_X, 140.0, POST_RADIUS),
		Vector3(WALL_X, 300.0, POST_RADIUS),
		Vector3(WALL_X, 460.0, POST_RADIUS),

		# The wing itself: a counter down its west wall — a table at either end and
		# a bench between them — so the middle of it stays clear and the doorway
		# opens onto somewhere to walk rather than onto a table.
		#
		# [b]All three are pinned to the west wall by WING_PIECE_X, and that is not
		# decoration.[/b] The wing is a strip DOORWAY-wide with a walker's usable
		# band narrower still, so a piece of furniture standing in the middle of it
		# does not make the room interesting, it closes the room — which is what the
		# two r=55 tables at x=-770 did from the day the wing was built until
		# 2026-09-17. They left a 31-unit squeeze against the west wall and a walker
		# holding north jammed against the partition at y=-266, in a room whose
		# renderer, roster and resolve were all perfectly happy. Nothing walked the
		# wing's length until something did.
		Vector3(WING_PIECE_X, -330.0, WING_PIECE_RADIUS),
		Vector3(WING_PIECE_X, 330.0, WING_PIECE_RADIUS),
		Vector3(WING_PIECE_X, 0.0, WING_PIECE_RADIUS),
	])

	# --- The gallery along the north wall ------------------------------------
	#
	# A screen standing off the north wall, centred on the room, with the two north
	# pillars as its doorposts. See [constant GALLERY_DEPTH].
	out.append_array(gallery_screen())

	# --- The snug in the south-east corner -----------------------------------
	#
	# An L of screen posts standing off the corner, a gate at each end of it against a
	# wall, and a seat in the crook. See [constant SNUG_ARM_POSTS].
	out.append_array(snug_screen())
	out.append(snug_seat())

	# --- The alcove off the south wall ---------------------------------------
	#
	# A bow of posts standing out from the south wall west of the island, a gate at
	# each end of it against the wall. See [constant ALCOVE_RADIUS].
	out.append_array(alcove_screen())

	return out


## Where the partition stands. West of the north-west and south-west pillars.
const WALL_X := -620.0

## The radius of a partition post.
##
## Sized so that neighbouring posts 160 apart overlap by 20 rather than touching: two
## circles that merely touch leave a contact point that [method resolve_circles] can
## push a walker straight through, because each circle on its own is happy to send them
## toward the other.
const POST_RADIUS := 90.0

## How wide the way through is, edge to edge, in units.
##
## An occupant is [constant OCCUPANT_RADIUS] * 2 across, so this is a door somebody can
## walk through without aiming — which is the difference between a second room and a
## second room nobody goes into.
const DOORWAY_SPAN := 280.0 - POST_RADIUS * 2.0


## The centre of the partition's northernmost post.
##
## [b]Derived so that the gap it leaves against the north wall is exactly
## [constant DOORWAY_SPAN].[/b] The north gate is the front door's width because it is
## a door, not a squeeze: a second way through that has to be aimed at is a second way
## through nobody finds, and the value of it is precisely that the wing stops being a
## pocket you have to back out of. One person standing in one doorway was a locked
## room, and a lobby is the one place people do stand in doorways.
##
## Written as an expression rather than as -370 so that moving the room's north wall,
## or widening the door, moves the gate with them.
const NORTH_GATE_Y := -ROOM_EXTENT.y + DOORWAY_SPAN + POST_RADIUS


## How far the wing's furniture stands from the room's west wall.
##
## [b]Against it, so a lane runs the wing's whole length on its east side.[/b] The
## partition's posts take [constant POST_RADIUS] off the wing's east edge and a walker's
## own radius takes another, which leaves about 146 units of usable band — less than the
## diameter of a table plus two walkers. There is no arrangement in which furniture
## stands in the middle of this wing and the wing is still a room.
const WING_PIECE_X := -862.0

## How big a piece of the wing's counter is.
##
## Sized against the lane it has to leave rather than against how a table looks: at this
## radius a walker clears the counter from x = -804 eastward and the partition from
## x = -732 westward, so the lane is 72 units wide — wider than the window a walker has
## through the doorway, which is the width this room has already agreed is walkable
## without aiming.
const WING_PIECE_RADIUS := 36.0


# --- The gallery -----------------------------------------------------------

## How deep the strip behind the north screen is, from the wall to the screen's face.
##
## [b]Derived from what has to fit in it rather than from how it looks.[/b] The wing was
## built to a width that looked right and was then furnished until nobody could walk
## down it, and nothing in this project noticed for as long as that was true. Four
## occupant diameters is two people stopped against the north wall talking and two more
## getting past them, which is the only thing this strip has to be able to do — and it
## is the reason the gallery is left EMPTY. There is nothing in it to stand behind
## because the gallery itself is the thing you stand behind.
const GALLERY_DEPTH := OCCUPANT_RADIUS * 8.0

## The radius of one screen post.
##
## [b]Thinner than a partition post, and it is the hall that decides so.[/b] The room's
## north half is 410 units from the island's edge to the wall, and the screen has to fit
## its own thickness, the gallery behind it and the hall's north lane into that. At the
## partition's radius of 90 the lane came out at 94 units — a walker's window of 50, in
## the main room, which is the wing's own bug moved into the hall. At 50 the lane is 136
## and the gallery is still four occupant diameters deep. A screen is not load-bearing;
## the partition is a wall and this is furniture.
const GALLERY_POST_RADIUS := 50.0

## How much neighbouring screen posts overlap, in units.
##
## The partition's number, for the partition's reason: two circles that merely touch
## leave a contact point [method resolve_circles] can push a walker straight through,
## because each circle on its own is happy to send them toward the other.
const GALLERY_OVERLAP := 20.0

## How many posts the screen is made of.
##
## [b]Six, and the count is bounded by the pillars rather than by the wall.[/b] The
## screen must stop well short of the north-west and north-east pillars but not far
## short: a post 167 units from a pillar centre leaves 52 between their faces and 8 for a
## walker, which is a slot nothing can pass and reads in a picture as a way through,
## while a screen that stops 300 short has mouths so wide the gallery is not a room. At
## six the ends stand 265 from the pillar beside them, which leaves 169 — more than the
## front door and less than a third of the hall. The pillars are the gallery's doorposts,
## which is why the mouths are where they are.
const GALLERY_POSTS := 6

## Where the screen stands.
##
## Derived so the walkable strip behind it is exactly [constant GALLERY_DEPTH], the same
## way [constant NORTH_GATE_Y] derives the north gate: move the north wall and the screen
## moves with it rather than the gallery quietly becoming a corridor.
const GALLERY_Y := -ROOM_EXTENT.y + GALLERY_DEPTH + GALLERY_POST_RADIUS


## How far apart the screen's posts stand, centre to centre.
static func gallery_spacing() -> float:
	return GALLERY_POST_RADIUS * 2.0 - GALLERY_OVERLAP


## The screen's posts, on their own.
##
## [b]Separate from [method furniture] so a check can ask about the screen rather than
## about whatever happens to be standing near it.[/b] The first version of the gallery's
## section asked [method in_gallery] which pieces were the screen, and the answer was
## none of them: a post's centre sits exactly ON [constant GALLERY_Y] and that predicate
## is a strict `<`, so the mouth measurement compared an empty set against an empty set
## and reported `inf` as a pass. Two questions — "is this point in the strip" and "is
## this circle part of the screen" — and one of them is not a position test at all.
static func gallery_screen() -> PackedVector3Array:
	var out := PackedVector3Array()

	for index in range(GALLERY_POSTS):
		out.append(Vector3(
			(float(index) - float(GALLERY_POSTS - 1) * 0.5) * gallery_spacing(),
			GALLERY_Y,
			GALLERY_POST_RADIUS
		))

	return out


## Whether [param at] is in the gallery behind the north screen rather than in the hall.
##
## [b]Read from the same constants the posts are placed from[/b], for the reason
## [method in_wing] gives: a check that wrote -314 again would keep passing after the
## wall moved. The x bound is the screen's own extent, so a point level with the gallery
## but out past either mouth is in the hall, which is what a person standing there would
## say.
static func in_gallery(at: Vector2) -> bool:
	var half := float(GALLERY_POSTS - 1) * 0.5 * gallery_spacing() + GALLERY_POST_RADIUS
	return at.y < GALLERY_Y and absf(at.x) <= half


# --- The snug ----------------------------------------------------------------

## The radius of one of the snug's screen posts.
##
## [b]Thinner than the gallery's, and the neighbours decide so rather than the look.[/b]
## The snug is boxed in by two things it must not narrow: the south bench above it and
## the south-east pillar beside it. At the gallery's 50 an arm of useful length puts its
## face within 90 of the bench, which is the gallery's own lesson — a screen that closes
## the hall's lane while making a room — so the posts are 30 and the arms are longer.
const SNUG_POST_RADIUS := 30.0

## How far apart the snug's posts stand, centre to centre.
##
## Overlapping by [constant GALLERY_OVERLAP], for the partition's reason: two circles that
## merely touch leave a contact point [method resolve_circles] can push a walker through.
const SNUG_SPACING := SNUG_POST_RADIUS * 2.0 - GALLERY_OVERLAP

## How many posts each arm has beyond the corner post they share.
##
## [b]Three, and it is the most the corner has room for.[/b] At four the north arm's face
## comes within 70 of the south bench and the corner post within 74 of the south-east
## pillar — two slots narrower than the front door, in the hall, made by a room nobody
## is standing in. At three those are 110 and 116.
##
## [b]The arms share the corner post, and it is what makes the corner a corner.[/b] Without
## it the two arms' first posts face each other across the diagonal and overlap by
## [code]2r - spacing * sqrt(2)[/code], which is 3.4 units at these numbers — enough, and
## only just: at the gallery's 50 and 80 the same join is a 13-unit hole. A join in a
## wall is exactly where nobody thinks to walk, so the corner is placed rather than
## left to arithmetic.
const SNUG_ARM_POSTS := 3

## The centre of the north arm's east end post.
##
## [b]Derived so the east gate is exactly [constant DOORWAY_SPAN] against the east
## wall[/b], the way [constant NORTH_GATE_Y] derives the wing's north gate: move the wall
## or widen the door and the gate follows.
const SNUG_GATE_X := ROOM_EXTENT.x - DOORWAY_SPAN - SNUG_POST_RADIUS

## The centre of the west arm's south end post. The south gate, derived the same way.
const SNUG_GATE_Y := ROOM_EXTENT.y - DOORWAY_SPAN - SNUG_POST_RADIUS

## Where the two arms meet: the corner post's x, and the line the west arm stands on.
const SNUG_X := SNUG_GATE_X - SNUG_SPACING * SNUG_ARM_POSTS

## The corner post's y, and the line the north arm stands on.
const SNUG_Y := SNUG_GATE_Y - SNUG_SPACING * SNUG_ARM_POSTS

## How big the seat in the snug's crook is.
##
## [b]Derived from what the floor round it has to hold, not from how big the crook
## is.[/b] Somebody standing at the seat is one occupant's width, and somebody else
## getting past them needs the front door's width, so that is the band left between the
## seat and each wall. It came out at 38.
##
## The first version filled the crook instead — out to the inner edge of each gate, so
## a walker down either gate still never touched it — and every check passed. The
## picture was a clump of circles in the corner with two door-width corridors round it:
## the wing's corridor-with-furniture, drawn again, in a room that was meant to be the
## one place in the hall to sit down.
const SNUG_SEAT_RADIUS := (
	ROOM_EXTENT.x - SNUG_X - SNUG_POST_RADIUS - DOORWAY_SPAN - OCCUPANT_RADIUS * 2.0
) * 0.5


## The snug's screen posts, on their own: the corner, then the north arm eastward, then
## the west arm southward.
##
## [b]Separate from [method furniture] for [method gallery_screen]'s reason[/b] — "is this
## circle part of the snug's wall" is not a position test, and asking a position
## predicate for it is how the gallery's first mouth check measured an empty set.
static func snug_screen() -> PackedVector3Array:
	var out := PackedVector3Array()
	out.append(Vector3(SNUG_X, SNUG_Y, SNUG_POST_RADIUS))

	for index in range(1, SNUG_ARM_POSTS + 1):
		out.append(Vector3(SNUG_X + SNUG_SPACING * index, SNUG_Y, SNUG_POST_RADIUS))

	for index in range(1, SNUG_ARM_POSTS + 1):
		out.append(Vector3(SNUG_X, SNUG_Y + SNUG_SPACING * index, SNUG_POST_RADIUS))

	return out


## The seat, in the crook of the L, against both arms' inner faces.
static func snug_seat() -> Vector3:
	var inset := SNUG_POST_RADIUS + SNUG_SEAT_RADIUS
	return Vector3(SNUG_X + inset, SNUG_Y + inset, SNUG_SEAT_RADIUS)


## Whether [param at] is inside the snug rather than in the hall.
##
## Read from the constants the posts are placed from, for [method in_wing]'s reason. A
## point in either gate counts as inside once it is past the arm's line, which is what
## somebody standing there would say.
static func in_snug(at: Vector2) -> bool:
	return at.x > SNUG_X and at.y > SNUG_Y


# --- The alcove ------------------------------------------------------------

## Where the alcove's bow is centred, on the south wall: the x of a point ON the wall.
##
## [b]Placed by its neighbours, and there is one place it fits.[/b] The south-west
## pillar is the tightest: at -200 the nearest post stands 107 from it, and at -210 that
## gap is 100 — the front door — and past it a slot. Nudged east instead and the seat the
## spawn ring puts at (0, 392) ends up inside the bow's east posts, so one arrival in
## eight would be pushed out of a wall. Everything else it borders — the island, the
## partition, the flood's start — is further off than either.
const ALCOVE_X := -200.0

## The radius of the line the bow's posts stand on, from its centre on the wall.
##
## [b]A lane, and somewhere to stand out of it.[/b] The gates are [constant DOORWAY_SPAN]
## against the wall, so somebody going along the wall passes through the alcove in a lane
## the door's width and touches nothing. At the middle the bow's inner face is 170 off
## the wall: that lane, and 70 more behind it — room for a person (44 across) to stand
## against the bow out of the way of whoever is walking through. 200 is the most the
## south-west pillar leaves room for: at 218 the nearest post comes within 88 of it.
const ALCOVE_RADIUS := 200.0

## The radius of one of the bow's posts. The snug's, for the snug's reason: a screen, not
## a wall, and its neighbours are what bound it.
const ALCOVE_POST_RADIUS := 30.0


## The centre of the bow: a point on the south wall.
static func alcove_centre() -> Vector2:
	return Vector2(ALCOVE_X, ROOM_EXTENT.y)


## How far round from the wall each end post stands, in radians.
##
## [b]Derived so that the gate between an end post and the wall is exactly
## [constant DOORWAY_SPAN][/b], the way [constant SNUG_GATE_Y] derives the snug's: the end
## post's centre is the door's width plus its own radius off the wall. Widen the door and
## the bow's ends draw back from the wall with it.
static func alcove_end_angle() -> float:
	return asin((DOORWAY_SPAN + ALCOVE_POST_RADIUS) / ALCOVE_RADIUS)


## The bow's posts, east end first.
##
## [b]The count comes from the overlap, not from how it looks.[/b] The posts go at even
## angles from end to end, and there are as many as it takes for no two neighbours to be
## further apart than [constant GALLERY_OVERLAP] short of touching — the partition's rule,
## for the partition's reason: two tangent circles leave a contact point
## [method resolve_circles] can push a walker straight through. At these numbers that is
## ten posts.
##
## The trigonometry is evaluated identically on both ends of a connection, because both
## run the same build; the last-digit difference two platforms' [code]sin[/code] could
## disagree by is fourteen orders of magnitude under the reconcile epsilon in
## [method net_config].
##
## Separate from [method furniture] for [method gallery_screen]'s reason.
static func alcove_screen() -> PackedVector3Array:
	var out := PackedVector3Array()
	var start := alcove_end_angle()
	var sweep := PI - start * 2.0
	var chord := ALCOVE_POST_RADIUS * 2.0 - GALLERY_OVERLAP
	var step := 2.0 * asin(chord / (2.0 * ALCOVE_RADIUS))
	var count := int(ceil(sweep / step))

	for index in range(count + 1):
		var angle := start + sweep * float(index) / float(count)
		out.append(Vector3(
			ALCOVE_X + cos(angle) * ALCOVE_RADIUS,
			ROOM_EXTENT.y - sin(angle) * ALCOVE_RADIUS,
			ALCOVE_POST_RADIUS
		))

	return out


## Whether [param at] is inside the alcove rather than in the hall.
##
## Inside the bow's post line, and between its two end posts — so somebody in a gate is
## inside once they are past the end post, which is what a person standing there would
## say, and a point against the wall but out past either end is in the hall.
static func in_alcove(at: Vector2) -> bool:
	var half := cos(alcove_end_angle()) * ALCOVE_RADIUS
	return (
		at.distance_to(alcove_centre()) < ALCOVE_RADIUS
		and absf(at.x - ALCOVE_X) < half
	)


## Whether [param at] is in the wing behind the partition rather than in the hall.
##
## [b]Read from the same constant the posts are placed from.[/b] A check that wrote
## -620 again would keep passing after the wall moved.
static func in_wing(at: Vector2) -> bool:
	return at.x < WALL_X


## Pushes [param position] out of any furniture it is inside. Returns where it ends up.
##
## [b]Static and side-effect free, because both ends call it and one of them calls it
## inside a prediction replay.[/b] Anything stateful here — a cached nearest obstacle, a
## "was I stuck last tick" flag — is state a replay does not have and a correction the
## player sees.
##
## [param out_normal] is filled with the push direction when there was one, so the caller
## can also kill the velocity going into the obstacle. Without that a player holding a
## direction against the island is pushed out and accelerated back in on every tick, and
## the resulting jitter reads as lag.
static func resolve_furniture(
	position: Vector2, radius: float, out_normal: Array
) -> Vector2:
	return resolve_circles(position, radius, furniture(), out_normal)


## The same resolve against any list of circles.
##
## [b]Split out because the furniture is no longer the only thing standing in the
## room.[/b] [RoomProps] holds what people have placed and it is exactly the same
## problem — a list of `(x, y, radius)` both ends have to push a walker out of
## identically — so it is exactly the same function. A second copy of this loop is a
## second thing that can round differently, and rounding differently is a player being
## corrected out of a space that looks empty.
static func resolve_circles(
	position: Vector2, radius: float, circles: PackedVector3Array, out_normal: Array
) -> Vector2:
	var resolved := position

	for piece in circles:
		var centre := Vector2(piece.x, piece.y)
		var clearance := piece.z + radius
		var away := resolved - centre
		var distance := away.length()

		if distance >= clearance:
			continue

		# Dead centre. A zero-length normal would come out as NaN and put the walker
		# nowhere, so the tie is broken toward +X — deterministically, because the one
		# thing worse than an arbitrary direction is two machines choosing different
		# arbitrary directions.
		var normal := away / distance if distance > 0.001 else Vector2.RIGHT

		resolved = centre + normal * clearance
		out_normal.append(normal)

	return resolved


## The netcode's settings, in one place both ends read.
##
## [b]Built here rather than three times.[/b] A server, a client and the offline pair each
## need one, and any field they disagree about is a field that decodes to a different
## value on the two ends — silently, because a bit-packed reader cannot tell a wrong range
## from a right one. [param authority] is the only thing that differs.
##
## [param authority] is [Variant]-free on purpose: everything else about the two roles is
## the manager's, not the config's.
static func net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = TICK_RATE
	config.snapshot_rate = SNAPSHOT_RATE

	# [b]Larger than dot-net's default, and it has to be.[/b] A replicated position is
	# quantised to [constant Dot2DNetSync.POSITION_BITS] bits over
	# ±[constant Dot2DNetSync.WORLD_EXTENT], which is a step of about 0.016 units — bigger
	# than the 0.01 default. Left alone, every single reconciliation measures the
	# quantisation as an error, `correction_rate()` reads ~1.0 whether or not anything is
	# wrong, and the one number that says whether prediction is working says nothing.
	# 0.05 is [method Dot2DState.matches]'s own tolerance, chosen for the same reason.
	config.reconcile_position_epsilon = 0.05

	# Nothing in a lobby is a hitscan shot and nothing is disputed, so rewinding the world
	# would change an outcome nobody is arguing about. Off, and said here rather than left
	# at whatever the default happens to be.
	config.enable_lag_compensation = false
	return config


## What somebody may wear, as a document with no art in it.
##
## [b]In [RoomContent] for the same reason the room's size is: both ends read it.[/b] The
## server validates a published avatar against these slots and these parts without loading
## anything, and a client draws the ids it is sent as shapes — see
## [method RoomRenderer._draw_avatar]. A client holding a different schema would draw a
## part in the wrong place, or refuse one the server had accepted, and nothing would
## error on either side.
##
## Three slots and eight parts, which is small on purpose. A lobby is where you *choose*
## how to look before you go and play something, so what matters is that the choosing
## works end to end — the server refusing something you have not unlocked, the choice
## surviving a reconnect, and everybody else seeing it. A hundred hats would prove
## nothing more.
##
## [b]One part is not free.[/b] `hat_crown` requires an entitlement, and it is here for
## the reason game-hungario's `greedy` is: entitlements default to nothing, so a server
## that granted everything would work perfectly in every test, ship, and quietly be a
## game where every unlock is free — and nobody reports that as a bug.
static func avatar_schema() -> DotAvatarSchema:
	var schema := DotAvatarSchema.new()
	schema.id = &"room_person"
	schema.version = 1

	# Layers, low to high: a badge sits on the body, a face over that, a hat over both.
	# The renderer here draws them in the order it is given rather than by layer, which
	# is legitimate for three shapes that do not overlap — and the layers are still
	# correct, because the moment a deployment resolves these to real content it will be a
	# rig that does honour them.
	var badge := DotAvatarSlot.make(&"badge")
	badge.display_name = "Badge"
	badge.layer = 20

	var face := DotAvatarSlot.make(&"face", true, &"face_plain")
	face.display_name = "Face"
	face.layer = 40

	var hat := DotAvatarSlot.make(&"hat")
	hat.display_name = "Hat"
	hat.layer = 60

	schema.slots = [badge, face, hat]

	var parts: Array[DotAvatarPart] = []

	for entry in [
		[&"face_plain", &"face", true, 1],
		[&"face_wide", &"face", true, 1],
		[&"face_narrow", &"face", true, 1],
		[&"hat_cap", &"hat", true, 1],
		[&"hat_band", &"hat", true, 1],
		[&"hat_crown", &"hat", false, 1],
		[&"badge_dot", &"badge", true, 1],
		[&"badge_ring", &"badge", true, 1],
	]:
		var row: Array = entry
		var part := DotAvatarPart.make(row[0], row[1], bool(row[2]))
		part.colour_channels = int(row[3])
		# Everything in the face slot falls back to the plain one, so somebody wearing a
		# part this build has never heard of is drawn as a person rather than as nothing.
		# The plain face has no fallback: a part that fell back to itself is a resolution
		# loop that cannot terminate, which the schema refuses — and which
		# game-hungario's `headless_round` never noticed for a while because it never
		# validated a schema.
		part.fallback_id = (
			&"face_plain" if row[1] == &"face" and row[0] != &"face_plain" else &""
		)
		parts.append(part)

	schema.parts = parts
	schema.invalidate()
	return schema


## What a person with no stored avatar looks like.
##
## [b]Derived from their id, exactly as their colour is.[/b] A client that has not been
## sent somebody's avatar therefore draws the same guest as everybody else rather than a
## different one per machine — which is the property that makes a default worth having at
## all.
static func default_avatar(occupant_id: int) -> DotAvatar:
	var avatar := DotAvatar.make(&"room_person")
	var faces := [&"face_plain", &"face_wide", &"face_narrow"]

	avatar.set_part(&"face", faces[absi(occupant_id) % faces.size()])
	avatar.set_colour(&"face", 0, Color(0.10, 0.11, 0.14))
	return avatar
