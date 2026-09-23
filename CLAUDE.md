# game-simple-lobby

A lobby: a small 2D room with chat, a roster and join/leave notices. Read
`../../CLAUDE.md` first for the family-wide rules; this file is what is specific to this
game.

## Why this project exists

**A server with no game is a legitimate thing to run and there was nothing to look at.**
dot-server's own comment beside the empty-scene branch calls a scene-less server
"legitimate for a lobby", and until now no lobby existed. A player who connects to one and
sees a blank screen cannot distinguish it from a broken server.

**It is the first game meant to be delivered rather than shipped.** game-arena, game-blob
and dot-2d-hungry all ship inside their own build, so `changelevel` has never sent a client
to fetch a map and dot-server's content sync has never run end to end. This one is small
enough to be a pack — no art, no audio, no fonts — and it is what
[dot-server-deploy](../dot-server-deploy)'s client shell mounts.

**It is the smallest thing that still exercises the whole platform.** No scoring, no
rounds, no combat, no items. What is left is admission, membership, replication,
prediction and chat, and every one of those is something every other game also has to get
right.


## The moderator's live tools, in a room where nobody can be hurt

dot-moderation's live tools are on this server's console and in chat, and **what a lobby needs a moderator for is moving people and renaming them**: bring, goto, send, return and rename work, with a stand-off in pixels (48) rather than the addon's metre and a half, which would put one avatar on top of the other. Everything else is refused with a reason `modtools` prints — nobody can be hurt or die here, there is nothing to hold, and noclip, freeze and speed would be server-only changes to a predicted 2D motor that carries no admin modifiers, so the owner's client would rubber-band. `dedicated` sends one occupant to another, returns them exactly, renames one and has a slay refused.

## Chat is dot-chat's, and there is still exactly one path

It used to be dot-server's, whole: `DotChatManager` routed, sanitised, flood-limited and
permission-filtered every message and every client received one through
`DotClientLink.chat_received`. What changed is that **`DotChatRouter` took over the
rules**, because a lobby wants what that one does not have — channels with an audience, a
radius so somebody across the room is not in your conversation, a backlog for whoever just
walked in, a `/me`, and a gag that survives a reconnect.

**The important half is that there is still one path.** `RoomModule` hooks `player_chat`
with `hook_pre` and **cancels** it, so dot-server's own broadcast never happens; the line
goes to the router instead, and the router's `send_fn` comes out on this game's wire as
`RoomEvents.Kind.CHAT`. dot-server's join and leave announcements are turned off in the
same place, because dot-chat now makes them. Two paths would be two sets of rules to keep
in step, and the one that skipped the filter would be the one that leaked admin chat to
everybody — or that let a zero-width character through and rendered a name backwards.
`examples/sandbox.tscn` asserts that **nothing at all** arrives through dot-server's own
chat signal, which is the check that says the cancel works.

**The legacy path still works and is still the router's.** A browser shell's own chat box
and a client console's `say` both go through dot-server and have no way to name a channel;
the module forwards them onto the room channel rather than dropping them, and the sandbox
checks a line sent the old way comes back on the new wire.

The bubble over somebody's head is drawn from the same message the log is. One path, so a
bubble can never say something the log does not.

### The chat key is not the punishment subject, and the difference is measurable

dot-chat asks "who said this" through `key_fn`; dot-moderation asks "who is this" through
`key_for_peer`. They are separate seams and this game answers them differently:

- **A punishment is against a person who will come back**, so its subject is the durable
  account uid. A gag keyed by anything shorter-lived lasts until the gagged player presses
  reconnect, which is the first thing anybody who has been gagged tries — and is exactly
  the bug dot-moderation exists to fix in dot-server's two-booleans-on-a-session.
- **A chat line is attributed to somebody standing in this room right now**, so its key is
  the occupant.

Keying both by the uid looks obviously right and is wrong: **two guests connecting from
one machine share a device id and therefore share a uid**, so the second person's words
appear over the first person's head. `sandbox` runs two clients in one process and found
it — every count matched throughout.

## Voice

`DotVoiceManager` on each client, `DotVoiceRouter` on the server, and three decisions here.

**One RPC for both transports.** `RoomLink.send_voice` is `@rpc(..., "unreliable", ...)` on
its own channel. On ENet that is a UDP datagram that is never retransmitted, which is what
voice wants — a frame that arrives late is one the jitter buffer has already concealed. On
a WebSocket every transfer mode is TCP underneath and it is delivered reliably whether or
not that was asked for. That is a property of the transport rather than a gap here, and
writing two paths would be two paths to keep in step for a difference neither end can act
on.

**Push to talk, and the microphone closes with the keyboard.** A lobby is somewhere people
leave a tab open, and voice activation on an open tab is a room full of somebody's
television. `RoomVoice.release()` is called from the typing handler as well as from the key
release, because a key-up delivered into a text field is a gate that never closes — the one
voice bug people report as "everyone could hear me" rather than as a bug.

**Playback goes into a buffer when there is no audio device**, which is what makes the
receiving half checkable at all. `DotVoiceSinkPlayer` needs a mixer; a headless run has
none, and without a buffer sink a wire that decoded to nothing would look exactly like one
that worked. `sandbox` asserts an **amplitude**, not a frame count.

### The bug voice found in dot-voice

**The speaker id was 16 bits and a Godot peer id is 31.** A listener got a number matching
nobody, and — the half that is not merely useless — two players whose ids differ only above
bit 16 became one speaker: one jitter buffer, interleaved sequence numbers, one stateful
ADPCM decoder, and both of them noise. About a 3% chance per 64-player server. dot-voice's
own suite drives the router with speaker numbers like 2 and 7, all of which fit; this is
the first thing in the family to relay a frame between two real clients over real sockets
and then ask a listener **who** was talking. Fixed there, as wire version 2.

## Props: the room is furnished by the people in it

`dot-props` is here for its **book-keeping**, which is the dimension-free half: a
catalogue, a per-player budget, a spawn interval, a world cap, an undo stack, ownership,
and a cleanup when somebody leaves. `DotPropSpawner.spawn_2d` was added to dot-props for
this deployment — the coupling to 3D was twelve lines and none of it was about any of the
above.

**Everything is frozen the moment it lands**, and that is the whole reason a lobby can have
props at all. Rigid-body simulation is not reproducible across machines — dot-props says so
and every game here that networks props repeats it — so a prop that fell over would be
somewhere different on every client with nothing erroring. A frozen body is a static
obstacle, and both ends derive its collision from the same replicated position and the same
catalogue radius.

**Collision is a circle, always.** Same argument as the furniture: one normalise and one
multiply, exact, no corner case — and because both ends use the same circle they cannot
disagree, which is the property that actually matters.

**Three of the four things about a prop never travel.** What goes on the wire is a place
id, an **index** into the catalogue, a quantised position and a rotation; the radius, the
colour and whether anybody collides with it are derived from the same file both ends read.
The index is taken from a list sorted as `String` rather than as `StringName`, because
`Array.sort()` on a StringName compares interned pointers — dot-net shipped exactly that
bug with message ids and only a browser client could see it.

**The place id is adopted, never allocated.** A receiving peer that numbered things itself
gives the same bench two names on two machines and every count still matches, which is the
bug dot-2d had to gain `Dot2DScatter.adopt` to fix.

### What a picture found

The prop drawing was written, the suites passed, and the screenshot had **no props in it
at all**: `DotNodeRef.of_path(world.get_path())` needs the world to be in a tree, and
`tools/screenshot.gd` builds one from `SceneTree._initialize` where it is not. The spawner
refused every placement. The bodies are parented to `RoomProps` now, which is also the
right answer for a different reason — a prop outlives a `changegame` and the world does
not.

And once they drew: **a rug read as an obstacle.** A third-opacity fill with a solid rim at
a fixed size is exactly what the furniture looks like, so the two things a player may walk
over looked like the six they may not. There is no assertion that could have said so — the
radius was zero, the obstacle list was right, and both ends agreed. They are drawn now with
no shadow, no rim, a fainter fill and a dotted edge, at a size the catalogue gives.

## Identity: profiles, avatars and a platform

`RoomPlatform` builds dot-user, dot-user-avatar and `DotPlatformHub` with this lobby's
settings, and `examples/dedicated.tscn` loads `DotPlatformModule` beside `RoomModule`.

**It is optional and the lobby must work without it.** A LAN room somebody runs for an
evening has no accounts, and that is the most common deployment there is — so `RoomModule`
duck-types against the platform module rather than naming it. game-hungario's module takes
the same shape for the same reason.

**Guests get profiles.** `allow_guest_profiles` is on, which is not dot-user's default,
because the whole point of a lobby is that you can walk into one.

**An avatar arrives after the person does**, so it is its own event rather than a field of
the join: dot-platform resolves a profile and an avatar asynchronously and a lobby must not
hold somebody at the door while a cosmetic loads. A player you cannot see is worse than a
player with no hat.

**Ids and colours travel; no mesh, no scene, no download.** That is dot-user-avatar's whole
claim and this is the client end of it — the renderer draws a hat as an arc and a face as
two dots, and a slot it has never heard of as a mark beside the head, so somebody wearing
something from a newer catalogue is visibly wearing *something*. `hat_crown` is not free,
because entitlements default to nothing and a server that granted everything would work
perfectly in every test and quietly be a game where every unlock is free.

## The server browser, and what is still missing

`RoomBrowser` puts `DotBrowser` behind a table: DQP over UDP, DQP over a WebSocket in a
browser, A2S for everything else, with favourites, history and a local filter.

**Filtering is local and always will be.** A server that decided which of its own
properties to report is a server that reports whatever gets it listed.

**There is no master server, and this file is where that is visible.** A tracker has to be
told an address and nothing announces one, so the sources are the two that need no such
thing: where this person has been, and whatever they type.
`DotBrowserSourceBackbone` reads a listing website-city does not yet publish; adding it is
one line the day it does.

**And until now the server half was missing too, which is worse**, because it is the half
that breaks the source this game *does* have: somebody typing an address in. This room
answered no query at all — `query_enabled` was never set, no `DotQueryHost` was ever
attached, and `RoomModule` contributed no provider — so the one path that needs no tracker
reached a server that could not say what it was. dot-browser's own suite queries a server
dot-browser built, which is why neither end had noticed.

`RoomQueryProvider` is this game's half, and what it says is what a lobby's row is:
**the occupancy against the capacity**, and the split between the two sides. A browser
showing 0/0 for a room with five people waiting in it is a browser nobody uses twice, and
the side somebody picks here is the one they take into the match they go to, which is this
game's whole reason for existing. Both numbers come from the thing that owns them —
`RoomWorld.occupant_count()` and `DotTeamRoster.counts()` — rather than from a tally kept
beside them.

## Delivered, not shipped

`tools/publish_room.tscn` packages `game/` and `scenes/` into a signed dot-cloud pack: a `manifest.json` and a content-addressed `objects/` tree that drops behind any web server. `RoomModule.game_descriptor(manifest_url)` then produces the relative-path shape a generic shell mounts and instantiates.

A mounted pack's `class_name` globals are not registered in the host — measured, and in the family's own CLAUDE.md — so every script here reaches its neighbours by relative `preload`, and `RoomPaths.rebase()` wraps every `res://` string that names one of this game's own files. **The tool checks the staged files and refuses to publish if any declares a `class_name`.** It used to print "every script in this game uses `class_name`" unconditionally, on every run, for as long after the conversion as before it — a warning that is always printed is one nobody reads, which is the worst state for the one warning that means a pack will mount dead.

## The room has furniture, and it is in `RoomContent` for the same reason its size is

The room was an empty rectangle. It now has an island in the middle, four pillars marking
the quarters and two benches by the east wall — landmarks, so "by the north-west pillar"
means something and a lobby is a place with a shape rather than a plane everybody stands
in the middle of.

**The list lives in `RoomContent` and both ends collide against it.** An obstacle a client
draws and does not collide with is a client whose prediction disagrees with the server
every tick somebody walks into it; an obstacle the server has and the client does not is
worse, because the player is corrected out of a space that looks empty. The resolution is
a static function on `RoomContent` called from `RoomWorld.simulate_occupant`, which is the
one function a client replays.

**Circles, not rectangles.** Pushing a walker out of a circle is one normalise and one
multiply, is exact, and has no corner case. A rectangle has four, and the one where
somebody is exactly on a diagonal is the one that puts them inside.

**The velocity into whatever pushed is removed.** Without it a player leaning on the
island is pushed out by the resolve and accelerated straight back in by the motor on the
next tick, sixty times a second. The position stays correct and the movement reads as
lag — which is the worst way for a level to be wrong, because it sends the next person to
the netcode.

### A wall across it, and a second room behind that

The room was one space, and one space is one conversation. dot-chat gives a channel a radius so that somebody across the room is not in your conversation, and in a single open hall that radius is either the whole room or an invisible line across the middle of it. A partition people walk round is the same rule made visible.

Six posts on `RoomContent.WALL_X`, overlapping by twenty units each rather than merely touching — two tangent circles leave a contact point the resolve can push a walker straight through, because each circle on its own is happy to send them toward the other. The pair either side of the middle are the door posts and `DOORWAY_SPAN` between them is the only way across; it is wide enough to walk through without aiming, because a door that has to be aimed at is a door nobody uses.

**The wing behind it has its own furniture** — a counter down its west wall, a table at either end and a bench between them — with the lane beside it left clear, so the doorway opens onto somewhere to walk rather than onto a table.

`headless_room`'s **the wing behind the partition** section is what says any of that is true. A list of circles is happy to be a wall with a hole in it or a wall with no way through at all, and both of those are the same list with different numbers in it, so the section walks it: into a post and blocked, through the doorway and into the wing, and back out again. `RoomContent.in_wing` is read from the same constant the posts are placed from, because a check that wrote the number again would keep passing after the wall moved.

#### Walking ACROSS a room is not walking ALONG it, and nothing had done the second

The wing shipped on 2026-09-12 with two round tables of radius 55 standing at x = -770, in the middle of a strip 280 units wide. **It was not a room. It was a corridor with a cork in each end**, and a walker holding north from the doorway jammed against the partition at y = -266 and stayed there for the remaining 550 ticks.

The arithmetic is the whole lesson. The partition's posts eat `POST_RADIUS` off the wing's east edge and a walker's own radius eats another, which leaves about 146 units of usable band — **less than one table's diameter plus two walkers**. There is no arrangement in which a table of that size stands in the middle of this wing and the wing is still passable; the geometry had already decided, and the only thing that had not noticed was that nothing ever asked.

Everything else was green the entire time. The renderer drew it, the roster listed it, the resolve pushed people out of it correctly, the determinism section replayed it bit-identically, and `in_wing` answered honestly about a room nobody could reach the ends of. **The three checks in this section all walked across the wing, through its door, and back out the same door** — which proves a door, and proves nothing at all about a room.

Fixed by pinning all three pieces to the west wall (`WING_PIECE_X`) and sizing them against the lane they have to leave rather than against how a table looks (`WING_PIECE_RADIUS`, which leaves 72 units — wider than the window a walker has through the doorway, which is the width this room has already agreed is walkable without aiming). The section now walks the wing's length in both directions, and would fail again the moment anybody puts something back in the middle of it.

#### The north gate: a second way through, so one person in a doorway is not a locked door

The partition's northernmost post is at `NORTH_GATE_Y`, which is **derived** so that the gap it leaves against the north wall is exactly `DOORWAY_SPAN` — the front door's width, from the front door's constant, so widening one widens both and moving the room's north wall moves the gate with it. Written as -370 it would be a number that keeps its value after the thing it was measured from has moved.

The wing is a circuit now rather than a pocket: in through the middle door, up the lane, out at the north. That matters here more than it would in a shooter, because **a lobby is the one place people genuinely do stand in doorways** — it is a room whose entire activity is standing about talking — and a second room with one door and somebody parked in it is a room you cannot leave. `headless_room` drives a walker the length of the wing and out the gate, so the gate is a route rather than a gap in a list.

#### The gallery: a screen off the north wall, and the pillars are its doorposts

The wing made the room two spaces. The hall was still one space with an island in the middle of it, which means the only thing between two conversations in the main room is distance — and a lobby's main room is where everybody is.

`GALLERY_POSTS` posts stand off the north wall on `GALLERY_Y`, overlapping by the partition's twenty for the partition's reason. The strip behind them is `GALLERY_DEPTH` deep and is **left empty**, which is the opposite of the wing's rule and is the wing's lesson rather than a departure from it: the wing needs something to stand behind because it is a room you go to, and the gallery *is* the thing to stand behind. Four occupant diameters is two people stopped against the wall talking and two more getting past them, which is the only thing this strip has to do.

**Both ends of the screen are placed against the north pillars rather than against the wall**, and the count is what places them. A post 167 units from a pillar centre leaves 52 between their faces and 8 for a walker — a slot nothing can pass, which reads in a picture as a way through and is this family's own recurring bug. A screen that stops 300 short has mouths so wide the gallery is not a room. At six the ends stand 265 from the pillar beside them, which leaves 169: more than the front door and less than a third of the hall.

**The screen is thinner than the partition and the hall is what decided so.** The room's north half is 410 units from the island's edge to the wall, and the screen has to fit its own thickness, the gallery behind it and the hall's north lane into that. At the partition's radius of 90 the lane came out at 94 — a walker's window of 50, in the main room, which is the wing's bug moved into the hall. The check that says so measures the narrowest way past the screen *anywhere*, against the furniture that exists rather than against the constants, so it sees the hall lane as well as the two mouths; it read 100 against 100 and failed, and the radius is 50 now and it reads 136.

**Its section drives the room rather than describing it**, because that is what the wing cost: a walker goes north past the screen's west end, then holds east until the far side, and has to come out past the east mouth having been behind the screen the whole way. Two held directions, nothing steering.

And one check in it was worth more than the level. The first version asked `in_gallery` which pieces of furniture were the screen and got **none of them** — a post's centre sits exactly on `GALLERY_Y` and that predicate is a strict `<` — so the mouth measurement compared an empty set against an empty set and reported `inf` as a pass. "Is this point in the strip" and "is this circle part of the screen" are two questions and only one of them is a position test; `gallery_screen()` is the second one, and it is what `furniture()` builds the screen from.

#### The snug: an L off the south-east corner, a gate at each end, and a seat in the crook

The wing is a room you go to and the gallery is a thing you stand behind. Neither is somewhere to *sit*, and the south-east quarter of the hall was the one part of the room with nothing in it.

An L of `SNUG_POST_RADIUS` posts stands off the corner: a north arm running east and a west arm running south, **sharing one corner post**. Each arm stops `DOORWAY_SPAN` short of its wall, derived the way `NORTH_GATE_Y` is (`SNUG_GATE_X`, `SNUG_GATE_Y`), so the snug has two gates against two walls and is a circuit rather than a pocket. The shared corner is placed rather than left to arithmetic: without it the arms' first posts overlap across the diagonal by `2r - spacing·√2`, which is 3.4 units at these numbers and a 13-unit hole at the gallery's.

**The neighbours size it, not the corner.** Two things box it in and it must not narrow either of them: the south bench above it and the south-east pillar beside it. That is why the posts are 30 rather than the gallery's 50, and why `SNUG_ARM_POSTS` is three. At four, the north arm's face comes within 70 of the bench and the corner post within 74 of the pillar: two slots in the hall, narrower than the front door, made by a room nobody is standing in. At three those gaps are 110 and 116.

**The seat is sized from the floor round it, and the first size came from a picture.** It sits in the crook against both arms' inner faces. Version one filled the crook out to the inner edge of each gate, so a walker coming straight through either gate still never touched it. Every check passed, and `tools/screenshot.sh` showed a clump of circles in the corner with two door-width corridors round it: the wing's corridor-with-furniture drawn again. `SNUG_SEAT_RADIUS` now leaves a band between the seat and each wall of one occupant's width plus `DOORWAY_SPAN`, which is one person standing at the seat and another getting past them. It came out at 38.

`headless_room`'s **the snug** section drives it both ways round, on two held directions each way. South from the benches down the east gate to the far wall, then west under the seat and out the south gate. Then east along the south wall in by the south gate, and north out the east gate. On the way down it asserts that the seat stands no further into the gate's lane than the gate's own post does. Its first version asked only "did not touch", and that passed with the seat twelve units into the lane. The gap measurement includes the **walls** this time, because both gates are against one and a gate derived against a wall is a gap no circle pair ever sees. It reads exactly 100 against 100 at the east gate, which is the derivation holding.

**And the room is now asked the other half of the question.** The wing, the gate, the gallery and the snug each asked whether a walker gets through a gap; nothing asked whether there is anywhere in the room a walker fits and *cannot reach*. That question produces a sealed pocket that every picture shows as floor. **anywhere a walker fits, a walker can reach** lays an 8-unit grid over the room, marks every point a walker's centre fits at, and floods from the hall: 21,707 points, all of them reached. With both snug gates closed it reports the pocket and where it starts.

##### The check it found: a crowded level that `headless_net` promised to fail on, and passed

`headless_net`'s **under loss** section walks along `_clear_heading`, which scans 64 headings from the spawn for one clear of furniture for 480 units. Its comment says that if there is none, *"a level this crowded is a level worth failing on rather than one to quietly measure a grinding walk in"*. The code under that comment called `push_error` and returned `Vector2.RIGHT`. A `push_error` is a line on stderr and changes no exit code, so with no clear heading anywhere (forced by lengthening the reach) the suite walked due east into the wall, measured a correction rate against it, and exited 0 with **65 passed, 0 failed**. The one outcome the comment ruled out.

The snug is what made it worth looking at. The spawn is the ring's east seat and the heading the scan used to choose, 45°, runs straight through where the snug now stands. The scan now picks 101° (rate 0.275 → 0.300, drift 0.063 → 0.072, both well inside their bars). A heading that silently gives up is the level after this one making the loss section measure a wall. It returns zero now and the section fails a check on it, `there is open floor to walk on from the spawn`, which fails and exits 1 with the reach lengthened.

**Not folded in: `[lobby-earshot-1]`.** The snug is the obvious room to be out of earshot in, and it isn't. `near` is still a radius through its screen, as it is through the partition. The fix is a `can_hear_fn` seam in dot-chat's router and dot-voice's, and it belongs in those two repositories rather than in a position function that lies about where somebody is standing.

**The spawn is resolved too.** `Dot2DArena.spawn_position` knows the room's rectangle and
nothing about what is standing in it, so a share of its answers are inside something. A
lobby that puts somebody inside a bench is broken quietly.

### What the furniture cost in the netcode suite, and what it did not

The "under loss" section's correction rate went from 0.325 to 0.475 when the room gained
furniture, and the interesting part is that **none of it was the furniture**.

- The old walk aimed at the middle of the room, which is now the island — so it measured
  a player grinding against a curved obstacle, which is the most divergence-amplifying
  thing in the room.
- Rerouted to "open floor", the first attempt scanned the grid from a corner and returned
  a point pressed against two walls. 0.475.
- Rerouted again to a heading checked *along its whole length*, it reads 0.375 — **and it
  reads 0.375 with the furniture list emptied as well.** That control is the answer: under
  a quarter of snapshots dropped, two different paths of the same length through the same
  simulation report rates five points apart.

So the drift is the evidence and the rate is a proxy: 0.078 units of disagreement is two
ends running the same simulation whatever the rate says. The threshold is 0.45 now, with
the measurement written beside it, and stays under 0.5 because 0.5 is what a second
reconciliation pass looks like.

`headless_net` gained an **against the furniture** section, and its first version failed
at 20.6 units apart — which was not a disagreement either. The client's input timeline
leads the server by the flight time plus a margin, so a *moving* client is meant to be
about five ticks ahead, and five ticks of walk speed is twenty units. Sliding along a
curve turns that lead into a distance instead of hiding it behind a straight line.
Comparing two ends while one is deliberately ahead measures the lead. It settles first now.

## Everybody is always relevant, and that is what caps the room

`DotNetIdentity.always_relevant` is set on every occupant. A room is smaller than a screen
and the roster names every person in it anyway, so hiding a position would save thirteen
bytes a snapshot and produce a name in the list with nobody under it.

`RoomContent.MAX_OCCUPANTS` is what makes that affordable and it is the only reason the cap
exists. Past it a lobby needs interest management, at which point it is not a lobby.

## The bugs this project found

Every one of these parsed cleanly and none produced an error. Four are in other projects
and none was reachable from that project's own suite.

**In dot-net — the input timeline did not include the flight time.**
`DotNetClock._target_lead()` returned `input_margin_ticks` alone. A command stamped for
tick N has to be in the server's hands *before* it simulates N and spends half a round trip
getting there, so on any connection with more than about 30 ms of one-way latency every
input landed after its tick had passed, `DotNetInput.Buffer` discarded all of them as late,
and the server repeated whatever command it last had. The player moved perfectly on their
own screen and nowhere else, and the position was corrected back a few times a second, so
it read as a broken predictor. The class documentation on `input_margin_ticks` had said
"on top of half the round trip" the whole time; that half was never added.

It was unreachable from either existing netcode suite because **dot-2d-hungry's loopback
delivers everything in the same flush** — zero latency — and hand-stamps a lead of 2 with a
comment saying `DotNetClock` is what does this in a real deployment. This project's
loopback is the first in the family that delays a packet, and it delays in *ticks*, because
a wall-clock delay measured against a loop that advances a tick per frame is not a delay at
all: a headless run does several hundred frames a second, so a "60 ms" latency swallows
every packet for the first fifty ticks. The first version did that and the symptom was 240
units of drift, which reads as a broken predictor and is a broken clock.

**In dot-net — nothing ever calls `DotNetStats.note_rtt`.** It is a public method with a
median and a mean-absolute-deviation behind it, and `DotNetManager.receive_snapshot` reads
`stats.rtt_percentile(0.5)` on every snapshot to feed the clock. No caller anywhere in
dot-net writes a sample, so it always reads zero — dot-net never touches a transport and
cannot measure it. The host has to feed it, and until this project nothing knew that.
`RoomBridge.rtt_source` is the seam, pointed at `DotClientLink.ping_ms()` on a real client
and at the loopback's own known delay in a test. Fixing the lead without also fixing this
would have changed nothing.

**In dot-net — the first sample with a real round trip was treated as drift.** Once
`_synced` is set, `sync_from_server` corrects proportionally at up to 5% a second, and a
six-tick error takes two seconds to close — two seconds during which every input is
discarded. The first anchor usually arrives before anything has measured the link, so it is
not drift from that: it is a different measurement, and it is now adopted outright, once.

**Here — `_net_state_applied` moved the node on a predicted entity.**
`DotNetManager.receive_snapshot` calls it, through `read_state`, *before* it calls
`DotNetPredictor.reconcile` — and the first thing reconcile does is capture the node as
"what the client is currently showing", to measure how wrong the prediction was. Writing
the server's position there first makes that capture the server's position, so the measured
error is the entire replay distance rather than the disagreement. `correction_rate()` read
0.909, every reconciliation logged a snap, and the simulation was right the whole time,
which is what made it hard to see. **`HungryPieceNet` has the same line.**

**Here — the peer map was written after the world was told.** `RoomWorld.add_occupant`
emits `occupant_joined` synchronously and the handler builds the `DotNetIdentity` from
`peer_for_occupant`, so writing the map afterwards gave every entity `owner_peer_id = 0`.
Nothing errors: the entity replicates perfectly and is simply owned by nobody, so
`DotNetManager._apply_input` hands the peer's commands to an empty list.

**Here — the scene-instantiated world never had `setup()` called.** `DotGameManager`
instantiates a game's scene and nothing in dot-server knows a world needs setting up, so
the documented way of loading this game produced a world with no arena that registered no
service, and the module refused to load with "No RoomWorld is registered". The scene loaded
perfectly. `auto_setup` is on by default now, and `setup()` is idempotent.

**Here — the descriptor named an absolute client scene.** Exactly the trap dot-server's own
CLAUDE.md describes: `DotClientLink._resolve_scene` refuses every absolute path outside
dot-cloud's mount, correctly, so the client refused it, never reported loaded, sat in
`LOADING` sending no heartbeats and was timed out for being idle. A game shipped inside its
build must name *no* client scene. `RoomModule.game_descriptor()` now takes a manifest URL
and produces either shape, because both are real deployments of this game.

**Here — a `Dot2DState` position quantisation step larger than dot-net's reconcile
epsilon.** 20 bits over ±8192 is 0.016 units; the default epsilon is 0.01. Every single
reconciliation therefore measured the quantisation as an error and `correction_rate()` read
~1.0 whether or not anything was wrong — so the one number that says whether prediction is
working said nothing. `RoomContent.net_config()` sets 0.05, which is `Dot2DState.matches`'s
own tolerance, chosen for the same reason. **Any dot-2d game on dot-net has this.**

**In dot-net — `Array.sort()` on a `StringName` does not sort lexicographically.**
Godot compares StringNames by their interned pointer, so `DotNetMessageRegistry.seal()`
gave the same message type different wire ids on two peers and hashed two different
schemas. Found from `dot-server-deploy`'s browser client, which is the first peer in
this family that is a separate program; every suite here runs both ends in one process and
shares one intern table. `headless_net` now asserts the order is lexicographic, which
catches it without two processes.

**Here — `set_anchors_preset` does not set offsets.** The anchors describe how a rectangle
should follow its parent and change nothing until something resizes it, so a `Control`
built in code keeps the zero size it was created with. Every child then lays out inside
nothing and the whole interface is invisible while being, by every property, correctly
configured. The chat log, the roster and the feed were all built, populated and drawn at
size zero.

**Here — the leave broadcast went to the peer that had left.** `remove_peer` erased the
peer from the ready set after telling the world, and telling the world fires
`occupant_left` synchronously. Harmless, and it put "Attempt to call RPC with unknown peer
ID" in the log of every single disconnect — which is where somebody looks when something
else is wrong.

**Here — the module was never moved onto the next world.** It was built to outlive a game change — the netcode, the props and the services are all its own for that reason — and `RoomBridge.rebind` was written and documented as what a game change does. Nothing called it: `DotModuleHost` calls `_module_game_changed` and this module did not override it. So on any server that keeps its modules loaded across a `changegame`, the bridge held the freed world, `live_world()` answered null, the tick returned early on every frame and the room froze with everybody still in it; `room_status` died on a freed object while the console reported success, and the next person to connect reached `add_occupant` on the freed world. `rebind` itself had never run either, and read the freed world twice — so it keeps each occupant's name now rather than asking a scene that is gone. `dedicated`'s **a game change** section is what says it works: six of its checks failed before.

**Here — the seat chooser never read the seats.** `RoomPlayerStack` handed dot-spawn an `enemies_fn` so that people who arrive together are spread out, on top of `DotSpawnRules.deathmatch()`, whose mode is `RANDOM` — which never consults `enemies_fn`. Of eight arrivals in an empty room the sixth and eighth stood exactly on the first while two seats went unused. It is `FURTHEST` now, and `RoomWorld` falls back to the arena's scatter once the eight seats are taken, because past that the best seat is always somebody's. Found by `tools/screenshot.sh`: two nameplates printed over each other.

**Here — a punishment length that was not a number was permanent.** `room_gag ada 10m` read the length with `arg_int`, whose default for anything that is not an integer is 0, and 0 is permanent — against a uid that outlives the session on purpose. `RoomModule.parse_seconds` refuses what it cannot read, keeps a bare number as seconds, and takes `10m` / `2h` / `perm` the way dot-server's own commands do. `room_unpunish` also refuses a name that matches more than one person now, as `room_gag` always did.

**Here — the prop palette sat on the chat entry.** Centred on the window, it started at 387 px on this project's own 1280 × 720 window, and the entry runs to 476. It starts beside the chat column now. A frame found it; every `Control` involved had a size and a position.

## The suites, and which one matters

```bash
tools/check.sh                # every suite ci.yml names, after a parse pass
```

| | | |
| --- | --- | --- |
| `headless_room` | 68 | the room alone. Membership, walls, every level walked by a held direction, a flood over the whole floor for sealed pockets, and two worlds replaying the same commands bit-identically |
| `headless_stack` | 24 | the player layer: the collision layout, the two sides, the class as a choice nothing applies, and the ring of seats — filled past eight, because two arrivals cannot tell a seat chooser from a coin |
| `headless_presentation` | 74 | settings, audio, effects, the console and the party — **none of which `headless_room` can reach**, because that one is `RoomWorld` alone and has no client in it |
| `headless_net` | 66 | every encoder against its decoder, then a session over a lossy delaying loopback, then a walk into the furniture |
| `dedicated` | 118 | a real `DotServer`, a real module, a real WebSocket listener, and the props, chat, voice, moderation and identity halves — and a game change under the loaded module, to another room, to a game that is not one, and back |
| `sandbox` | 62 | **a real server and two real clients, over real sockets, in one process** — chat, props and voice all cross a wire here and nowhere else |

**The list of suites lives in `.github/workflows/ci.yml` and nowhere else.** `tools/check.sh` reads its `suites:` line and fails if `release.yml`'s differs. Before that, check.sh carried its own list, which had lost `headless_stack`, and CI auto-detected `examples/headless_*` — so neither `dedicated` nor `sandbox`, the two that run a real server, ever ran in CI.

**Both server suites turn dot-server's stdin console off**, because its reader thread blocks in a read nothing can wake: on an open pipe that never closes (`sleep 130 | godot ...`, or a CI step), `sandbox` printed "62 passed, 0 failed" and then never exited. **And both write punishments into their own directory** through `RoomModule.punishments_path` — `dedicated` had been writing a test gag into the real `user://room_punishments.json` on every run, 61 of them by the time anybody counted.

**`sandbox` is the one that matters and the slowest to write.** It is the only place
dot-server's signon, the RPC node paths, dot-server's chat and this game's netcode run at
once, and the only place two people are in the same room — which is the thing a multiplayer
game must do and the thing every per-observer decision is trivially correct about with one
observer. Three of the bugs above are its.

It runs three `MultiplayerAPI` instances in one tree, scoped by
`SceneTree.set_multiplayer`, and every one of the three link nodes is named `Server`,
because Godot routes an RPC by the receiver's node path relative to its API root. The name
is the routing, not a description.

Each suite counts **sections entered against sections that ran to their last line** and
fails when they differ. A runtime error inside a section aborts that function and nothing
says so: the checks that already ran still print ok, the ones after it never happen, and
the total at the bottom cannot reveal a check that never ran.

## Where a game plugs in

| To change | Where |
| --- | --- |
| The room's size, speed, capacity, palette | `RoomContent` — constants, because both ends read them and a mismatch is silent |
| What is standing in the room | `RoomContent.furniture()`, collided against by both ends and drawn from the same list |
| The netcode's settings | `RoomContent.net_config()`, in one place so three call sites cannot drift |
| Where a command comes from | `RoomInput.command_source` — bots, demo playback, tests |
| How somebody is drawn | `RoomRenderer`, which reads the world and never writes to it |
| Where the round trip is measured | `RoomBridge.rtt_source` |
| Whether the world sets itself up | `RoomWorld.auto_setup` |
| Which link a client uses | `RoomClient.link`, assigned before it enters the tree |
| What can be put in the room, and how much of it | `RoomProps.catalogue()`, `PER_PLAYER`, `WORLD_BUDGET`, `PLACE_INTERVAL` |
| What a player may change, and who owns each setting | `RoomPresentation.schema()` — one list, read by the console, the store and a screen |
| What the lobby makes a noise about | `RoomPresentation.sound_catalogue()` |
| What it draws | `RoomPresentation.fx_catalogue()` |
| What the client's own console can do | `RoomPresentation._local_commands()` |
| Where friends meet when there is no server | `RoomParty.signalling_url` |
| Where a chat line may be said and who hears it | `RoomServices.chat_channels()` — four channels, one of them a radius |
| What a chat line may contain | `RoomServices.chat_rules()` |
| Where punishments live | `RoomServices.punishments_path`, or a `DotPunishmentStore` subclass |
| Who counts as an admin, and what a speaker's key is | `RoomServices._is_admin` / `_key_of` / `_subject_for_peer` |
| The voice format both ends must agree on | `RoomServices.voice_config()` |
| Whether voice is proximity or the whole room | `RoomServices._build_voice`, one line |
| What somebody may wear | `RoomContent.avatar_schema()` |
| Where profiles and avatars are stored, and the pseudonym scope | `RoomPlatform` |
| Which servers the launcher knows about | `RoomBrowser._start`, a `DotBrowserSource` each |

## Looking at it

```bash
tools/screenshot.sh          # -> screenshots/room.png, gitignored
tools/screenshot_menus.sh    # -> screenshots/menu_*.png, the pause and settings screens
```

`screenshot_menus.sh` is separate because a room wants a camera framing a world and a menu wants a viewport-sized stack with nothing behind it. It found the seventh bug of the pass that added it: **`DotSettingsConfig` emitted no `PROPERTY_USAGE_GROUP` entries**, so this game's eight settings all appeared under one heading called "Resource" — the base class name — instead of Audio, Chat and Accessibility. `DotSettingsDef.category` had carried those words since the class was written and reached nothing; the panel drew perfectly and the heading was a plausible word.

Needs `xvfb-run`: `--headless` gives a null renderer and saves empty frames, which is
worse than no screenshot because it looks like one. Copied from `game-arena`'s rather than
shared with it, because these are separate repositories.

**It took three attempts to frame, and every failure looked like a renderer bug.**
`root.size` read in `SceneTree._initialize` is whatever the window was created with before
the platform has finished sizing it — 121 units wide on this box — which fitted an
1800-unit room into a postage stamp. A `Camera2D.zoom` fitted by the documented convention
came out magnified instead, so the walls were off every edge. It scales and offsets the
renderer node now, because `scale` multiplies and `position` is where the origin lands and
there is nothing to get the direction of.

`RoomWorld.setup()` is also called explicitly there: a node added from `_initialize` gets
its `_ready` on the first frame, so `world.arena` is still null and `add_occupant` fails
with "Nonexistent function 'spawn_position' in base 'Nil'" — which reads like a missing
method rather than like a node that has not started yet.

## The presentation layer: four addons that belong to the person, not the room

`RoomPresentation` holds dot-settings, dot-audio, dot-fx and dot-console, on the client
only. They are together for the same reason `RoomServices` exists: **the joins between
them are the whole point.** The settings document is where the volume lives, the mixer is
what reads it, the console is what changes it from a keyboard, and none of the three
addons knows the other two exist.

**None of it runs on the dedicated server.** A settings document belongs to a person, a
sound belongs to a machine with a sound card, an effect belongs to one with a renderer,
and a console belongs to somebody with a keyboard. The server has dot-server's own
console, which this one *bridges to* by duck typing when the two are in one process — so
this file names no dot-server type and a client with no server still works.

**Every declared setting is a console variable, by reflection over the schema.** A setting
added to `RoomPresentation.schema()` appears in the console, in a generated settings screen
and in the saved document at once, with nobody editing three files. That is this tree's
most repeated bug — two copies of one list — not happening, and it is why the schema is a
static function rather than a resource somebody fills in twice.

Three decisions in it are this lobby's rather than the addons':

- **The chat notification has a cooldown and the whisper does not share it.** A room of
  twenty people typing is twenty notification sounds a second, which is not a busy room,
  it is a fire alarm. A whisper and a line with your name in it are louder and higher
  priority, because both are addressed to you.
- **`near_range` is the only setting a server may clamp.** A room that wants everybody to
  hear everybody caps how far a voice carries; a server that could read the volume, the
  audio device or the key bindings would be assembling a fingerprint that survives a new
  account.
- **`show_timestamps` and `chat_lines` are ACCOUNT-scoped.** A lobby is where somebody
  configures themselves before going somewhere else, so the settings that are about *them*
  follow them into every game in this family that opts into `tmc_account`.

And the line every game with a console forgets: `_unhandled_input` returns early while
`presentation.swallows_input()`. This game turns letters into shortcuts, so without it
typing `settings` into the console cycles the chat channel four times and opens the chat
box.

## Escape opens a menu, which it did not

This client had a console and no menu at all. Escape put the prop palette down and did nothing else, so the only route to a setting was knowing that a console existed and what to type into it — which is not a route a player has.

`RoomMenus` registers a pause screen and dot-ui's `DotSettingsScreen`, and Escape is a **ladder**: stop typing, then put the palette down, then open the menu. One key still means "stop what you are doing", and the menu is what is left when there is nothing else to stop.

**The stack does not own the mouse.** `DotScreenStack.manage_mouse` forces CAPTURED whenever nothing is open, which is right for a first-person game and wrong for this one: the lobby is played with a visible cursor — a click places a prop — so a stack that recaptured on every close would take away the only control scheme this game has.

**Both screens are dot-ui's, and one of them was a copy for longer than it should have been.** Four clients in the family had written the same panel-title-buttons shape, and two copies of one thing is this tree's most repeated mistake. `DotSettingsScreen` was adopted the day it existed; `DotPauseScreen` was not, so this file went on holding the forty lines the addon exists to hold once — while dot-ui's own notes said four clients had stopped writing them. Three of the four had not. What is this game's own is which words are on the buttons and what happens when one is pressed, and that is what `RoomMenus` is now.

**The button ids are derived from the labels, never paired with them.** `DotPauseScreen.id_for("Leave")` is `&"leave"`; a list of labels and a parallel list of ids is two lists that can disagree. Resume and Settings are wired inside `install` because both are about the stack and nothing else; **Leave is not**, because what leaving means is the client's, which is the next paragraph.

**And the check that matters is not that it draws.** `DotSettingsManager.to_config()` hands out a *snapshot*, so a screen that called only the panel's apply would report success and change nothing. Every structural check passes either way — it builds, it has a size, it has focus. `headless_presentation` edits a value, presses Apply, and then reads the **manager** and the mixer.

**`leave_requested` is announced rather than acted on.** What "leave" means belongs to whatever loaded this client — a shell goes back to its own menu, an embedded page closes the frame. A client that called `get_tree().quit()` itself would be one that cannot be embedded in anything.

## Hosting for friends, and why this is the game for it

`RoomParty` is dot-peer-to-peer, and of the five games in this family the lobby is the one
it actually suits:

- **There is nothing to cheat at.** No score, no records, no entitlements, no reward. A
  host who can lie about the simulation can lie about where a bench is.
- **It is small.** Eight people in one room is inside what a domestic uplink carries.
- **It is the case a dedicated server is too much for.** "Come and sit in a room with me"
  should not need somebody to rent a box.

So the trust model is `HOST_AUTHORITATIVE` and that is a considered answer rather than a
default — `game-g2gfast` takes the same addon and refuses it, because its entire output is
records and a host who can cheat and a leaderboard are one exploit rather than two
features.

**It does not replace the netcode.** dot-net still carries the simulation and `RoomBridge`
still speaks it; the party produces a `MultiplayerPeer` and a membership list, which is
the part dot-server would otherwise have provided. And **a browser tab still cannot
listen** — the "Things deliberately not here" entry about a Host button stands for the
dedicated path; WebRTC is the one way round it, and it is the reason this addon exists.

## Watching somebody else

**A lobby is the smallest possible use of dot-spectate, and that is why it is here.**
This project exists to be the staging area — the smallest thing that still exercises
admission, membership, replication, prediction and chat — and a spectator camera has the
same shape as all of those: a rule the server owns, a state a client mirrors, and a
camera that has to point somewhere sensible when the thing it was following is gone.

Nobody dies in a lobby, so there is no death camera and no hand-over chain; both timers
are set to zero rather than left at their defaults, because **a timer that can never fire
is a thing somebody eventually spends an afternoon on**. What is left is the part a lobby
actually wants: follow somebody while you wait, and cope when they leave.

Two settings are the opposite of every other game's and both are deliberate:

- **A living occupant may watch.** Everybody here is alive; the deathmatch rule would
  mean nobody could ever watch anything.
- **Roaming is on.** A room twenty metres across is not a map to be scouted, and a free
  camera over it is how you look at the furniture.

`occupant_left` is connected rather than the camera being told directly, and the order
matters: dot-spectate picks a replacement from the participants list, so a game that
reports the departure *before* removing the occupant picks the occupant who just left.

## The one game that does not get a chat box, because it already is one

Every other game in this family gained dot-ui's `DotChatWindow` — a log, a line to type in, and `Y` to open it — because four of them could be talked to and could not talk back. This one is the exception, and the reason is worth writing down: `RoomUi` already draws the chat log, the channel palette, the roster and the entry, and **they are the game**. Dropping a second chat box over a chat room would be two boxes for one conversation.

What it takes from the family instead is the key. `RoomUi.OPEN_CHAT_ACTION` is an `InputMap` action, `chat_open_key` in the lobby's settings document sets it, and it defaults to `Y` like everywhere else. **Enter still works and always will**: this is a chat room, and a chat room that ignores Enter is broken.

**There is deliberately no `chat_window` setting here, and this is the only game where that is right.** Everywhere else the box is drawn over a game and "I chat somewhere else" is a sensible thing for a player to say. Here, turning it off leaves a person standing in an empty room with no way to say so. `headless_presentation` asserts the setting's *absence*, so nobody adds it later for symmetry.

The server still tells its clients what is carrying chat — `RoomServices` points `DotChatManager.watch_relay` at the relay it builds — because every other game uses that answer and the lobby is where the site's relay is most likely to be on. Nothing here hides anything for it.

## No message preloads itself

`room_event.gd` and `room_request.gd` each began by preloading themselves, for a typed `of()` factory. mg-buses-from-hell measured that line (8ed866c) as enough to leak the whole script graph at exit on Godot 4.7.2: a script that `extends DotNetMessage` and preloads ITSELF, first loaded by a module inside a running `DotServer` — which is how every deployed server loads a game. Both are built with `new(kind, body)` now, an `_init` whose arguments default because dot-net's registry decodes with a bare `new()`.

`dedicated`'s last section, **exiting clean**, reads every `DotNetMessage` script under `game/` as text and fails on a self-preload. It is on the source deliberately: the leak is printed by the engine after `quit()`, where no assertion can reach.

**Here it was not the cause, and the leak is still open.** `dedicated` exits with 232 ObjectDB instances, 170 resources and a VariantPools page, exactly as many before the change as after (2026-09-23) — the whole-script-graph shape, held up by something else.

## Things deliberately not here

- **Interest management.** Everybody is always relevant, and `MAX_OCCUPANTS` is the price.
- **Lag compensation.** Nothing here is disputed, so rewinding would change an outcome
  nobody is arguing about. Off, explicitly, in `RoomContent.net_config()`.
- **Persistence.** Nobody's position outlives their session, and a name that did would be a
  profile — which is dot-user's.
- **A wardrobe screen.** The schema, the entitlement check and the drawing are all here
  and a player cannot yet *choose*: `DotAvatarSchema.choices_for` is the call and a
  `DotScreen` over it is the missing half. Deliberate, because the thing worth proving was
  that a server decides what is legal without loading anything, and a screen does not
  change that.
- **A Host button.** A browser tab cannot listen, and offering a control that fails on the
  platform this game exists for is worse than not offering it.
- **Any actual audio files.** The catalogue is written and there are still no files behind it. That is the right way round — what this game was missing was never the files but the decision about what is audible, how many at once and how loud, which is a document and is `RoomPresentation.sound_catalogue()`. It is not silent any more: `sound_recipes()` gives each of the five ids a `DotAudioSynth` voice and the sink falls through to it when a path resolves to nothing. Everything a lobby makes a noise about is somebody *else* doing something, so all five are short and quiet by design — a room you sit in for twenty minutes is the one place in this family where an over-eager sound is something people mute the tab for. Dropping five `.ogg` files into `audio/` changes nothing else.
