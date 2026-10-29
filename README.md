# FS25_RoadFollow

Cruise control that steers. Two ways to use it:

1. **Assisted cruise control (the normal one).** Switch on the game's own cruise control (key 3). While you are on a road or track and pointing along it, the vehicle steers along the road ("ROAD ASSIST" shows at the bottom of the screen). Steer, touch a pedal or the handbrake and it hands control straight back (and stays out of the way for 1.5 s). If the road ends, or you are not on one, it is plain cruise control, straight ahead, as before. Console command `roadFollowAssist` switches this on and off.
   The **mouse wheel** works as the speed knob while it drives: 5 km/h per notch (`roadFollowWheel <km/h>`, 0 = off).
   It behaves like an autopilot, not a hint: it corrects a drift off the road with speed and steering, joins a road from the side at an angle (slowing for the merge), and **stops the vehicle** (cruise off, with a message) if it is leaving the road, can't get back, or loses the road at speed. Steering, a pedal or the handbrake always hand control straight back.
   **At junctions it goes straight on by default.** **Tap** the steering keys (a short tap on left or right, the assist keeps driving; hold the key longer than about 0.6 s and you are steering yourself, as before) or click the **left** or **right mouse button** (or number block 4 / 6) to signal (the vehicle's own indicator lights go on, and the game's own indicator keys count too): the assist then takes the next turn that way, planning the whole corner, and clears the signal once the turn is done (left, on; left again, off; the other side switches it; with the assist not driving, a tap still works the vehicle's own turn lights while cruise control is on, and a light that is on can always be put out). `roadFollowSignals` switches the mouse buttons off. If a tap on the left key signals right, `roadFollowTapFlip` swaps the sides.
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

**The road map debug tool:** `roadFollowMap [radius]` draws the roads round where you stand (see the console help).
