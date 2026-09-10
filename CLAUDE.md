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
[dot-server-setup-test](../dot-server-setup-test)'s client shell mounts.

**It is the smallest thing that still exercises the whole platform.** No scoring, no
rounds, no combat, no items. What is left is admission, membership, replication,
prediction and chat, and every one of those is something every other game also has to get
right.

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

## Delivered, not shipped — and the one thing that stops it

`tools/publish_room.tscn` packages `game/` and `scenes/` into a signed dot-cloud pack:
25 files, a `manifest.json` and a content-addressed `objects/` tree that drops behind any
web server. `RoomModule.game_descriptor(manifest_url)` then produces the relative-path
shape a generic shell mounts and instantiates.

**And the pack does not work yet, which the tool says out loud rather than hiding.**
A mounted pack's `class_name` globals are not registered in the host — measured, and in the
family's own CLAUDE.md — so every cross-file type reference inside it fails to compile:
the pack mounts, the scenes load, and every script in it is dead. `preload` and
`extends "res://..."` by path both work. Converting this game to paths is what makes it
deliverable; the pack is produced anyway so the publishing half can be checked before that
work, and the warning is printed on every run so nobody discovers it from a black screen.

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
schemas. Found from `dot-server-setup-test`'s browser client, which is the first peer in
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

## The suites, and which one matters

```bash
tools/check.sh                # all four, after a parse pass
```

| | | |
| --- | --- | --- |
| `headless_room` | 31 | the room alone. Membership, walls, and two worlds replaying the same commands bit-identically |
| `headless_net` | 65 | every encoder against its decoder, then a session over a lossy delaying loopback, then a walk into the furniture |
| `dedicated` | 81 | a real `DotServer`, a real module, a real WebSocket listener, and the props, chat, voice, moderation and identity halves |
| `sandbox` | 61 | **a real server and two real clients, over real sockets, in one process** — chat, props and voice all cross a wire here and nowhere else |

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
```

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
- **A `class_name`-free build.** The pack publishes and would mount dead; see the section
  above. It is a mechanical change to every file in `game/` and it is the last thing
  between this and being genuinely delivered rather than shipped.
- **A Host button.** A browser tab cannot listen, and offering a control that fails on the
  platform this game exists for is worse than not offering it.
- **Audio.** dot-2d-hungry generates its whole bank arithmetically; there is nothing here
  worth hearing.
