# FS25_RoadFollow

Cruise control that steers. Two ways to use it:

1. **Assisted cruise control (the normal one).** Switch on the game's own cruise control (key 3). While you are on a road or track and pointing along it, the vehicle steers along the road ("ROAD ASSIST" shows at the bottom of the screen). Steer, touch a pedal or the handbrake and it hands control straight back (and stays out of the way for 1.5 s). If the road ends, or you are not on one, it is plain cruise control, straight ahead, as before. Console command `roadFollowAssist` switches this on and off.
   The **mouse wheel** works as the speed knob while it drives: 5 km/h per notch (`roadFollowWheel <km/h>`, 0 = off).
   It behaves like an autopilot, not a hint: it corrects a drift off the road with speed and steering, joins a road from the side at an angle (slowing for the merge), and **stops the vehicle** (cruise off, with a message) if it is leaving the road, can't get back, or loses the road at speed. Steering, a pedal or the handbrake always hand control straight back.
   **At junctions it goes straight on by default.** Signal with **Right Ctrl + Left / Right** (rebind them in the controls menu: "Turn signal left / right"; these are keys no base game action or other mod of ours uses: numpad 6 is the rear work light and numpad 2 the hazard lights, which is why the old numpad keys were unreliable). **Right Ctrl + Up / Down** set the speed (as the mouse wheel does). It works whatever the vehicle is doing, standing still, cruise control off, the assist not driving: the vehicle's own indicator lights go on (the game's own indicator keys count too). Left, on; left again, off; the other side switches it. With the assist driving, it then takes the next turn that way, planning the whole corner, and clears the signal once the turn is done. While a Ctrl key is held the steering keys are not read as the player steering, so a signal key never hands control over. (Tapping the steering keys and the left / right mouse buttons as signals are off by default: `RoadFollow.TAP_SIGNALS` and `roadFollowSignals`; a steering key then simply takes over at once.)
   If the vehicle starts to **weave** from side to side, the assist notices, looks further ahead and leans on the average direction of the last few seconds until it is steady again.
2. **Hands-off road follow.** Press **Right Ctrl + R** and a helper job drives the vehicle along the road until it ends. Press again (or the usual stop-helper key) to take over.

It reads the road and track layers of the **WAILA** map scan (`FS25_whatAmILookingAt`, a required dependency), so run the scan (Shift+G) or load a save that already has it.

- Speed (mode 2): the lowest of the vehicle's cruise control setting, the speed limit, what the bend / junction / end of the road allows, and what the collision check allows.
- At a fork it keeps straight on. At a junction or a yard it slows to 12 km/h and holds its line. At the end of a road it slows and stops ("The road ended").
- Console command `roadFollowDebug` draws the centre-line the follower sees (green = road ahead, yellow = it ends or meets open ground) while you drive by hand, so you can check what it would do.

Early version, singleplayer only. How it works: `scripts/RoadCenterline.lua` (pure geometry, tested offline in `tests/`), `scripts/RoadFollow.lua` (vehicle specialization), the AI job pieces modelled on FollowMe.

## Field mode and joining paths

**Cruise control on a field, no road at all:** the assist steers a course through it. It keeps the direction the vehicle was going and goes round trees, buildings, forest and
ground too steep to drive (the map's obstacle layers; the whole width of the vehicle and what it pulls is kept clear, with a little room to spare). A course is worked out
50 m ahead a few times a second and rejoins the original line behind an obstacle. Where there is no way through (a wall of trees, a gap too narrow) it stops in front instead of
guessing. Only on farmland, only with cruise control on, only at the field speed (20 km/h); `roadFollowField` switches it on and off.

**Joining paths from open ground:** a path is only joined when it runs within 15 degrees of the way the vehicle goes (`RoadFollow.JOIN_MAX_DEG`). A field path across the way is
ignored, unless you take the wheel yourself.

**The junction picture:** while you drive, the next junction ahead (a T, a Y fork, a + crossing, or a side road) is shown above the gauge, about 8 s ahead (at least 120 m): your road at the bottom, every way on as a leg at its angle, the distance underneath. Until you signal, the ways on **blink**; straight on at a crossing or a side road is shown green (that is where it goes without a signal). Signal left or right (Right Ctrl + Left / Right) and the leg that leads there turns **green and the blinking stops**; at a T or a fork there is no default. The signal keys also show in the key help at the top left, with the key the game really gave them (the log says it once at start: `keys: ROADFOLLOW_SIGNAL_LEFT = ...`). It is made from the same moving road map as the debug lines (`scripts/RoadAtlas.lua`, junctions classified in `scripts/RoadJunction.lua`), so it needs no extra reading while you drive. `roadFollowJunctions` switches it off.

**Terrain you edit:** the map picture (WAILA's road and trail bitmaps) is a snapshot of the terrain, so painting a road in the construction screen made the map wrong until the whole map was scanned again. Every terrain edit passes through the game's `TerrainDeformation` (construction paint / sculpt / smooth, terraforming mods, trail painting, placeables levelling ground), so the road follower hooks its `add...Brush` / `addArea` calls to learn which 8 m cells an edit covers, marks them when `apply` is called for real (not a preview), and starts the road map again when the deformation job has completed (`TerrainDeformationQueue:onJobComplete`). Marked cells are read from the terrain paint itself (WAILA's learned layer classes, live) instead of the snapshot, by the map and by the driving assist: a road you paint is followed at once, one you paint over is gone. The game has no "terrain changed" message of its own (checked), which is why the hook sits there.

**The road map debug tool:** `roadFollowMap [radius]` (again to switch off) draws a centre line for every road round you, moving along with you while you drive (white = road in the
map picture, orange = gravel / worn track, green posts = junctions, red posts = dead ends, pink = the circle that is read). Only the first look is a full sweep; while you move, only the
thin new edge of the circle ahead is read, so it costs a small share of the driving scan (the legend and the log show the map reads and ms per second). Nothing is read while you stand
still. The work is `scripts/RoadAtlas.lua`; the junctions it finds are what a later "approaching a T" display will use.
