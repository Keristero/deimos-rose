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
import gdb

SRAND, RAND = 0x461620, 0x4615E0
RANDOM_INT, RANDOM_FLOAT = 0x40F7E0, 0x40F840
GET_INPUTS = 0x41E300

log = open(gdb.convenience_variable("trace_out").string(), "w", buffering=1 << 16)
inferior = gdb.selected_inferior()
step = [0]


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

# The game is ended with wineserver -k; make sure buffered lines survive.
gdb.events.exited.connect(lambda _: log.close())
