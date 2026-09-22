# gdb script: dump every loaded sprite group's frame dimensions.
#
# U_Sprite_Load builds a list at DAT_004dce06 of {magic, id, count, frames*}
# records; each frame's encoded data starts with {magic, width, height}.
# Frame sizes decide entity dimensions and therefore collisions, so this is
# the ground truth our plate scanner (data/sprite_plate.odin) must match.
import gdb

LIST_PTR = 0x4DCE06  # holds a U_LinkedList*: {count, head, tail}
out = open(gdb.convenience_variable("sprites_out").string(), "w")
inf = gdb.selected_inferior()


def u32(addr):
    return int.from_bytes(bytes(inf.read_memory(addr, 4)), "little")


def fourcc(v):
    return v.to_bytes(4, "little").decode("latin-1")


lst = u32(LIST_PTR)
count = u32(lst)
link = u32(lst + 4)
out.write("sprite\tframe\twidth\theight\n")
for _ in range(count):
    obj = u32(link + 8)
    ident, frames, array = u32(obj + 4), u32(obj + 8), u32(obj + 12)
    for i in range(frames):
        data = u32(array + i * 4)
        if data:
            out.write(f"{fourcc(ident)}\t{i}\t{u32(data + 4)}\t{u32(data + 8)}\n")
    link = u32(link + 4)
out.close()
print(f"sprite groups: {count}")
