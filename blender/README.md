# Blender → DaVinci Resolve: scripted titles and content

Blender is the studio's motion-graphics forge: 3D logo stings, animated titles,
and generated content that would be painful inside Fusion — all rendered
**headless from the CLI**, so the same agent that edits the timeline can also
manufacture the media it inserts.

## Why Blender alongside Resolve

- **Real 3D** (extruded, beveled, lit, spinning) with physics/grease-pencil/geometry
  nodes — Fusion's 3D is compositor-grade; Blender is content-grade.
- **Scriptable end to end**: `Blender --background --factory-startup --python x.py`
  with no GUI — the agent writes the scene file, renders, then imports the result
  into Resolve over MCP. One conversation produces both the sting and its placement.
- **Transparent EXR round-trip**: `film_transparent=True` + OpenEXR RGBA gives
  Resolve a true alpha channel — the sting composites over footage with the whole
  Fusion grade stack available downstream.
- Apple Silicon GPU works: Cycles enumerates the Metal device (verified:
  `Apple M5 Ultra (GPU - 64 cores)`), Workbench/EEVEE/Cycles all available.

## The pipeline (all verified on Blender 5.2.3 LTS + Resolve 21.2)

1. **Render transparent EXR sequence** — see `exr_title_demo.py` (runs clean end to
   end: 48/48 EXRs). Timing reality: 48 f @ 1080p 32spp ≈ 98 s; UHD 60 f ≈ 426 s;
   a 90 f UHD 3D logo sting ≈ 650 s. Titles are a lunch-break render, not a live
   interaction. Preview framing at 8 spp before committing to a final.
2. **Import into Resolve as one sequence clip** — pass **every frame path** in one
   `media_pool.safe_import_media` call; Resolve collapses it to a single
   `NAME_[0001-0048].exr` clip. Passing one path silently imports a 1-frame still.
3. **Fix the alpha** — Resolve defaults EXR to Premultiplied → fringing. Set
   `MediaPoolItem.SetClipProperty("Alpha mode", "Straight")` (Blender's
   film_transparent EXR is straight alpha).
4. **Place it** — `append_to_timeline` with `clip_infos`
   (`start_frame`/`end_frame` are **0-based, end-exclusive**: end=60 → 60 frames),
   or for insertion at the head: `MoveItems` ripple +90 then positioned append.
5. **Proof-render to verify** — mark the title region, render a short ProRes/H264
   proof, `render.verify_output`, sample frames. Never trust grabs for comp output;
   the render is the truth.

## Blender 5.x script gotchas (all paid for in tuition)

| Gotcha | Fix |
|---|---|
| `--factory-startup` still loads the default cube/camera/light | scene-clear loop at script top, always |
| `image_settings.file_format` has no `FFMPEG` enum in 5.2 | render PNG/EXR sequences, encode with ffmpeg |
| `Action.fcurves` gone (slotted actions: layers/strips/channelbag) | key every frame, or use the strip API |
| `render()` throws "Cannot render, no camera" in background | assign `scene.camera` explicitly |
| Light `data.color` wants RGB 3-tuple | don't pass RGBA (Principled Base Color takes 4) |
| Euler-chain confusion for spins | parent to an empty, key `rotation_euler.z` (world-Z spin) |
| Text renders as a row of dice, cropped at both frame edges | a FONT curve lies flat in XY facing +Z — stand it up with `rotation_euler=(pi/2,0,0)`, then frame the camera from the measured `bound_box` + `cam_data.angle`, not by guessing distance |
| Metal materials go black with `film_transparent` | the transparent world reflects nothing — keep `Metallic` low (≈0.1) and light it directly |
| "Perspective roll" at yaw extremes looks like a bug | it isn't — verify with `world_to_camera_view` corner projection before debugging |
| Solidify on alpha-derived heightfields self-intersects | build constant-z sheets (silhouette slab + raised marks slab) instead |

## Scene-content ideas that worked in production

- **3D logo sting**: logo PNG → alpha-masked two-sheet construction (badge
  silhouette solidified for depth + raised white-marks sheet), bevel modifier for
  extrusion read, symmetric rim lights, ease-in spin with a slow drift so it never
  dead-stops. Composited over stage footage with the camera pulled to ~63%
  object-height so the background breathes around it.
- **Titles**: extruded text + dolly move, 1080p proxies for review, UHD finals.
- **Generated media**: 1M-vertex meshes build in <1 s; exports verified for glTF/FBX/USD/OBJ/ABC —
  useful for reference geometry and set previews brought into Resolve as media.
