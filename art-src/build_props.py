"""Rebuilds thirty-four of the furniture models under assets/props/furniture/ for game-murder-mystery.

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
    PAL["glow"] = mat("glow", (0.05, 0.5, 0.14), 0.0, 0.4)
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
"cardboardBoxClosed": {"wood": "kraft", "woodDark": "kraftDark"},
             "cardboardBoxOpen": {"wood": "kraft", "woodDark": "kraftDark"}, "plantSmall2": {"wood": "terracotta"},
             "computerScreen": {"metal": "gunmetal", "metalDark": "gunmetalDark"},
             "loungeSofa": {"carpet": "leather", "wood": "walnutDark"}, "trashcan": {"metal": "steel", "metalDark": "gunmetalDark"},
             "books": {"carpetDarker": "red", "carpetWhite": "paper", "plant": "leather", "metal": "brass"},
             "kitchenCabinet": {"metal": "slate"}, "sideTable": {"_defaultMat": "brass"},
             "computerKeyboard": {"metalDark": "gunmetalDark", "metalMedium": "steel"},
             "kitchenFridgeLarge": {"metalLight": "steel", "metalMedium": "gunmetal"},
             "speaker": {"metalMedium": "gunmetalDark"}, "loungeChairRelax": {"carpet": "leather", "metal": "brass"},
             "toaster": {"metalMedium": "steel", "metal": "gunmetalDark"},
             "bedDouble": {"carpetWhite": "linen", "carpet": "red"}, "bedBunk": {"carpetWhite": "linen", "carpet": "leather"},
             "loungeSofaLong": {"carpet": "velvet", "wood": "walnutDark"},
             "loungeDesignSofa": {"carpetBlue": "leather", "metal": "steel"},
             "rugRectangle": {"carpet": "velvet", "carpetDarker": "walnutDark"},
             "rugRound": {"carpet": "leather", "carpetDarker": "gunmetal"},
             "lampSquareTable": {"metal": "brass"}, "plantSmall1": {"wood": "terracotta"},
             "televisionVintage": {"metal": "brass", "wood": "walnut", "metalMedium": "gunmetal", "metalDark": "screen"},
             "kitchenStove": {"metal": "steel", "wood": "gunmetal", "metalDark": "gunmetalDark", "carpetWhite": "porcelain"},
             "kitchenSink": {"wood": "walnut", "woodDark": "walnutDark", "metal": "brass", "metalLight": "steel", "metalDark": "gunmetalDark", "_defaultMat": "porcelain"},
             "kitchenMicrowave": {"metalMedium": "gunmetal", "carpetWhite": "porcelain", "metalDark": "screen"},
             "tableCoffee": {"wood": "walnut"}}

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

def knob_in(host, c):
    """A knob half sunk in the face, so it does not grow the box the collision is measured from."""
    add_sphere(host, (c.x, c.y + 0.009, c.z), 0.011, "brass", 0.8)

def do_sideTableDrawers(by):
    o = by["sideTableDrawers(Clone)"]
    lo, hi = world_box([o])
    for k in ("drawerLeft", "drawerRight"):
        d = by[k]
        dlo, dhi = world_box([d])
        c = (dlo + dhi) / 2
        knob_in(d, c.__class__((c.x, dlo.y, c.z)))
        add_box(d, (dlo.x + 0.012, dlo.y - 0.001, dhi.z - 0.03), (dhi.x - 0.012, dlo.y + 0.001, dhi.z - 0.026), "brass")
    add_box(o, (lo.x + 0.01, lo.y + 0.01, lo.z), (hi.x - 0.01, hi.y - 0.01, lo.z + 0.02), "walnutDark")
    add_box(o, (lo.x + 0.03, lo.y + 0.06, hi.z - 0.002), (lo.x + 0.15, lo.y + 0.16, hi.z + 0.012), "red", rot=0.15)
    add_cyl(o, (hi.x - 0.1, lo.y + 0.12, hi.z + 0.002), 0.045, 0.006, "brass")

def do_cabinetBedDrawer(by):
    o, door, drawer = by["cabinetBedDrawer(Clone)"], by["door"], by["drawer"]
    lo, hi = world_box([o])
    for d, z in ((door, None), (drawer, None)):
        dlo, dhi = world_box([d])
        c = (dlo + dhi) / 2
        knob_in(d, c.__class__((c.x, dlo.y, c.z)))
    add_box(o, (lo.x + 0.01, lo.y + 0.01, lo.z), (hi.x - 0.01, hi.y - 0.01, lo.z + 0.02), "walnutDark")
    add_box(o, (lo.x + 0.03, lo.y + 0.05, hi.z - 0.002), (lo.x + 0.11, lo.y + 0.13, hi.z + 0.004), "gunmetal")
    add_box(o, (lo.x + 0.04, lo.y + 0.06, hi.z + 0.004), (lo.x + 0.10, lo.y + 0.12, hi.z + 0.006), "paper")
    add_cyl(o, (hi.x - 0.06, hi.y - 0.07, hi.z), 0.03, 0.008, "brass")

def case_books(o, seed):
    lo, hi = world_box([o])
    lv = sorted(z for z, a in top_levels(o) if z < hi.z - 0.05)
    for i, z in enumerate(lv):
        nxt = next((n for n in lv if n > z + 0.05), None)
        under = (nxt - 0.02) if nxt else hi.z - 0.02
        gap = under - z
        if gap > 0.06:
            books(o, Vector((lo.x + 0.03, lo.y + 0.04, 0)), Vector((hi.x - 0.03, hi.y - 0.03, 0)), z, gap, seed + i)
    return lo, hi

def do_bookcaseClosedWide(by):
    o = by["bookcaseClosedWide(Clone)"]
    lo, hi = case_books(o, 41)
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.03), "walnutDark")
    add_box(o, (lo.x, lo.y - 0.004, hi.z - 0.018), (hi.x, hi.y, hi.z), "brass")

def do_bookcaseOpenLow(by):
    o = by["bookcaseOpenLow(Clone)"]
    lo, hi = case_books(o, 61)
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.025), "walnutDark")
    add_box(o, (lo.x, lo.y - 0.003, hi.z - 0.014), (hi.x, hi.y, hi.z), "brass")

def do_loungeSofa(by):
    o = by["loungeSofa(Clone)"]
    lo, hi = world_box([o])
    lv = [(a, z) for z, a in top_levels(o) if 0.08 < z < hi.z * 0.8]
    seat = max(lv)[1] if lv else 0.2
    for x in (lo.x + 0.03, hi.x - 0.03):
        for y in (lo.y + 0.03, hi.y - 0.03):
            add_cyl(o, (x, y, lo.z + 0.006), 0.017, 0.012, "brass", verts=10)
    add_box(o, (lo.x + 0.12, lo.y + 0.12, seat), (lo.x + 0.28, lo.y + 0.27, seat + 0.07), "red", rot=0.3)
    add_sphere(o, (lo.x + 0.2, lo.y + 0.2, seat + 0.072), 0.008, "brass", 0.5)
    add_box(o, (hi.x - 0.30, lo.y + 0.14, seat), (hi.x - 0.14, lo.y + 0.28, seat + 0.06), "kraft", rot=-0.35)
    add_box(o, (lo.x, hi.y - 0.015, hi.z - 0.012), (hi.x, hi.y, hi.z), "brass")

def do_coatRackStanding(by):
    o = by["coatRackStanding(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_sphere(o, (c.x, c.y, hi.z - 0.012), 0.022, "brass", 1.0)
    add_torus(o, (c.x, c.y, lo.z + 0.02), 0.1, 0.01, "brass")
    for k in range(4):
        a = k * math.pi / 2 + math.pi / 4
        for h in (hi.z - 0.1, hi.z - 0.17):
            ang = a + (0.0 if h > hi.z - 0.12 else math.pi / 4)
            add_cyl(o, (c.x + math.cos(ang) * 0.045, c.y + math.sin(ang) * 0.045, h), 0.006, 0.07, "brass",
                    axis="X" if abs(math.cos(ang)) > 0.7 else "Y", verts=8)
    add_cyl(o, (c.x, c.y, hi.z - 0.205), 0.034, 0.01, "walnutDark")

def do_bench(by):
    o = by["bench(Clone)"]
    lo, hi = world_box([o])
    lv = [(a, z) for z, a in top_levels(o) if z > hi.z * 0.5]
    seat = max(lv)[1] if lv else hi.z
    add_box(o, (lo.x + 0.02, lo.y + 0.02, seat - 0.002), (hi.x - 0.02, hi.y - 0.02, seat + 0.012), "velvet")
    for x in (lo.x + 0.012, hi.x - 0.012):
        for y in (lo.y + 0.012, hi.y - 0.012):
            add_cyl(o, (x, y, lo.z + 0.004), 0.013, 0.008, "brass", verts=8)
    add_box(o, (lo.x + 0.02, lo.y + 0.02, seat + 0.012), (hi.x - 0.02, lo.y + 0.024, seat + 0.014), "brass")

def do_plantSmall2(by):
    o = by["plantSmall2(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    top = lo.z + (hi.z - lo.z) * 0.32
    add_torus(o, (c.x, c.y, top - 0.002), 0.045, 0.004, "brass")
    add_cyl(o, (c.x, c.y, top - 0.004), 0.043, 0.006, "soil")
    add_cyl(o, (c.x, c.y, lo.z + 0.004), 0.034, 0.008, "walnutDark")
    for k in range(5):
        a = k * 2 * math.pi / 5 + 0.3
        add_cyl(o, (c.x + math.cos(a) * 0.03, c.y + math.sin(a) * 0.03, top + 0.04), 0.008, 0.1, "plant", r2=0.0, verts=6)

def do_cardboardBoxOpen(by):
    o = by["cardboardBoxOpen(Clone)"]
    lo, hi = world_box([o])
    c = (lo.x + 0.292 - 0.08 + 0.08) / 2
    c = (lo.x + hi.x) / 2
    add_box(o, (c - 0.016, lo.y - 0.001, lo.z + 0.02), (c + 0.016, lo.y + 0.001, hi.z * 0.5), "tape")
    add_box(o, (c + 0.04, lo.y - 0.002, hi.z * 0.2), (c + 0.1, lo.y, hi.z * 0.34), "paper")
    add_box(o, (c - 0.12, lo.y - 0.002, hi.z * 0.12), (c - 0.08, lo.y, hi.z * 0.2), "red")
    add_box(o, (c - 0.07, lo.y + 0.06, hi.z * 0.5), (c + 0.06, lo.y + 0.17, hi.z * 0.5 + 0.01), "paper", rot=0.2)

def do_computerScreen(by):
    o = by["computerScreen(Clone)"]
    lo, hi = world_box([o])
    c = (lo.x + hi.x) / 2
    z0, z1 = lo.z + 0.085, hi.z - 0.02
    add_box(o, (lo.x + 0.02, lo.y - 0.0008, z0), (hi.x - 0.02, lo.y + 0.003, z1), "screen")
    for i in range(5):
        w = (hi.x - lo.x - 0.1) * (0.9 if i % 2 == 0 else 0.55)
        z = z1 - 0.03 - i * 0.03
        add_box(o, (lo.x + 0.05, lo.y - 0.0016, z), (lo.x + 0.05 + w, lo.y - 0.0006, z + 0.008), "glow")
    add_box(o, (c + 0.05, lo.y - 0.0008, lo.z + 0.062), (c + 0.062, lo.y + 0.002, lo.z + 0.07), "red")

def do_lampRoundFloor(by):
    o = by["lampRoundFloor(Clone)"]
    lo, hi = world_box([o])
    c = Vector((0.06, 0.06, 0))
    add_cyl(o, (c.x, c.y, lo.z + 0.01), 0.07, 0.02, "gunmetalDark", verts=20)
    add_torus(o, (c.x, c.y, lo.z + 0.022), 0.07, 0.004, "brass")
    add_sphere(o, (c.x, c.y, hi.z * 0.2), 0.016, "brass", 1.0)
    add_torus(o, (c.x, c.y, hi.z - 0.003), 0.058, 0.004, "brass")
    add_torus(o, (c.x, c.y, hi.z * 0.74), 0.07, 0.004, "brass")

def do_lampSquareFloor(by):
    o = by["lampSquareFloor(Clone)"]
    lo, hi = world_box([o])
    c = Vector((0.06, 0.06, 0))
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.014), "gunmetalDark")
    add_box(o, (lo.x + 0.008, lo.y + 0.008, lo.z + 0.014), (hi.x - 0.008, hi.y - 0.008, lo.z + 0.02), "brass")
    add_sphere(o, (c.x, c.y, hi.z * 0.22), 0.015, "brass", 1.0)
    add_box(o, (lo.x, lo.y, hi.z - 0.012), (hi.x, hi.y, hi.z), "brass")
    add_box(o, (lo.x, lo.y, hi.z * 0.72), (hi.x, hi.y, hi.z * 0.72 + 0.008), "brass")

def seat_z(o, lo_f=0.25, hi_f=0.75):
    lo, hi = world_box([o])
    lv = [(a, z) for z, a in top_levels(o, 0.004) if lo.z + (hi.z - lo.z) * lo_f < z < lo.z + (hi.z - lo.z) * hi_f]
    return max(lv)[1] if lv else lo.z + (hi.z - lo.z) * 0.5

def do_books(by):
    o = by["books(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x, lo.y, lo.z), (lo.x + 0.006, hi.y, lo.z + 0.07), "brass")
    for z in (0.03, 0.062):
        add_box(o, (lo.x + 0.012, lo.y - 0.001, z), (hi.x - 0.012, lo.y + 0.001, z + 0.004), "brass")

def do_kitchenCabinet(by):
    o, d = by["kitchenCabinet(Clone)"], by["door"]
    lo, hi = world_box([o, d])
    for i, s in enumerate(d.material_slots):
        if s.material == PAL["slate"]:
            d.material_slots[i].material = PAL["brass"]
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.03), "walnutDark")
    add_box(o, (lo.x, lo.y - 0.002, hi.z - 0.012), (hi.x, lo.y + 0.01, hi.z), "brass")
    add_box(o, (lo.x + 0.07, lo.y - 0.002, lo.z + 0.2), (lo.x + 0.1, lo.y, hi.z - 0.1), "linen")
    add_box(o, (lo.x + 0.07, lo.y - 0.003, lo.z + 0.23), (lo.x + 0.1, lo.y, lo.z + 0.245), "red")

def do_chairRounded(by):
    o = by["chairRounded(Clone)"]
    lo, hi = world_box([o])
    z = seat_z(o)
    add_box(o, (lo.x + 0.025, lo.y + 0.025, z - 0.002), (hi.x - 0.025, hi.y - 0.025, z + 0.012), "velvet")
    for x in (lo.x + 0.012, hi.x - 0.012):
        for y in (lo.y + 0.012, hi.y - 0.012):
            add_cyl(o, (x, y, lo.z + 0.004), 0.012, 0.008, "brass", verts=8)

def do_sideTable(by):
    o = by["sideTable(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x + 0.03, lo.y + 0.03, hi.z - 0.002), (hi.x - 0.03, hi.y - 0.03, hi.z + 0.002), "leather")
    add_box(o, (lo.x, lo.y - 0.002, hi.z - 0.03), (hi.x, lo.y + 0.004, hi.z - 0.024), "brass")
    for z, a in top_levels(o, 0.004):
        if lo.z + 0.05 < z < hi.z - 0.1:
            add_box(o, (lo.x + 0.06, lo.y + 0.04, z), (lo.x + 0.18, hi.y - 0.04, z + 0.03), "kraft")
            add_box(o, (lo.x + 0.07, lo.y + 0.05, z + 0.03), (lo.x + 0.17, hi.y - 0.05, z + 0.037), "red")

def do_computerKeyboard(by):
    o = by["computerKeyboard(Clone)"]
    lo, hi = world_box([o])
    top = hi.z
    cols, rows = 14, 4
    x0, x1 = lo.x + 0.014, hi.x - 0.014
    y0, y1 = lo.y + 0.012, hi.y - 0.012
    w, h = (x1 - x0) / cols, (y1 - y0) / rows
    for r in range(rows):
        for c in range(cols):
            if r == 0 and c in range(4, 10):
                continue
            add_box(o, (x0 + c * w + 0.0012, y0 + r * h + 0.0012, top - 0.007), (x0 + (c + 1) * w - 0.0012, y0 + (r + 1) * h - 0.0012, top - 0.001), "paper" if r == 3 else "gunmetalDark")
    add_box(o, (x0 + 4 * w, y0 + 0.0012, top - 0.007), (x0 + 10 * w, y0 + h - 0.0012, top - 0.001), "gunmetalDark")

def do_bookcaseClosedDoors(by):
    o = by["bookcaseClosedDoors(Clone)"]
    lo, hi = world_box([o])
    c = (lo.x + hi.x) / 2
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.04), "walnutDark")
    add_box(o, (lo.x, lo.y - 0.004, hi.z - 0.02), (hi.x, hi.y, hi.z), "brass")
    for x0, x1 in ((lo.x + 0.04, c - 0.015), (c + 0.015, hi.x - 0.04)):
        add_box(o, (x0, lo.y - 0.0015, lo.z + 0.1), (x1, lo.y, hi.z - 0.1), "walnutDark")
        add_box(o, (x0 + 0.015, lo.y - 0.0025, lo.z + 0.12), (x1 - 0.015, lo.y - 0.0015, hi.z - 0.12), "leather")
    for x in (c - 0.03, c + 0.03):
        add_box(o, (x - 0.004, lo.y - 0.008, 0.38), (x + 0.004, lo.y - 0.002, 0.52), "brass")

def do_cabinetBed(by):
    o = by["cabinetBed(Clone)"]
    lo, hi = world_box([o])
    c = (lo.x + hi.x) / 2
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.02), "walnutDark")
    add_box(o, (lo.x + 0.015, lo.y + 0.015, hi.z - 0.002), (hi.x - 0.015, hi.y - 0.015, hi.z + 0.002), "leather")
    add_sphere(o, (c + 0.05, lo.y + 0.01, hi.z * 0.7), 0.012, "brass", 1.0)
    add_box(o, (lo.x, lo.y - 0.003, hi.z - 0.012), (hi.x, lo.y + 0.003, hi.z - 0.008), "brass")

def do_kitchenFridgeLarge(by):
    o = by["kitchenFridgeLarge(Clone)"]
    lo, hi = world_box([v for v in by.values() if v.type == "MESH"])
    c = (lo.x + hi.x) / 2
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.05), "gunmetalDark")
    for i in range(5):
        z = lo.z + 0.012 + i * 0.007
        add_box(o, (lo.x + 0.06, lo.y - 0.001, z), (hi.x - 0.06, lo.y + 0.002, z + 0.003), "gunmetal")
    add_box(o, (c - 0.004, lo.y - 0.001, lo.z + 0.1), (c + 0.004, lo.y + 0.001, hi.z - 0.04), "gunmetalDark")
    add_box(o, (c + 0.1, lo.y - 0.001, hi.z - 0.12), (c + 0.14, lo.y + 0.001, hi.z - 0.108), "brass")
    for x in (c - 0.03, c + 0.03):
        add_box(o, (x - 0.005, lo.y - 0.005, hi.z * 0.45), (x + 0.005, lo.y, hi.z * 0.75), "brass")

def do_speaker(by):
    o = by["speaker(Clone)"]
    lo, hi = world_box([o])
    c = Vector(((lo.x + hi.x) / 2, lo.y, 0))
    cx = (lo.x + hi.x) / 2
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.03), "walnutDark")
    for z, r in ((0.2, 0.045), (0.46, 0.028)):
        add_cyl(o, (cx, lo.y + 0.002, z), r + 0.006, 0.006, "brass", axis="Y", verts=20)
        add_cyl(o, (cx, lo.y + 0.001, z), r, 0.006, "gunmetalDark", axis="Y", verts=20)
        add_sphere(o, (cx, lo.y + r * 0.3, z), r * 0.3, "steel", 1.0)
    add_box(o, (cx - 0.02, lo.y - 0.001, hi.z - 0.05), (cx + 0.02, lo.y + 0.001, hi.z - 0.046), "brass")

def do_tableRound(by):
    o = by["tableRound(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    zt = hi.z
    add_cyl(o, (c.x, c.y, zt), min(hi.x - lo.x, hi.y - lo.y) * 0.5 - 0.02, 0.004, "leather", verts=28)
    add_torus(o, (c.x, c.y, zt - 0.003), min(hi.x - lo.x, hi.y - lo.y) * 0.5 - 0.012, 0.004, "brass")
    add_cyl(o, (c.x, c.y, lo.z + 0.008), 0.05, 0.016, "brass", verts=20)

def do_loungeChairRelax(by):
    o = by["loungeChairRelax(Clone)"]
    lo, hi = world_box([o])
    z = seat_z(o, 0.2, 0.6)
    cx = (lo.x + hi.x) / 2
    add_box(o, (cx - 0.1, lo.y + 0.18, z), (cx + 0.06, lo.y + 0.33, z + 0.06), "kraft", rot=0.3)

def do_toaster(by):
    o = by["toaster(Clone)"]
    lo, hi = world_box([o])
    for dx in (-0.034, 0.034):
        add_box(o, (dx - 0.008, -0.036, hi.z - 0.004), (dx + 0.008, 0.036, hi.z), "gunmetalDark")
    add_box(o, (hi.x - 0.002, -0.006, 0.05), (hi.x + 0.004, 0.006, 0.09), "brass")
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.008), "gunmetalDark")
    add_cyl(o, (hi.x - 0.03, lo.y + 0.002, 0.04), 0.011, 0.008, "brass", axis="Y", verts=12)
    add_box(o, (lo.x + 0.02, lo.y - 0.001, 0.09), (lo.x + 0.07, lo.y + 0.001, 0.095), "red")

def do_bedDouble(by):
    o, cover = by["bedDouble(Clone)"], by["cover"]
    lo, hi = world_box([o])
    clo, chi = world_box([cover])
    cx = (lo.x + hi.x) / 2
    add_box(cover, (clo.x - 0.002, clo.y + 0.32, chi.z - 0.004), (chi.x + 0.002, clo.y + 0.345, chi.z + 0.002), "brass")
    add_box(cover, (clo.x - 0.002, chi.y - 0.1, chi.z - 0.004), (chi.x + 0.002, chi.y, chi.z + 0.003), "linen")
    for x in (lo.x + 0.014, hi.x - 0.014):
        add_sphere(o, (x, hi.y - 0.014, hi.z - 0.012), 0.014, "brass")
    for name in ("pillowLeft", "pillowRight"):
        plo, phi = world_box([by[name]])
        add_box(by[name], (plo.x + 0.03, plo.y + 0.02, phi.z - 0.003), (phi.x - 0.03, phi.y - 0.02, phi.z), "paper")
    add_box(o, (cx - 0.1, clo.y + 0.12, chi.z - 0.003), (cx + 0.1, clo.y + 0.24, chi.z + 0.003), "kraft", rot=0.0)

def do_bedBunk(by):
    o = by["bedBunk(Clone)"]
    lo, hi = world_box([o])
    for k in ("coverBottom", "coverTop"):
        clo, chi = world_box([by[k]])
        add_box(by[k], (clo.x - 0.002, clo.y + 0.2, chi.z - 0.004), (chi.x + 0.002, clo.y + 0.215, chi.z + 0.002), "brass")
        add_box(by[k], (clo.x - 0.002, chi.y - 0.07, chi.z - 0.004), (chi.x + 0.002, chi.y, chi.z + 0.003), "linen")
    for k in ("pillowBottom", "pillowTop"):
        plo, phi = world_box([by[k]])
        add_box(by[k], (plo.x + 0.025, plo.y + 0.02, phi.z - 0.003), (phi.x - 0.025, phi.y - 0.02, phi.z), "paper")
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.01), "walnutDark")
    for x in (lo.x + 0.012, hi.x - 0.012):
        add_sphere(o, (x, hi.y - 0.012, hi.z - 0.01), 0.012, "brass")

def sofa_extras(o, red_x, kraft_x):
    # No feet or back rail: both sofas have their own legs and a bounding-box corner is not on the L-shaped one.
    lo, hi = world_box([o])
    lv = [(a, z) for z, a in top_levels(o) if 0.08 < z < hi.z * 0.8]
    seat = max(lv)[1] if lv else 0.2
    add_box(o, (red_x, lo.y + 0.12, seat), (red_x + 0.16, lo.y + 0.27, seat + 0.07), "red", rot=0.3)
    add_box(o, (kraft_x, lo.y + 0.12, seat), (kraft_x + 0.16, lo.y + 0.26, seat + 0.06), "kraft", rot=-0.35)

def do_loungeSofaLong(by):
    o = by["loungeSofaLong(Clone)"]
    lo, hi = world_box([o])
    sofa_extras(o, lo.x + 0.14, hi.x - 0.3)

def do_loungeDesignSofa(by):
    o = by["loungeDesignSofa(Clone)"]
    lo, hi = world_box([o])
    sofa_extras(o, lo.x + 0.14, hi.x - 0.3)

def rug_border(o, key, key2):
    lo, hi = world_box([o])
    z = hi.z
    m = 0.03
    for y in (lo.y + m, hi.y - m):
        add_box(o, (lo.x + m, y - 0.007, z - 0.002), (hi.x - m, y + 0.007, z + 0.0004), key)
    for x in (lo.x + m, hi.x - m):
        add_box(o, (x - 0.007, lo.y + m, z - 0.002), (x + 0.007, hi.y - m, z + 0.0004), key)
    c = (lo + hi) / 2
    add_box(o, (c.x - 0.18, c.y - 0.012, z - 0.002), (c.x + 0.18, c.y + 0.012, z + 0.0004), key2)
    add_box(o, (c.x - 0.012, c.y - 0.18, z - 0.002), (c.x + 0.012, c.y + 0.18, z + 0.0004), key2)

def do_rugRectangle(by):
    rug_border(by["rugRectangle(Clone)"], "brass", "red")

def do_rugRound(by):
    o = by["rugRound(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    for r, key in ((0.4, "brass"), (0.3, "paper"), (0.1, "red")):
        add_torus(o, (c.x, c.y, hi.z - 0.002), r, 0.004, key)

def do_lampSquareTable(by):
    o = by["lampSquareTable(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_box(o, (c.x - 0.045, c.y - 0.045, lo.z), (c.x + 0.045, c.y + 0.045, lo.z + 0.01), "walnutDark")
    add_sphere(o, (c.x, c.y, lo.z + 0.06), 0.012, "brass", 1.0)
    add_box(o, (c.x - 0.042, c.y - 0.042, hi.z - 0.004), (c.x + 0.042, c.y + 0.042, hi.z), "brass")
    add_box(o, (c.x - 0.055, c.y - 0.055, hi.z * 0.5), (c.x + 0.055, c.y + 0.055, hi.z * 0.5 + 0.004), "brass")

def do_televisionVintage(by):
    o = by["televisionVintage(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x + 0.03, lo.y - 0.0005, lo.z + 0.04), (lo.x + 0.27, lo.y + 0.004, hi.z - 0.03), "screen")
    for k in range(3):
        add_cyl(o, (hi.x - 0.055, lo.y + 0.002, lo.z + 0.06 + k * 0.05), 0.014, 0.008, "brass", axis="Y", verts=12)
    for x in (lo.x + 0.04, hi.x - 0.04):
        for y in (lo.y + 0.04, hi.y - 0.04):
            add_cyl(o, (x, y, lo.z + 0.006), 0.014, 0.012, "walnutDark", verts=8)
    add_box(o, (lo.x + 0.06, lo.y + 0.06, hi.z - 0.003), (hi.x - 0.08, hi.y - 0.06, hi.z + 0.001), "gunmetalDark")

def do_plantSmall1(by):
    o = by["plantSmall1(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    top = lo.z + (hi.z - lo.z) * 0.3
    add_torus(o, (c.x, c.y, top - 0.002), 0.04, 0.004, "brass")
    add_cyl(o, (c.x, c.y, top - 0.004), 0.038, 0.006, "soil")
    add_cyl(o, (c.x, c.y, lo.z + 0.003), 0.03, 0.006, "walnutDark")

def do_kitchenStove(by):
    o, d = by["kitchenStove(Clone)"], by["door"]
    lo, hi = world_box([o, d])
    cx = (lo.x + hi.x) / 2
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.03), "gunmetalDark")
    add_box(o, (lo.x + 0.04, lo.y - 0.006, hi.z * 0.76), (hi.x - 0.04, lo.y - 0.002, hi.z * 0.77), "brass")
    for k in range(4):
        add_cyl(o, (lo.x + 0.07 + k * 0.1, lo.y + 0.002, hi.z * 0.9), 0.016, 0.01, "brass", axis="Y", verts=12)
    for x in (lo.x + 0.11, hi.x - 0.11):
        for y in (lo.y + 0.11, hi.y - 0.11):
            add_torus(o, (x, y, hi.z + 0.0), 0.04, 0.005, "gunmetalDark")

def do_kitchenSink(by):
    o, d = by["kitchenSink(Clone)"], by["door"]
    lo, hi = world_box([o, d])
    cx = (lo.x + hi.x) / 2
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.03), "gunmetalDark")
    add_box(o, (lo.x, lo.y - 0.002, hi.z * 0.9), (hi.x, lo.y + 0.008, hi.z * 0.9 + 0.012), "slate")
    add_box(o, (lo.x + 0.07, lo.y - 0.003, lo.z + 0.2), (lo.x + 0.1, lo.y, lo.z + 0.3), "linen")
    add_box(o, (cx + 0.05, lo.y - 0.003, lo.z + 0.23), (cx + 0.08, lo.y, lo.z + 0.245), "red")

def do_kitchenMicrowave(by):
    o = by["kitchenMicrowave(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.008), "gunmetalDark")
    for k in range(3):
        add_cyl(o, (hi.x - 0.04, lo.y - 0.002, lo.z + 0.05 + k * 0.035), 0.011, 0.008, "brass", axis="Y", verts=12)
    add_box(o, (hi.x - 0.05, lo.y - 0.0012, hi.z - 0.04), (hi.x - 0.03, lo.y + 0.001, hi.z - 0.034), "glow")
    add_box(o, (lo.x + 0.01, lo.y - 0.004, lo.z + 0.03), (lo.x + 0.016, lo.y, hi.z - 0.03), "brass")

def do_tableCoffee(by):
    o = by["tableCoffee(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_box(o, (lo.x + 0.02, lo.y + 0.02, hi.z - 0.003), (hi.x - 0.02, hi.y - 0.02, hi.z + 0.001), "leather")
    add_box(o, (lo.x, lo.y, hi.z - 0.012), (hi.x, lo.y + 0.006, hi.z - 0.002), "brass")
    add_box(o, (lo.x, hi.y - 0.006, hi.z - 0.012), (hi.x, hi.y, hi.z - 0.002), "brass")
    for x in (lo.x + 0.03, hi.x - 0.03):
        for y in (lo.y + 0.03, hi.y - 0.03):
            add_cyl(o, (x, y, lo.z + 0.004), 0.012, 0.008, "brass", verts=8)

def do_computerMouse(by):
    o = by["computerMouse(Clone)"]
    lo, hi = world_box([o])
    cx = (lo.x + hi.x) / 2
    add_box(o, (cx - 0.0015, lo.y + 0.004, hi.z - 0.003), (cx + 0.0015, lo.y + 0.045, hi.z), "gunmetal")
    add_cyl(o, (cx, lo.y + 0.03, hi.z - 0.005), 0.0035, 0.006, "steel", axis="X", verts=10)
    add_cyl(o, (cx, hi.y - 0.006, lo.z + 0.008), 0.0025, 0.012, "gunmetalDark", axis="Y", verts=6)
    add_box(o, (lo.x + 0.004, lo.y + 0.004, lo.z), (hi.x - 0.004, hi.y - 0.004, lo.z + 0.002), "steel")

def do_speakerSmall(by):
    o = by["speakerSmall(Clone)"]
    lo, hi = world_box([o])
    cx = (lo.x + hi.x) / 2
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.012), "walnutDark")
    for z, r in ((0.095, 0.036), (0.215, 0.019)):
        add_cyl(o, (cx, lo.y + 0.002, z), r + 0.004, 0.005, "brass", axis="Y", verts=18)
        add_cyl(o, (cx, lo.y + 0.001, z), r, 0.005, "gunmetalDark", axis="Y", verts=18)
        add_sphere(o, (cx, lo.y + r * 0.25, z), r * 0.32, "steel", 1.0)
    add_box(o, (cx - 0.012, lo.y - 0.001, hi.z - 0.035), (cx + 0.012, lo.y + 0.001, hi.z - 0.032), "brass")

def cushion_bench(o, lo, hi):
    lv = [(a, z) for z, a in top_levels(o) if z > hi.z * 0.3]
    seat = max(lv)[1] if lv else hi.z * 0.6
    add_box(o, (lo.x + 0.02, lo.y + 0.02, seat - 0.002), (hi.x - 0.02, hi.y - 0.02, seat + 0.006), "velvet")
    add_box(o, (lo.x + 0.02, lo.y + 0.02, seat + 0.006), (hi.x - 0.02, lo.y + 0.024, seat + 0.008), "brass")
    for x in (lo.x + 0.015, hi.x - 0.015):
        for y in (lo.y + 0.015, hi.y - 0.015):
            add_cyl(o, (x, y, lo.z + 0.004), 0.012, 0.008, "brass", verts=8)
    return seat

def do_benchCushionLow(by):
    o = by["benchCushionLow(Clone)"]
    lo, hi = world_box([o])
    cushion_bench(o, lo, hi)

def do_benchCushion(by):
    o = by["benchCushion(Clone)"]
    lo, hi = world_box([o])
    cushion_bench(o, lo, hi)
    add_box(o, (lo.x + 0.01, hi.y - 0.012, hi.z - 0.012), (hi.x - 0.01, hi.y, hi.z), "brass")

def do_radio(by):
    o = by["radio(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.008), "walnutDark")
    add_box(o, (lo.x + 0.03, lo.y - 0.0015, lo.z + 0.06), (lo.x + 0.15, lo.y + 0.002, hi.z - 0.04), "paper")
    add_box(o, (lo.x + 0.075, lo.y - 0.003, lo.z + 0.06), (lo.x + 0.079, lo.y + 0.002, hi.z - 0.04), "red")
    for k in range(2):
        add_cyl(o, (hi.x - 0.055 - k * 0.05, lo.y + 0.002, lo.z + 0.05), 0.016, 0.01, "brass", axis="Y", verts=14)
    add_cyl(o, (hi.x - 0.03, hi.y - 0.01, hi.z - 0.005), 0.003, 0.012, "steel", verts=6)

def do_kitchenCabinetDrawer(by):
    o, d, dr = by["kitchenCabinetDrawer(Clone)"], by["door"], by["drawer"]
    lo, hi = world_box([o, d, dr])
    c = (lo.x + hi.x) / 2
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.03), "gunmetalDark")
    add_box(o, (lo.x - 0.001, lo.y - 0.002, hi.z - 0.014), (hi.x + 0.001, hi.y + 0.002, hi.z + 0.001), "slate")
    add_box(o, (c - 0.06, lo.y - 0.006, hi.z * 0.8), (c + 0.06, lo.y, hi.z * 0.8 + 0.008), "brass")
    add_box(o, (hi.x - 0.07, lo.y - 0.006, hi.z * 0.46), (hi.x - 0.06, lo.y, hi.z * 0.62), "brass")

def do_kitchenFridge(by):
    o = by["kitchenFridge(Clone)"]
    lo, hi = world_box([v for v in by.values() if v.type == "MESH"])
    c = (lo.x + hi.x) / 2
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.04), "gunmetalDark")
    for i in range(4):
        z = lo.z + 0.01 + i * 0.006
        add_box(o, (lo.x + 0.05, lo.y - 0.001, z), (hi.x - 0.05, lo.y + 0.002, z + 0.003), "gunmetal")
    add_box(o, (hi.x - 0.07, lo.y - 0.006, hi.z * 0.62), (hi.x - 0.06, lo.y, hi.z * 0.85), "brass")
    add_box(o, (hi.x - 0.07, lo.y - 0.006, hi.z * 0.2), (hi.x - 0.06, lo.y, hi.z * 0.5), "brass")

def laundry(o, lo, hi):
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.03), "gunmetalDark")
    cx = (lo.x + hi.x) / 2
    for k in range(2):
        add_cyl(o, (lo.x + 0.07 + k * 0.05, lo.y + 0.002, hi.z - 0.045), 0.014, 0.01, "brass", axis="Y", verts=12)
    add_box(o, (hi.x - 0.1, lo.y - 0.0012, hi.z - 0.055), (hi.x - 0.05, lo.y + 0.001, hi.z - 0.045), "glow")
    add_box(o, (lo.x + 0.02, lo.y - 0.004, hi.z - 0.075), (hi.x - 0.02, lo.y, hi.z - 0.07), "brass")

def do_dryer(by):
    o = by["dryer(Clone)"]
    lo, hi = world_box([v for v in by.values() if v.type == "MESH"])
    laundry(o, lo, hi)

def do_washer(by):
    o = by["washer(Clone)"]
    lo, hi = world_box([v for v in by.values() if v.type == "MESH"])
    laundry(o, lo, hi)

def do_lampWall(by):
    o = by["lampWall(Clone)"]
    lo, hi = world_box([o])
    c = (lo.x + hi.x) / 2
    add_box(o, (c - 0.04, hi.y - 0.006, lo.z + 0.01), (c + 0.04, hi.y, hi.z - 0.01), "brass")
    add_cyl(o, (c, lo.y + 0.008, (lo.z + hi.z) / 2), 0.025, 0.006, "brass", axis="Y", verts=16)

def table_top(o, lo, hi):
    add_box(o, (lo.x, lo.y, hi.z - 0.018), (hi.x, hi.y, hi.z - 0.006), "walnutDark")
    for x in (lo.x + 0.02, hi.x - 0.02):
        for y in (lo.y + 0.02, hi.y - 0.02):
            add_cyl(o, (x, y, lo.z + 0.004), 0.012, 0.008, "brass", verts=8)

def do_tableCrossCloth(by):
    o = by["tableCrossCloth(Clone)"]
    lo, hi = world_box([o])
    table_top(o, lo, hi)
    add_box(o, (lo.x + 0.04, lo.y + 0.04, hi.z - 0.006), (hi.x - 0.04, hi.y - 0.04, hi.z - 0.003), "red")

def do_tableCloth(by):
    o = by["tableCloth(Clone)"]
    lo, hi = world_box([o])
    table_top(o, lo, hi)
    add_box(o, (lo.x + 0.05, lo.y + 0.05, hi.z - 0.006), (hi.x - 0.05, hi.y - 0.05, hi.z - 0.003), "paper")

def do_cabinetTelevision(by):
    o = by["cabinetTelevision(Clone)"]
    lo, hi = world_box([o])
    c = (lo.x + hi.x) / 2
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.02), "walnutDark")
    add_box(o, (lo.x + 0.02, lo.y + 0.02, hi.z - 0.003), (hi.x - 0.02, hi.y - 0.02, hi.z + 0.001), "leather")
    for x in (c - 0.2, c + 0.2):
        add_box(o, (x - 0.03, lo.y - 0.006, hi.z * 0.6), (x + 0.03, lo.y, hi.z * 0.6 + 0.008), "brass")

def do_tree_oak(by):
    o = by["tree_oak"]
    lo, hi = world_box([o])
    for k in range(5):
        a = k * 2 * math.pi / 5 + 0.3
        add_cyl(o, (math.cos(a) * 0.045, math.sin(a) * 0.045, lo.z + 0.1), 0.02, 0.1, "woodBark", r2=0.006, verts=6)
    add_cyl(o, (0, 0, 0.5), 0.018, 0.3, "woodBark", verts=6)
    for k, (x, y, z, r) in enumerate(((0.16, 0.0, 0.8, 0.12), (-0.14, 0.1, 0.9, 0.13), (0.0, -0.18, 0.78, 0.11), (-0.05, 0.16, 1.05, 0.1))):
        add_sphere(o, (x, y, z), r, "leafsGreen", 0.8)

def do_plant_bush(by):
    o = by["plant_bush"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    for k in range(6):
        a = k * math.pi / 3
        add_sphere(o, (math.cos(a) * 0.1, math.sin(a) * 0.1, lo.z + 0.1), 0.05, "grass", 0.8)
    add_cyl(o, (c.x, c.y, lo.z + 0.03), 0.03, 0.06, "woodBark", verts=6)

NATURE = ["tree_oak", "plant_bush"]

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
    nature = name in NATURE
    if nature:
        for m in bpy.data.materials:
            PAL[m.name.split(".")[0]] = m
    for o in objs:
        if not nature:
            reskin(o, OVERRIDES.get(name))
            bevel(o)
    for o in objs:
        if not nature:
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
    od = os.path.join(here, "..", "assets", "props", "nature") if nature else outdir
    os.makedirs(od, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(od, name + ".glb"), export_format="GLB", export_yup=True,
                              export_apply=False, export_cameras=False, export_lights=False)

ALL = ["pottedPlant", "chairCushion", "kitchenBar", "desk", "chairDesk", "bookcaseOpen", "loungeChair",
       "cardboardBoxClosed", "cabinetBedDrawerTable", "trashcan"]
ALL2 = ["rugDoormat", "bedSingle", "bookcaseClosed", "stoolBar", "lampRoundTable", "toilet", "bathroomSink",
        "cabinetTelevisionDoors", "televisionModern", "table", "showerRound", "chair"]
ALL3 = ["sideTableDrawers", "cabinetBedDrawer", "bookcaseClosedWide", "loungeSofa", "coatRackStanding", "bench",
        "plantSmall2", "cardboardBoxOpen", "bookcaseOpenLow", "computerScreen", "lampRoundFloor", "lampSquareFloor"]
ALL4 = ["books", "kitchenCabinet", "chairRounded", "sideTable", "computerKeyboard", "bookcaseClosedDoors",
        "cabinetBed", "kitchenFridgeLarge", "speaker", "tableRound", "loungeChairRelax", "toaster"]
ALL5 = ["bedDouble", "bedBunk", "loungeSofaLong", "loungeDesignSofa", "rugRectangle", "rugRound", "lampSquareTable",
        "televisionVintage", "plantSmall1", "kitchenStove", "kitchenSink", "kitchenMicrowave", "tableCoffee"]
ALL6 = ["computerMouse", "speakerSmall", "benchCushionLow", "benchCushion", "radio", "kitchenCabinetDrawer",
        "kitchenFridge", "dryer", "washer", "lampWall", "tableCrossCloth", "tableCloth", "cabinetTelevision",
        "tree_oak", "plant_bush"]
for n in (names or ALL + ALL2 + ALL3 + ALL4 + ALL5 + ALL6):
    build(n)
