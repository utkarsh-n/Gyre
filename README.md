# Gyre

A holographic gyroscope in a soap bubble, for iPhone on iOS 27. The bubble lives in your phone, or in AR, in your room. The rotor inside obeys real rigid-body physics: turn the phone and the spinning axis holds its direction in space while the bubble turns around it.

The phone's sensors drive it:
- **Gyroscope and accelerometer:** your turning, and gravity's real direction.
- **Magnetometer:** a magnetised rotor precesses around the measured field.
- **Barometer:** can set the density of the bubble's air.
- **Microphone:** draws an oscilloscope and can modulate the environment.

The stack is SwiftUI and Liquid Glass for the interface, Metal for the hologram and the holo-metal gyroscope, ARKit for AR, Core Motion for the sensors, and Core Haptics plus a live audio synth for feedback. No network, no third-party code.

## Run

```bash
Tools/build.sh sim       # Debug build for the iPhone 17 Pro simulator
Tools/build.sh device    # Release build for a connected iPhone
```

`xcodebuild` hangs when it loads a project from this iCloud-synced folder, so the script mirrors the project to a local scratch directory and builds there (override with `GYRE_BUILD_DIR`). Opening `Gyre.xcodeproj` in Xcode 27 works too. After adding or removing source files, run `xcodegen generate`.

Install on the phone after a device build:

```bash
xcrun devicectl device install app --device <device-id> "$TMPDIR/GyreBuild/dd/Build/Products/Release-iphoneos/Gyre.app"
```

The Simulator has no motion sensors, so Gyre simulates a phone held upright and tilted back. Drag outside the bubble to tilt it.

Launch arguments for testing:

| Argument | Effect |
| --- | --- |
| `-simSway` | The simulated phone sways by itself. |
| `-fakeMic` | A synthetic room (a swelling chord plus a clap every 1.6 s) stands in for the microphone. |
| `-fakeAR` | Without world tracking, a synthetic camera and room stand in for ARKit. |
| `-startMic` | Turns the microphone on at launch. |
| `-startAR` | Starts AR at launch. |

## Playing with it

- **Swipe across the rotor** to spin it, like pulling a toy gyroscope's string. Torque is r × F, so dragging along the axis does nothing.
- **Tap the bubble** to poke the rotor. A fast rotor nods (nutation); a slow one rocks. The poke scales with the rotor's angular momentum.
- **Turn, tilt and shake the phone.** You feel the hum strengthen when you swing a fast rotor around: that is the torque a real gyroscope would push back with.
- **Experiments** (flask): Spinning top, Free gyroscope, Moon, Jupiter, Hanging gyro, Magnetic compass, Slow motion, Wind-down, Zero-g.
- **Layers** toggles the vectors (angular momentum **L**, torque **τ** at its tip, gravity **g**, field **B**), the axle-tip trail, the dust, sound, haptics and live air pressure.
- **Knobs** fold away so the bubble can fill the screen. Double-tap a knob to reset it; pause freezes time.
- **Object tab** (console): a shelf of glass tiles turns the spinning thing into something else. The physics is always the gyroscope's rotor; the object is a skin over it.
  - *Wireframe:* the original light-drawn hologram.
  - *Gyroscope:* holo-metal.
  - *Glass orb:* the gyroscope sealed in a thick glass ball fixed to its cage, so its scratches turn as it precesses and nods. The orb refracts the gyroscope with chromatic dispersion, mostly near the rim, and its abraded skin (frost, scuffs, broken scratch arcs) scatters the view. Knobs: **Frost**, **Dispersion**, **Refraction**.
  - *Top:* a machined titanium top in the style of the one in *Inception*, a single lathe-turned piece: domed stem, concave trumpet flare, thin disc, concave point. The point stretches to reach the pivot.
    - Finish: titanium's own reflectance (0.54/0.50/0.45), with no tint or anodising.
    - Brushing: grooves run around the axis, so highlights and reflections streak radially across the disc and lengthwise along the stem. Fine lathe tool-marks show up close.
  - *Planet:* a banded, ringed gas giant on a glowing axis. Its storm smears into a band at speed.
- **Magnetic field lines** (Layers, on by default) appear once Magnet is turned up.
  - They trace the field your magnetometer measures through the bubble and the space around it, and bend around the rotor's own dipole.
  - They brighten with the knob, crowd together as the field strengthens (line spacing follows field strength, so a real magnet visibly packs them), and pulse along the direction of B.
- **Layers → Gyroscope → Harmonic center:** glides the rotor's centre of mass to the bubble's centre and lets the pivot ride along instead. The physics doesn't change; it is how a free gyroscope would sit in zero-g.
- **AR** (toolbar):
  - The bubble floats 45 cm in front of the phone, so swinging the phone swings the gyroscope, including the lever arm's centripetal and tangential pull.
  - **Place** (or tap a surface) sets it on a table or wall, or leaves it in mid-air. Walk around it and pinch to resize; **Pick up** carries it again.
  - The metal reflects your actual room through ARKit's environment maps, and the bubble's rim lenses the camera image.
- **Sound page** (console tabs): turn on the mic and the bubble draws an oscilloscope.
  - **Scope:** a rotary switch for *Ring* (waveform around the horizon), *Trace* (triggered, with a graticule) or *XY* (delay embedding).
  - **Listen:** modulation depth.
  - **Drives:** a rotary switch for what sound pushes on. *Gravity* adds up to 2 g, *Air* thickens and stirs it, *Spin* pushes the rotor like wind on a pinwheel, *Kicks* turns claps and beats into nods, and *Film* makes the bubble shiver and ripple.
  - **Gain:** sensitivity.
  - The modulation follows loudness above the room's own background, so a steady hum, including the rotor's own, fades out.

| Knob | What it does |
| --- | --- |
| Motor | Speed the governor holds (0–12,000 rpm). Off lets the rotor coast, slow and topple. |
| Inertia | ×0.25–3 moment of inertia. With the motor off, angular momentum is conserved, so spin slows as inertia grows. |
| Gravity | −1 to 3 g, with detents at Zero-g, Moon, Mars, Earth and Jupiter. The direction is measured. |
| Balance | Rotor position on the axle, ±3.5 cm. Balanced = free gyro; above the pivot = top; below = hanging gyro. |
| Friction | Pivot and bearing friction, which couples the rotor to the phone and damps nutation. |
| Air | Air density: drag on spin and swing, and the medium the dust floats in. Vacuum at 0. |
| Magnet | The rotor's magnetic moment. It precesses around the measured field (Larmor). |
| Time | 0.05–2× simulation speed. Slow motion makes nutation loops visible. |

## How it works

**Physics** (`Gyre/Physics/GyroSim.swift`). A symmetric heavy top on a ball pivot fixed to the phone: a 60 g, 6 cm brass disc whose centre of mass sits up to 3.5 cm along its axle. State is the spin axis and the angular momentum in the world frame (Core Motion's, Z up), integrated with RK4. It takes enough substeps per frame to resolve the fastest motion present (nutation ≈ L₃/I₁, pendulum swing, magnetic oscillation, friction).

Torques:
- gravity plus the phone's own acceleration, acting on the offset centre of mass;
- μ × B from the calibrated magnetometer;
- a torque-limited governor motor;
- pivot friction relative to the phone's rotation;
- air drag relative to the bubble's air, which itself lags the phone.

The cage frame is parallel-transported so it turns with the axis but never spins.

`Tools/physcheck/run.sh` compiles the physics with a harness and checks it against theory:

| Check | Result |
| --- | --- |
| Steady precession | within 0.1% |
| Free gyro axis while the phone tumbles | no drift |
| Energy conservation | 2 × 10⁻⁵ over 20 s |
| Sleeping-top threshold | 421 rpm |
| Larmor rate | within 0.1% |
| Skater effect | 4,000 → 2,000 rpm at 2× inertia |
| Wind-down | falls after ~67 s |
| Cost | 0.02 ms per frame at 12,000 rpm |

**Bubble world** (`Gyre/Physics/BubbleWorld.swift`).
- **Dust:** 220 motes in the phone frame. They are nearly buoyant in air, so they settle like a snow globe over about 15 s. They fall freely in a vacuum, slosh with acceleration, and swirl backwards when you turn the phone because the air lags. The rotor's wake stirs them, and static friction lets them rest on the floor of the film.
- **Wobble:** a damped spring drives the bubble's jelly wobble.
- **Trail:** a world-frame trail of the axle tip.

**Rendering** (`Gyre/Render`). Each frame draws, into a half-float buffer:
1. a world-anchored sky with a horizon, a 15° grid and a north tick, so the phone reads as a window;
2. the bubble's far wall;
3. Liquid Glass-style lensing of the sky at the rim;
4. the hologram as glowing line segments;
5. the near wall.

The film colours are thin-film interference in a soap film that drains toward the measured gravity, swirls and sloshes. Its specular glints come from lights fixed in the room, so they slide as you tilt. Spokes fade into motion blur: three rim markers are drawn as arcs over the angle swept in that frame. Bloom runs at half and quarter resolution. The composite adds slight chromatic aberration and scanlines and soft-clips into the display's EDR headroom, so on an XDR screen the hologram glows brighter than white. Reduce Motion turns off the scan band, flicker, scanlines, ripples and wobble.

**Feedback** (`Gyre/Feedback`).
- **Haptics:** a looping continuous haptic whose intensity and sharpness follow spin. It pulses with nutation and strengthens with gyroscopic strain (|ω_phone × L|). Transients mark knob ticks, detents, string pulls and pokes, and a Geiger-style crackle sounds when Magnet is on and a magnet is near.
- **Sound:** synthesised live. A six-blade whine over the rotor fundamental, bearing rumble with friction, air whoosh with density, a wobble at nutation, panned with the rotor. It uses the ambient category, so the silent switch mutes it.

**Holo-metal** (`Render/GyroMeshes.swift`, `metalFragment`):
- **Meshes:** a turned rotor (rim, web, hub, bolts that vanish into the blur at speed), torus cage rings, the axle, knobs and a glowing pivot ball.
- **Shading:** GGX/Smith/Schlick metal with anisotropic circular brushing on the rotor and an anodised-oxide rainbow.
- **Reflections:** image-based, of the environment. At home it reflects a holographic studio (softboxes, a horizon glow, a magenta strip light) fixed in the room, so reflections slide as you tilt. In AR it reflects ARKit's `AREnvironmentProbeAnchor` cube maps of your room.
- **Glow:** the hologram's fresnel rim glow and scan band sweep over the metal.

**Objects** (`Render/HoloRenderer.swift`):
- **Top:** two lathe meshes from a Catmull–Rom-smoothed profile: the body and stem, and the point, which is stretched along the axis (normals use the inverse transpose).
  - Shading: anisotropic GGX with circumferential tangents.
  - Reflections: environment reflections smeared across the grooves.
  - Tool marks: procedural lathe rings that fade out before they would alias.
- **Planet:** procedural bands and a storm, with a two-sided ring whose Cassini division is cut out.
- **Glass orb:** needs what's inside it, so the scene pass splits in two. Everything inside the orb (gyroscope, far walls, the object's own glow lines) is drawn first. It is then copied into a mipmapped texture, which the orb's near face samples with per-channel refraction offsets for dispersion and abrasion-driven mip blur for frost. Lines outside the orb and the bubble's near wall follow. In AR the orb also refracts the camera image.

**Field lines** (`HoloSceneBuilder.fieldLines`): seeds on a hexagonal grid across the plane through the bubble perpendicular to the measured field, with spacing ∝ 1/√|B|. Each line is traced both ways with midpoint steps through B_measured plus a drawing-scale rotor dipole along the spin axis. Lines fade beyond about 1.1 bubble radii and near the viewer.

**AR** (`Sensors/ARController.swift`): ARKit world tracking feeds the same Metal pipeline. The captured YCbCr image is decoded under the scene, and ARKit's projection replaces the phone camera; depth direction is detected per frame. While the bubble is carried, its frame is the phone's, and the physics adds the lever arm. Once placed it is anchored and upright, and the physics frame is the room.

**Microphone** (`Sensors/MicListener.swift`):
- **Capture:** a 16k ring buffer that is constantly overwritten (nothing is kept), RMS, bass, and onset detection.
- **Scope:** triggered on rising zero crossings like a real oscilloscope, with three sweeps of phosphor persistence.
- **Audio session:** shared with the hum (`AudioRoute`): ambient until the mic listens, then play-and-record in measurement mode.

**Interface** (`Gyre/UI`). Liquid Glass throughout: interactive glass knobs in a `GlassEffectContainer`, a glass toolbar group whose menus grow out of it, a telemetry card that unfolds into live sensor readings, a glass readout naming the physics of whichever knob you're turning, and a Liquid Glass sheet. Knobs are VoiceOver-adjustable.

## Verified, and not yet

- **Verified:** the physics harness; Simulator runs of every control path (knobs, detents, readout, string pull, poke and nutation, fold and unfold, experiments, layers, info sheet); a Release build installed and launched on the iPhone 15 Pro Max (iOS 27.2), where it renders and runs on live sensors.
- **New in v2, verified in the Simulator:**
  - holo-metal rendering;
  - harmonic center;
  - the Sound page with the synthetic mic: all three scope styles and Gravity modulation;
  - the AR pipeline with the synthetic camera: carry, place, banner, camera compositing.
- **Verified on the iPhone:** holo-metal rendering on live sensors (phone mode).
- **Needs hands-on testing (v2):** real ARKit (permission, tracking, surface placement, environment-probe reflections, coaching), and the real microphone (permission, levels, onsets).
- **Not yet checked by hand:**
  - how the haptics feel;
  - how the hum sounds (the Simulator has neither);
  - the magnet behaviour with a real magnet;
  - the barometer permission prompt and live pressure;
  - EDR brightness on the device.
