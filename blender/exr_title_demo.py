# exr_title_demo.py — headless Blender → transparent EXR title sequence
#
# Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
#         --python exr_title_demo.py
#
# Verified on Blender 5.2.3 LTS / Apple M5 Ultra (Cycles METAL, 64-core GPU):
#   48 frames 1920x1080, 32 spp + denoise, film_transparent → 98 s total.
#   UHD (3840x2160) 60 f at 32 spp ≈ 426 s — render titles at project res
#   overnight, or proxies at 1080p for review.
#
# Blender 5.x gotchas baked into this script:
#   * --factory-startup still loads the default cube/camera/light — always clear the scene.
#   * image_settings.file_format has NO 'FFMPEG' enum in 5.2 — render PNG/EXR sequences
#     and encode with ffmpeg afterwards if you need video.
#   * scene.camera must be assigned explicitly in background mode or render() throws.
#   * Light data.color wants a 3-tuple RGB (Principled Base Color takes 4).
#   * Rotation sanity: parenting to an empty and keying the empty's rotation_euler.z
#     gives an unambiguous world-Z spin (raw euler chains fooled two debug rounds).
#   * A FONT curve lies FLAT in the XY plane facing +Z. A near-level camera then renders
#     only the extrusion edge (looks like a row of dice). Stand it up with
#     rotation_euler=(pi/2, 0, 0) — the parent empty's Z keyframes still spin it turntable-style.
#   * Don't guess camera distance: measure the mesh bounding box, derive the fit from
#     cam_data.angle. That one line replaced three rounds of cropped-title re-renders.
#
# Output: <script dir>/render/title_[0001-0048].exr  (RGBA 32-bit, straight alpha)

import bpy, os, math
from mathutils import Vector

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "render")
RES_X, RES_Y, FPS, FRAMES, SPP = 1920, 1080, 30, 48, 32

# ── 1. Clear the factory scene (mandatory) ─────────────────────────────────
for ob in list(bpy.data.objects):
    bpy.data.objects.remove(ob, do_unlink=True)

scene = bpy.context.scene

# ── 2. Cycles on Metal with transparent film ───────────────────────────────
scene.render.engine = "CYCLES"
prefs = bpy.context.preferences.addons.get("cycles")
if prefs:
    cp = prefs.preferences
    try:
        cp.compute_device_type = "METAL"          # Apple Silicon GPU
        cp.get_devices()
        for d in cp.devices:
            d.use = True
        scene.cycles.device = "GPU"
    except Exception as e:
        print("Metal setup failed, falling back to CPU:", e)
scene.cycles.samples = SPP
scene.cycles.use_denoising = True
scene.cycles.use_adaptive_sampling = True
scene.render.film_transparent = True              # THE alpha switch
scene.view_settings.view_transform = "Standard"   # predictable EXR values (on view_settings, not scene)

# ── 3. Output: OpenEXR RGBA 32-bit sequence ────────────────────────────────
os.makedirs(OUT_DIR, exist_ok=True)
scene.render.image_settings.file_format = "OPEN_EXR"
scene.render.image_settings.color_depth = "32"
scene.render.image_settings.exr_codec = "ZIP"
scene.render.filepath = os.path.join(OUT_DIR, "title_")
scene.frame_start, scene.frame_end, scene.render.fps = 1, FRAMES, FPS

# ── 4. Build the title ─────────────────────────────────────────────────────
text = bpy.data.curves.new("title", type="FONT")
text.body = "RESOLVE + AI"
text.align_x = "CENTER"; text.align_y = "CENTER"
text.size = 1.0; text.extrude = 0.12; text.bevel_depth = 0.015; text.bevel_resolution = 2
title = bpy.data.objects.new("Title", text)
scene.collection.objects.link(title)
title.rotation_euler = (math.pi / 2, 0, 0)      # stand the flat XY curve upright, facing -Y

mat = bpy.data.materials.new("TitleMat"); mat.use_nodes = True
bsdf = mat.node_tree.nodes["Principled BSDF"]
bsdf.inputs["Base Color"].default_value = (0.95, 0.95, 0.95, 1)
bsdf.inputs["Metallic"].default_value = 0.1     # keep it dielectric: with film_transparent
bsdf.inputs["Roughness"].default_value = 0.4    # the world is BLACK, metal would reflect nothing
title.data.materials.append(mat)

# Spin via a parent empty — key the empty's world-Z rotation, not the mesh's eulers
rig = bpy.data.objects.new("Rotator", None)
scene.collection.objects.link(rig)
title.parent = rig
rig.rotation_euler = (0, 0, -0.96)               # ≈ -55° ease-in start
rig.keyframe_insert("rotation_euler", frame=1)
rig.rotation_euler = (0, 0, 0.24)
rig.keyframe_insert("rotation_euler", frame=FRAMES)
# 5.2 note: Action.fcurves is gone (actions are slotted: layers/strips/channelbag).
# For scripted easing, either key every frame, or set interpolation through the strip API.

# ── 5. Lights + camera ─────────────────────────────────────────────────────
def add_light(name, loc, energy):
    ld = bpy.data.lights.new(name, type="AREA")
    ld.energy = energy
    ld.color = (1.0, 0.97, 0.92)                 # 3-tuple, NOT RGBA (5.x gotcha)
    lo = bpy.data.objects.new(name, ld)
    lo.location = loc
    scene.collection.objects.link(lo)
    return lo

add_light("KeyL",  (-2.6, -3.4, 2.4), 500)       # symmetric pair on the camera side
add_light("KeyR",  ( 2.6, -3.4, 2.4), 500)
add_light("Rim",   ( 0.0,  2.8, 1.4), 250)       # behind the title: catches the extruded edges

# ── 6. Frame the camera FROM THE MEASUREMENT ───────────────────────────────
# bound_box is local: X = string width, Y = glyph height, Z = extrude depth.
bb = [Vector(c) for c in bpy.context.evaluated_depsgraph_get().objects["Title"].bound_box]
half_w = (max(v.x for v in bb) - min(v.x for v in bb)) / 2
half_h = (max(v.y for v in bb) - min(v.y for v in bb)) / 2
half_d = (max(v.z for v in bb) - min(v.z for v in bb)) / 2
half_sweep = math.hypot(half_w, half_d)          # worst-case width while it spins about world Z

cam_data = bpy.data.cameras.new("Cam")           # default 50 mm / 36 mm sensor
tan_h = math.tan(cam_data.angle / 2)
tan_v = tan_h * cam_data.sensor_height / cam_data.sensor_width
FIT = 1.25                                       # 25% breathing room around the string
DIST = max(half_sweep / tan_h, half_h / tan_v) * FIT
print(f"fit: half_w={half_w:.2f} half_h={half_h:.2f} → camera at y=-{DIST:.2f}")

cam = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam                               # mandatory in background mode

def place(dist, frame):
    """Dolly along the view axis, always aimed at the title centre."""
    cam.location = (0, -dist, half_h)
    aim = Vector((0, 0, half_h)) - cam.location
    cam.rotation_euler = aim.to_track_quat("-Z", "Y").to_euler()
    cam.keyframe_insert("location", frame=frame)
    cam.keyframe_insert("rotation_euler", frame=frame)

place(DIST * 1.07, 1)                            # slow dolly in sells the parallax
place(DIST * 0.99, FRAMES)

# ── 7. Render the sequence ─────────────────────────────────────────────────
bpy.ops.render.render(animation=True)
print("Done:", OUT_DIR)
