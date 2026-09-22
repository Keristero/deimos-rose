# gdb script: record the original's RNG activity while it plays a film.
#
# The MSL LCG (sim/rand.odin) is exact, so RNG state is fully determined by
# the seed and the number of draws. We therefore log *who* draws and with what
# arguments, not the values:
#   S <tid> <seed>                     srand
#   D <tid>                            rand (one LCG step)
#   N <tid> <caller> <lo> <hi>         U_Utils_RandomInt entry
#   F <tid> <caller> <a> <b>           U_Utils_RandomFloat entry, f32 bits hex
#   I <tid> <player> <step>            G_Film::GetInputs entry, step from 1
#                                      per srand; a film of N frames shows
#                                      N+1 steps (the last detects the end)
# RandomInt/RandomFloat return early without drawing when the bounds are
# equal, so N/F lines without a following D are expected and must be matched.
# Stops are handled in Python and never reach the prompt, keeping overhead low.
#
# Detail mode ($trace_detail = 1) also logs entry to key functions, so ported
# code can be matched to the original call by call:
#   E <tid> <function> <details...>
# and $trace_steps limits logging to the first N steps of each film.
import gdb

SRAND, RAND = 0x461620, 0x4615E0
RANDOM_INT, RANDOM_FLOAT = 0x40F7E0, 0x40F840
GET_INPUTS = 0x41E300

log = open(gdb.convenience_variable("trace_out").string(), "w", buffering=1 << 16)
inferior = gdb.selected_inferior()
step = [0]
DETAIL = int(gdb.convenience_variable("trace_detail") or 0)
MAX_STEPS = int(gdb.convenience_variable("trace_steps") or 0)


def logging():
    return MAX_STEPS == 0 or step[0] <= MAX_STEPS


def u32s(addr, n):
    b = bytes(inferior.read_memory(addr, 4 * n))
    return [int.from_bytes(b[i : i + 4], "little") for i in range(0, 4 * n, 4)]


def s32(v):
    return v - (1 << 32) if v & 0x80000000 else v


class Hook(gdb.Breakpoint):
    def __init__(self, addr, kind):
        super().__init__(f"*{addr:#x}", internal=True)
        self.kind = kind

    def stop(self):
        if self.kind != "S" and not logging():
            return False
        tid = gdb.selected_thread().ptid[1]
        esp = int(gdb.parse_and_eval("$esp")) & 0xFFFFFFFF
        k = self.kind
        if k == "D":
            log.write(f"D {tid}\n")
        elif k in "NF":
            ret, a, b = u32s(esp, 3)
            if k == "N":
                log.write(f"N {tid} {ret:#x} {s32(a)} {s32(b)}\n")
            else:
                log.write(f"F {tid} {ret:#x} {a:08x} {b:08x}\n")
        elif k == "S":
            # A film starts with srand(film seed); steps count from there.
            step[0] = 0
            log.write(f"S {tid} {u32s(esp + 4, 1)[0]}\n")
            log.flush()
        else:
            player = u32s(esp + 4, 1)[0]
            if player == 0:
                step[0] += 1
                if step[0] % 60 == 0:
                    log.flush()
            log.write(f"I {tid} {player} {step[0]}\n")
        return False


for addr, kind in [(SRAND, "S"), (RAND, "D"), (RANDOM_INT, "N"),
                   (RANDOM_FLOAT, "F"), (GET_INPUTS, "I")]:
    Hook(addr, kind)


def cstr(addr, n=64):
    b = bytes(inferior.read_memory(addr, n))
    return b.split(b"\0", 1)[0].decode("latin-1")


def fourcc(v):
    return v.to_bytes(4, "little").decode("latin-1")


def f32(v):
    import struct
    return struct.unpack("<f", v.to_bytes(4, "little"))[0]


def reg(name):
    return int(gdb.parse_and_eval(f"${name}")) & 0xFFFFFFFF


# name, address, formatter(esp, ecx) -> details
DETAILS = [
    ("level_start", 0x41FC80, lambda esp, ecx: ""),
    ("game_step", 0x420280, lambda esp, ecx: (
        "time=%d view_top=%d view_bottom=%d progress=%d speed=%d" % (
            u32s(0x4E4836, 1)[0], *[s32(v) for v in u32s(0x4DE6F4, 1) + u32s(0x4DE6FC, 1)
                                     + u32s(0x4DE704, 1) + u32s(0x4DE708, 1)]))),
    ("map_row", 0x417900, lambda esp, ecx: f"row={s32(u32s(esp + 4, 1)[0])}"),
    ("eg_process", 0x418220, lambda esp, ecx: f"time={u32s(esp + 4, 1)[0]}"),
    ("initial_map_spawns", 0x0040fc20, lambda esp, ecx: ""),
    ("request_spawn", 0x417A90, lambda esp, ecx: (lambda r: (
        f"unit={fourcc(u32s(r, 1)[0])} x={f32(u32s(r + 4, 1)[0]):g} "
        f"y={f32(u32s(r + 8, 1)[0]):g}"))(u32s(esp + 4, 1)[0])),
    ("change_state", 0x4135A0, lambda esp, ecx: (
        f"unit={fourcc(u32s(u32s(ecx + 0x8A, 1)[0] + 4, 1)[0])} "
        f"entity={u32s(ecx + 0x92, 1)[0]} init={u32s(esp + 4, 1)[0] & 0xFF} "
        f"state={cstr(u32s(esp + 8, 1)[0])!r}")),
    # G_GameObject::MoveAndCheckPosition: entity number and position, for
    # comparing trajectories with the simulation.
    ("move", 0x424530, lambda esp, ecx: (
        f"entity={u32s(ecx + 0x92, 1)[0]} x={f32(u32s(ecx, 1)[0]):g} y={f32(u32s(ecx + 4, 1)[0]):g}")),
    ("spawn_control", 0x414AE0, lambda esp, ecx: (
        f"entity={u32s(ecx + 0x92, 1)[0]} state={s32(u32s(ecx + 0x9E, 1)[0])}")),
    ("sound_play", 0x44F5F0, lambda esp, ecx: (lambda st: (
        f"id={fourcc(u32s(st, 1)[0])}"))(u32s(esp + 4, 1)[0])),
    ("notice_process", 0x42E180, lambda esp, ecx: ""),
    ("player_process", 0x432820, lambda esp, ecx: f"player={u32s(ecx + 0xC2, 1)[0]} state={u32s(ecx + 0xBA, 1)[0]}"),
]


class Detail(gdb.Breakpoint):
    def __init__(self, name, addr, fmt):
        super().__init__(f"*{addr:#x}", internal=True)
        self.name, self.fmt = name, fmt

    def stop(self):
        if not logging():
            return False
        tid = gdb.selected_thread().ptid[1]
        try:
            d = self.fmt(reg("esp"), reg("ecx"))
        except gdb.MemoryError:
            d = "?"
        log.write(f"E {tid} {self.name} {d}\n".rstrip() + "\n")
        return False


if DETAIL:
    for name, addr, fmt in DETAILS:
        if addr:
            Detail(name, addr, fmt)

# The game is ended with wineserver -k; make sure buffered lines survive.
gdb.events.exited.connect(lambda _: log.close())
