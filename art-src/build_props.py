"""Rebuilds twenty-two of the furniture models under assets/props/furniture/ for game-murder-mystery.

Run:  blender -b -P art-src/build_props.py -- [name ...] [--out DIR]
Bases: art-src/base/<name>.glb, Kenney's Furniture Kit (CC0, see assets/props/furniture/LICENSE-kenney-furniture-kit.txt).
Changes, for every model: every sharp edge is bevelled and the kit's pale pine, coral and silver palette is replaced
by this game's own (stained walnut, burgundy velvet, brass, gunmetal, kraft board). Then each gets parts of its own:
books on the bookcase's shelves, a leather blotter on the desk, a slate top and brass rail on the kitchen island,
a soil disc and rim on the plant pot, taped and labelled cardboard, brass knobs and a book stack on the bedside
table, buttons on the chair, armrests on the desk chair, a pillow on the lounge chair, ribs on the bin.
Node names, the node tree, each model's origin and its bounding box are kept: after the parts are added the
whole model is refitted to the base's box (a fraction of a percent), because pieces.json (the collision) and
catalogue.json (the size) are measured from the box. The material called "plant" keeps its name: the loader's
recolour table finds it by that name.
Blender axes: the importer turns glTF (x, y, z) into (x, -z, y), so a model's front (glTF +Z) is Blender -Y.
"""
import bpy, bmesh, sys, os, math, random
from mathutils import Vector, Matrix

here = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
outdir = os.path.join(here, "..", "assets", "props", "furniture")
if "--out" in argv:
    i = argv.index("--out")
    outdir = argv[i + 1]
    del argv[i:i + 2]
names = argv

PAL = {}

def mat(name, rgb, metal=0.0, rough=0.6):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (*rgb, 1)
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    return m

def palette():
    PAL.clear()
    PAL["walnut"] = mat("walnut", (0.12, 0.055, 0.03), 0.0, 0.5)
    PAL["walnutDark"] = mat("walnutDark", (0.06, 0.028, 0.016), 0.0, 0.55)
    PAL["velvet"] = mat("velvet", (0.2, 0.018, 0.035), 0.0, 0.85)
    PAL["brass"] = mat("brass", (0.55, 0.34, 0.07), 0.6, 0.4)
    PAL["steel"] = mat("steel", (0.32, 0.34, 0.37), 0.5, 0.4)
    PAL["gunmetal"] = mat("gunmetal", (0.1, 0.11, 0.125), 0.5, 0.45)
    PAL["gunmetalDark"] = mat("gunmetalDark", (0.04, 0.045, 0.05), 0.4, 0.5)
    PAL["leather"] = mat("leather", (0.015, 0.1, 0.1), 0.0, 0.55)
    PAL["kraft"] = mat("kraft", (0.4, 0.24, 0.1), 0.0, 0.8)
    PAL["kraftDark"] = mat("kraftDark", (0.3, 0.17, 0.07), 0.0, 0.8)
    PAL["tape"] = mat("tape", (0.62, 0.45, 0.22), 0.0, 0.35)
    PAL["paper"] = mat("paper", (0.8, 0.78, 0.7), 0.0, 0.9)
    PAL["red"] = mat("red", (0.5, 0.03, 0.03), 0.0, 0.7)
    PAL["slate"] = mat("slate", (0.035, 0.04, 0.045), 0.1, 0.3)
    PAL["terracotta"] = mat("terracotta", (0.42, 0.14, 0.07), 0.0, 0.8)
    PAL["soil"] = mat("soil", (0.02, 0.012, 0.008), 0.0, 1.0)
    PAL["plant"] = mat("plant", (0.07, 0.3, 0.09), 0.0, 0.6)
    PAL["porcelain"] = mat("porcelain", (0.62, 0.6, 0.54), 0.0, 0.18)
    PAL["linen"] = mat("linen", (0.5, 0.46, 0.38), 0.0, 0.9)
    PAL["shade"] = mat("shade", (0.55, 0.38, 0.17), 0.0, 0.8)
    PAL["screen"] = mat("screen", (0.008, 0.01, 0.014), 0.2, 0.08)
    PAL["blotter"] = mat("blotter", (0.02, 0.17, 0.07), 0.0, 0.7)

# Kit material name -> ours.
SWAP = {"wood": "walnut", "woodDark": "walnutDark", "metal": "brass", "metalMedium": "gunmetal",
        "metalDark": "gunmetalDark", "carpet": "velvet", "plant": "plant", "_defaultMat": "walnut",
        "carpetWhite": "porcelain", "metalLight": "steel", "lamp": "shade"}

def meshes():
    return [o for o in bpy.data.objects if o.type == "MESH"]

def world_box(objs):
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    return Vector(min(p[i] for p in pts) for i in range(3)), Vector(max(p[i] for p in pts) for i in range(3))

OVERRIDES = {"bedSingle": {"carpetWhite": "linen", "carpet": "velvet"}, "stoolBar": {"carpet": "leather"},
             "rugDoormat": {"wood": "kraftDark"}, "toilet": {"_defaultMat": "walnutDark"},
             "bathroomSink": {"_defaultMat": "porcelain"}, "televisionModern": {"metal": "gunmetal", "metalDark": "screen"},
             "lampRoundTable": {"metal": "brass"}, "showerRound": {"_defaultMat": "porcelain", "metalDark": "steel"},
"cardboardBoxClosed": {"wood": "kraft", "woodDark": "kraftDark"}, "trashcan": {"metal": "steel", "metalDark": "gunmetalDark"}}

def reskin(o, overrides=None):
    overrides = overrides or {}
    for i, s in enumerate(o.material_slots):
        k = s.material.name.split(".")[0]
        if k == "glass":
            continue  # the shower's glass keeps its own transparent material
        o.material_slots[i].material = PAL[overrides.get(k, SWAP.get(k, "walnut"))]

def bevel(o, width=0.004):
    sc = sum(o.matrix_world.to_scale()) / 3
    bm = bmesh.new()
    bm.from_mesh(o.data)
    edges = [e for e in bm.edges if len(e.link_faces) == 2 and e.calc_face_angle(0) > math.radians(35)]
    bmesh.ops.bevel(bm, geom=edges, offset=width / sc, segments=2, affect="EDGES")
    bm.to_mesh(o.data)
    bm.free()
    o.data.update()

def slot(o, key):
    m = PAL[key]
    for i, s in enumerate(o.material_slots):
        if s.material == m:
            return i
    o.data.materials.append(m)
    return len(o.material_slots) - 1

def add_box(host, lo, hi, key, rot=0.0):
    """A box from world-space corner lo to hi (rotated rot rad about Z through its centre), joined into host."""
    lo, hi = Vector(lo), Vector(hi)
    c = (lo + hi) / 2
    bpy.ops.mesh.primitive_cube_add(size=1, location=c, rotation=(0, 0, rot))
    p = bpy.context.active_object
    p.scale = (hi - lo)
    bpy.ops.object.transform_apply(scale=True)
    join(host, p, key)

def add_cyl(host, c, r, h, key, axis="Z", verts=16, r2=None):
    rot = {"Z": (0, 0, 0), "X": (0, math.pi / 2, 0), "Y": (math.pi / 2, 0, 0)}[axis]
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r, radius2=r if r2 is None else r2, depth=h, location=c, rotation=rot)
    join(host, bpy.context.active_object, key)

def add_sphere(host, c, r, key, sq=1.0):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=6, radius=r, location=c)
    p = bpy.context.active_object
    p.scale.z = sq
    bpy.ops.object.transform_apply(scale=True)
    join(host, p, key)

def add_torus(host, c, R, r, key):
    bpy.ops.mesh.primitive_torus_add(major_radius=R, minor_radius=r, major_segments=20, minor_segments=6, location=c)
    join(host, bpy.context.active_object, key)

def join(host, p, key):
    for f in p.data.polygons:
        f.use_smooth = False
    p.data.materials.clear()
    p.data.materials.append(PAL[key])
    # Match the host's slot for this material so joining does not add a duplicate.
    idx = slot(host, key)
    bpy.ops.object.select_all(action="DESELECT")
    p.select_set(True)
    host.select_set(True)
    bpy.context.view_layer.objects.active = host
    bpy.ops.object.join()
    # The joined faces carry the slot index of the parts' own single material (0); remap by material.
    remap_new_faces(host)

def remap_new_faces(host):
    # After a join Blender appends the part's material to the host's slots when it is not there yet and points the
    # part's faces at it, so nothing is needed except dropping duplicate slots, which export merges anyway.
    pass

def top_levels(o, min_area=0.002):
    """z levels (world) of upward faces of o with their areas: shelves and seats."""
    bm = bmesh.new()
    bm.from_mesh(o.data)
    out = {}
    for f in bm.faces:
        n = (o.matrix_world.to_3x3() @ f.normal).normalized()
        if n.z > 0.95:
            z = round((o.matrix_world @ f.calc_center_median()).z, 3)
            out[z] = out.get(z, 0) + f.calc_area()
    bm.free()
    return sorted((z, a) for z, a in out.items() if a > min_area)

def books(host, lo, hi, z, gap, seed):
    rnd = random.Random(seed)
    cols = ["red", "leather", "velvet", "kraft", "paper", "walnutDark", "blotter", "gunmetal"]
    x = lo.x
    while x < hi.x - 0.02:
        w = rnd.uniform(0.012, 0.026)
        h = min(gap * rnd.uniform(0.62, 0.92), gap - 0.012)
        d = (hi.y - lo.y) * rnd.uniform(0.7, 0.9)
        if rnd.random() < 0.12 and x + 0.07 < hi.x:
            add_box(host, (x, lo.y, z), (x + 0.07, lo.y + d, z + 0.014), cols[rnd.randrange(len(cols))])
            x += 0.075
            continue
        add_box(host, (x, lo.y, z), (x + w, lo.y + d, z + h), cols[rnd.randrange(len(cols))])
        x += w + 0.001
        if rnd.random() < 0.1:
            x += rnd.uniform(0.03, 0.06)

def knob(host, c):
    add_sphere(host, c, 0.011, "brass", 0.8)

# ---- per-model parts; each gets the model's meshes by name ------------------------------------------------

def do_pottedPlant(by):
    pot, plant = by["pottedPlant(Clone)"], by["plant"]
    lo, hi = world_box([pot])
    c = (lo + hi) / 2
    top = hi.z
    add_cyl(pot, (c.x, c.y, top - 0.012), 0.092, 0.012, "soil")
    add_torus(pot, (c.x, c.y, top - 0.004), 0.092, 0.006, "terracotta")
    add_cyl(pot, (c.x, c.y, lo.z + 0.018), 0.075, 0.012, "walnutDark")
    plo, phi = world_box([plant])
    for k in range(4):
        a = k * math.pi / 2 + 0.5
        add_cyl(plant, (c.x + math.cos(a) * 0.05, c.y + math.sin(a) * 0.05, top + 0.1), 0.012, 0.2, "plant", r2=0.0, verts=6)

def do_chairCushion(by):
    o = by["chairCushion(Clone)"]
    lo, hi = world_box([o])
    lv = [z for z, a in top_levels(o) if 0.1 < z < hi.z - 0.05]
    seat = max(lv, key=lambda z: z) if lv else 0.23
    c = (lo + hi) / 2
    add_box(o, (lo.x + 0.01, hi.y - 0.012, hi.z - 0.012), (hi.x - 0.01, hi.y, hi.z), "brass")

def do_kitchenBar(by):
    o = by["kitchenBar(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x - 0.002, lo.y - 0.003, hi.z - 0.014), (hi.x + 0.002, hi.y + 0.002, hi.z + 0.003), "slate")
    add_cyl(o, ((lo.x + hi.x) / 2, lo.y, lo.z + 0.05), 0.006, (hi.x - lo.x) * 0.86, "brass", axis="X")
    for x in (lo.x + 0.04, hi.x - 0.04):
        add_cyl(o, (x, lo.y, lo.z + 0.05), 0.009, 0.01, "brass", axis="Y")

def do_desk(by):
    o, drawer = by["desk(Clone)"], by["drawer"]
    lo, hi = world_box([o])
    add_box(o, (lo.x + 0.12, lo.y + 0.07, hi.z - 0.002), (lo.x + 0.45, hi.y - 0.07, hi.z + 0.004), "blotter")
    add_box(o, (lo.x + 0.14, lo.y + 0.09, hi.z + 0.004), (lo.x + 0.43, lo.y + 0.095, hi.z + 0.006), "tape")
    dlo, dhi = world_box([drawer])
    c = (dlo + dhi) / 2
    add_cyl(drawer, (c.x, dlo.y, c.z), 0.008, 0.012, "brass", axis="Y")

def do_chairDesk(by):
    base, chair = by["chairDesk(Clone)"], by["chair"]
    lo, hi = world_box([chair])
    lv = [z for z, a in top_levels(chair) if 0.15 < z < hi.z - 0.05]
    seat = min(lv) if lv else lo.z + 0.2
    for x in (lo.x + 0.012, hi.x - 0.012):
        add_box(chair, (x - 0.008, lo.y + 0.045, seat + 0.012), (x + 0.008, hi.y - 0.045, seat + 0.026), "gunmetal")
        add_box(chair, (x - 0.006, hi.y - 0.075, seat), (x + 0.006, hi.y - 0.063, seat + 0.026), "gunmetal")
        add_box(chair, (x - 0.006, lo.y + 0.06, seat), (x + 0.006, lo.y + 0.072, seat + 0.026), "gunmetal")
    c = (lo + hi) / 2
    add_sphere(chair, (c.x, hi.y - 0.004, hi.z - 0.05), 0.009, "brass", 0.5)

def do_bookcaseOpen(by):
    o = by["bookcaseOpen(Clone)"]
    lo, hi = world_box([o])
    lv = [z for z, a in top_levels(o)]
    lv = [z for z in lv if z < hi.z - 0.05]
    lv.sort()
    for i, z in enumerate(lv):
        nxt = next((n for n in lv if n > z + 0.05), None)
        # The next shelf's top is a plank's thickness above its underside; the gap is to the underside.
        under = (nxt - 0.02) if nxt else hi.z - 0.02
        gap = under - z
        if gap > 0.06:
            books(o, Vector((lo.x + 0.022, lo.y + 0.03, 0)), Vector((hi.x - 0.022, hi.y - 0.02, 0)), z, gap, 7 + i)

def do_loungeChair(by):
    o = by["loungeChair(Clone)"]
    lo, hi = world_box([o])
    lv = [(a, z) for z, a in top_levels(o) if 0.08 < z < hi.z * 0.8]
    seat = max(lv)[1] if lv else 0.2
    c = (lo + hi) / 2
    add_box(o, (c.x - 0.09, c.y - 0.05, seat), (c.x + 0.09, c.y + 0.07, seat + 0.07), "kraft", rot=0.35)
    add_sphere(o, (c.x - 0.02, c.y + 0.01, seat + 0.072), 0.008, "brass", 0.5)

def do_cardboardBoxClosed(by):
    o = by["cardboardBoxClosed(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_box(o, (c.x - 0.016, lo.y - 0.001, hi.z - 0.002), (c.x + 0.016, hi.y + 0.001, hi.z + 0.002), "tape")
    add_box(o, (c.x - 0.016, lo.y - 0.001, lo.z + 0.02), (c.x + 0.016, lo.y + 0.001, hi.z), "tape")
    add_box(o, (lo.x + 0.03, lo.y - 0.002, hi.z * 0.35), (lo.x + 0.085, lo.y, hi.z * 0.62), "paper")
    add_box(o, (hi.x - 0.07, lo.y - 0.002, hi.z * 0.25), (hi.x - 0.03, lo.y, hi.z * 0.32), "red")

def do_cabinetBedDrawerTable(by):
    o, drawer = by["cabinetBedDrawerTable(Clone)"], by["drawer"]
    lo, hi = world_box([o])
    dlo, dhi = world_box([drawer])
    c = (dlo + dhi) / 2
    knob(drawer, (c.x, dlo.y, c.z))
    add_box(o, (lo.x + 0.04, lo.y + 0.05, hi.z - 0.002), (lo.x + 0.15, lo.y + 0.15, hi.z + 0.008), "red", rot=0.2)
    add_box(o, (lo.x + 0.05, lo.y + 0.06, hi.z + 0.008), (lo.x + 0.14, lo.y + 0.14, hi.z + 0.013), "paper", rot=0.2)
    add_cyl(o, (hi.x - 0.07, hi.y - 0.07, hi.z), 0.032, 0.012, "brass")

def do_trashcan(by):
    o = by["trashcan(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    r = min(hi.x - lo.x, hi.y - lo.y) / 2 - 0.006
    add_torus(o, (c.x, c.y, hi.z - 0.006), r, 0.007, "brass")
    for f in (0.3, 0.62):
        add_torus(o, (c.x, c.y, lo.z + (hi.z - lo.z) * f), r * 0.96, 0.005, "gunmetal")
    add_cyl(o, (c.x, c.y, lo.z + 0.006), r * 0.9, 0.012, "gunmetal")

def do_rugDoormat(by):
    o = by["rugDoormat(Clone)"]
    lo, hi = world_box([o])
    z = hi.z
    m = 0.022
    for y in (lo.y + m, hi.y - m):
        add_box(o, (lo.x + m, y - 0.006, z - 0.002), (hi.x - m, y + 0.006, z + 0.0004), "red")
    for x in (lo.x + m, hi.x - m):
        add_box(o, (x - 0.006, lo.y + m, z - 0.002), (x + 0.006, hi.y - m, z + 0.0004), "red")
    for i in range(7):
        x = lo.x + 0.08 + i * (hi.x - lo.x - 0.16) / 6
        add_box(o, (x - 0.004, lo.y + 0.05, z - 0.002), (x + 0.004, hi.y - 0.05, z + 0.0004), "walnutDark")

def do_bedSingle(by):
    o, cover, pillow = by["bedSingle(Clone)"], by["cover"], by["pillow"]
    lo, hi = world_box([o])
    clo, chi = world_box([cover])
    plo, phi = world_box([pillow])
    # A brass trim band across the blanket and a folded-back linen edge at the pillow end.
    add_box(cover, (clo.x - 0.002, clo.y + 0.30, chi.z - 0.004), (chi.x + 0.002, clo.y + 0.32, chi.z + 0.002), "brass")
    add_box(cover, (clo.x - 0.002, chi.y - 0.09, chi.z - 0.004), (chi.x + 0.002, chi.y - 0.0, chi.z + 0.003), "linen")
    for x in (lo.x + 0.012, hi.x - 0.012):
        add_sphere(o, (x, hi.y - 0.012, hi.z - 0.012), 0.012, "brass")
    add_box(pillow, (plo.x + 0.03, plo.y + 0.02, phi.z - 0.003), (phi.x - 0.03, phi.y - 0.02, phi.z + 0.0), "paper")

def do_bookcaseClosed(by):
    o = by["bookcaseClosed(Clone)"]
    lo, hi = world_box([o])
    lv = sorted(z for z, a in top_levels(o) if z < hi.z - 0.05)
    for i, z in enumerate(lv):
        nxt = next((n for n in lv if n > z + 0.05), None)
        under = (nxt - 0.02) if nxt else hi.z - 0.02
        gap = under - z
        if gap > 0.06:
            books(o, Vector((lo.x + 0.03, lo.y + 0.04, 0)), Vector((hi.x - 0.03, hi.y - 0.03, 0)), z, gap, 21 + i)
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.03), "walnutDark")
    add_box(o, (lo.x - 0.0, lo.y - 0.004, hi.z - 0.018), (hi.x, hi.y, hi.z), "brass")

def do_stoolBar(by):
    o = by["stoolBar(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    for z in (lo.z + 0.12,):
        pass
    add_torus(o, (c.x, c.y, hi.z - 0.03), 0.095, 0.006, "brass")
    add_cyl(o, (c.x, c.y, hi.z - 0.003), 0.03, 0.004, "brass", verts=12)
    for x in (0.076, 0.189):
        for y in (0.061, 0.169):
            add_cyl(o, (x, y, lo.z + 0.004), 0.016, 0.008, "gunmetalDark", verts=8)

def do_lampRoundTable(by):
    o = by["lampRoundTable(Clone)"]
    lo, hi = world_box([o])
    c = Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0))
    c.x, c.y = 0.06, 0.06
    add_cyl(o, (c.x, c.y, lo.z + 0.012), 0.032, 0.01, "brass", verts=12)
    add_sphere(o, (c.x, c.y, lo.z + 0.09), 0.016, "brass", 1.0)
    add_torus(o, (c.x, c.y, hi.z - 0.003), 0.052, 0.004, "brass")
    add_torus(o, (c.x, c.y, hi.z * 0.55), 0.068, 0.004, "brass")

def do_toilet(by):
    o, cover = by["toilet(Clone)"], by["cover"]
    lo, hi = world_box([o])
    clo, chi = world_box([cover])
    c = (lo.x + hi.x) / 2
    add_cyl(o, (c, hi.y - 0.05, hi.z - 0.002), 0.016, 0.012, "steel", verts=10)
    for x in (c - 0.07, c + 0.07):
        add_cyl(cover, (x, clo.y + 0.03, chi.z + 0.003), 0.008, 0.008, "steel", verts=8)

def do_bathroomSink(by):
    o = by["bathroomSink(Clone)"]
    lo, hi = world_box([o])
    c = (lo.x + hi.x) / 2
    for x in (c - 0.07, c + 0.07):
        add_cyl(o, (x, 0.05, 0.112), 0.012, 0.014, "steel", verts=10)

def do_cabinetTelevisionDoors(by):
    o, dl, dr = by["cabinetTelevisionDoors(Clone)"], by["doorLeft"], by["doorRight"]
    lo, hi = world_box([o])
    for d, side in ((dl, 1), (dr, -1)):
        dlo, dhi = world_box([d])
        x = dhi.x - 0.03 if side == 1 else dlo.x + 0.03
        add_cyl(d, (x, dlo.y, (dlo.z + dhi.z) / 2), 0.008, 0.01, "brass", axis="Y", verts=10)
    add_box(o, (lo.x, lo.y, hi.z - 0.012), (hi.x, hi.y, hi.z), "walnutDark")
    add_box(o, (lo.x + 0.05, hi.y - 0.002, lo.z + 0.1), (hi.x - 0.05, hi.y, lo.z + 0.103), "brass")

def do_televisionModern(by):
    o = by["televisionModern(Clone)"]
    lo, hi = world_box([o])
    c = (lo.x + hi.x) / 2
    add_box(o, (lo.x + 0.012, lo.y - 0.0005, lo.z + 0.085), (hi.x - 0.012, lo.y + 0.004, hi.z - 0.012), "screen")
    add_box(o, (c + 0.25, lo.y - 0.0005, lo.z + 0.074), (c + 0.262, lo.y + 0.003, lo.z + 0.082), "red")

def do_table(by):
    o = by["table(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_box(o, (lo.x, lo.y, hi.z - 0.012), (hi.x, hi.y, hi.z), "walnutDark")
    add_box(o, (lo.x + 0.02, lo.y + 0.02, hi.z - 0.003), (hi.x - 0.02, hi.y - 0.02, hi.z + 0.0), "walnut")
    for x in (lo.x + 0.02, hi.x - 0.02):
        for y in (lo.y + 0.02, hi.y - 0.02):
            add_cyl(o, (x, y, lo.z + 0.004), 0.012, 0.008, "brass", verts=8)

def do_showerRound(by):
    o, fa = by["showerRound(Clone)"], by["faucet"]
    lo, hi = world_box([o])
    flo, fhi = world_box([fa])
    # A rose on the faucet and a brass drain on the tray.
    add_cyl(o, (lo.x + 0.28, lo.y + 0.28, lo.z + 0.065), 0.03, 0.008, "steel", verts=12)
    add_cyl(fa, ((flo.x + fhi.x) / 2, (flo.y + fhi.y) / 2, fhi.z - 0.015), 0.035, 0.012, "brass", verts=12)

def do_chair(by):
    o = by["chair(Clone)"]
    lo, hi = world_box([o])
    lv = [z for z, a in top_levels(o) if 0.1 < z < hi.z - 0.05]
    seat = min(lv) if lv else 0.2
    c = (lo + hi) / 2
    add_box(o, (lo.x + 0.012, lo.y + 0.012, seat - 0.002), (hi.x - 0.012, hi.y - 0.045, seat + 0.012), "velvet")
    add_sphere(o, (lo.x + 0.012, hi.y - 0.012, hi.z - 0.004), 0.011, "brass", 0.8)
    add_sphere(o, (hi.x - 0.012, hi.y - 0.012, hi.z - 0.004), 0.011, "brass", 0.8)

def build(name):
    palette()
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o)
    bpy.ops.import_scene.gltf(filepath=os.path.join(here, "base", name + ".glb"))
    objs = meshes()
    by = {o.name: o for o in bpy.data.objects}
    # Bounds are taken before anything is added, from the stock model.
    lo0, hi0 = world_box(objs)
    names0 = sorted(o.name for o in bpy.data.objects)
    for o in objs:
        for i, s in enumerate(o.material_slots):
            pass
        reskin(o, OVERRIDES.get(name))
        bevel(o)
    for o in objs:
        for f in o.data.polygons:
            f.use_smooth = False
    globals()["do_" + name](by)
    objs = meshes()
    lo, hi = world_box(objs)
    # Refit to the stock box: every axis is scaled about the box's own corner.
    s = Vector(((hi0[i] - lo0[i]) / (hi[i] - lo[i]) if hi[i] - lo[i] > 1e-6 else 1.0) for i in range(3))
    print("refit", name, [round(v, 4) for v in s])
    roots = [o for o in bpy.data.objects if o.parent is None]
    for o in roots:
        o.matrix_world = Matrix.Translation(lo0) @ Matrix.Diagonal((*s, 1)) @ Matrix.Translation(-lo) @ o.matrix_world
    assert names0 == sorted(o.name for o in bpy.data.objects), "node names changed"
    bpy.ops.object.select_all(action="DESELECT")
    os.makedirs(outdir, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(outdir, name + ".glb"), export_format="GLB", export_yup=True,
                              export_apply=False, export_cameras=False, export_lights=False)

ALL = ["pottedPlant", "chairCushion", "kitchenBar", "desk", "chairDesk", "bookcaseOpen", "loungeChair",
       "cardboardBoxClosed", "cabinetBedDrawerTable", "trashcan"]
ALL2 = ["rugDoormat", "bedSingle", "bookcaseClosed", "stoolBar", "lampRoundTable", "toilet", "bathroomSink",
        "cabinetTelevisionDoors", "televisionModern", "table", "showerRound", "chair"]
for n in (names or ALL + ALL2):
    build(n)
