# gdb script: hold the original still at an exact game step so the frame it is
# showing can be photographed.
#
# The game loop is
#     Process_StartFrame -> FUN_00420280 (one step) -> time += 1
#     -> build draw lists -> Process_EndFrame (composite and flip)
# so at the top of FUN_00420280 the screen holds the frame built from the state
# after the previous step, while DAT_004e4836 reads the step about to run.
# Our own renderer screenshots at exactly the same point: after building the
# frame for `time`, before stepping it. The two are therefore comparable.
#
# While a breakpoint handler runs, the inferior stays stopped -- so the handler
# writes a marker file, waits for the shell outside to replace it, and only
# then lets the game go on.
import os
import time as clock

import gdb

STEP_FN = 0x420280  # FUN_00420280, one game step
SRAND = 0x461620
GAME_TIME = 0x4E4836  # DAT_004e4836
# Background state, logged beside each capture so the screenshot can be
# checked against what the game thought it was drawing.
BGND = {
    "view_top": 0x4DE6F4,
    "view_bottom": 0x4DE6FC,
    "map_bottom": 0x4DE6EC,
    "progress": 0x4DE704,
    "speed": 0x4DE708,
    "side_scroll": 0x4DE70D,
}

# The shipped demos, by the seed each one srands with.
DEMO_SEEDS = {1: 289218, 2: 325205, 3: 347267, 4: 372717}

out_dir = gdb.convenience_variable("shot_dir").string()
want_demo = int(gdb.convenience_variable("shot_demo") or 1)
want = sorted(int(s) for s in gdb.convenience_variable("shot_steps").string().split(",") if s.strip())
log = open(os.path.join(out_dir, "shot.log"), "w", buffering=1)
inferior = gdb.selected_inferior()
state = {"active": False, "left": list(want)}


def u32(addr):
    return int.from_bytes(bytes(inferior.read_memory(addr, 4)), "little")


def s32(v):
    return v - (1 << 32) if v & 0x80000000 else v


class Srand(gdb.Breakpoint):
    def __init__(self):
        super().__init__(f"*{SRAND:#x}", internal=True)

    def stop(self):
        esp = int(gdb.parse_and_eval("$esp")) & 0xFFFFFFFF
        seed = u32(esp + 4)
        state["active"] = seed == DEMO_SEEDS.get(want_demo)
        log.write(f"srand {seed} active={state['active']}\n")
        return False


class Step(gdb.Breakpoint):
    def __init__(self):
        super().__init__(f"*{STEP_FN:#x}", internal=True)

    def stop(self):
        if not state["active"] or not state["left"]:
            return False
        t = u32(GAME_TIME)
        if t != state["left"][0]:
            return False
        state["left"].pop(0)
        fields = " ".join(f"{k}={s32(u32(a))}" for k, a in BGND.items())
        log.write(f"step {t}: {fields}\n")
        ready = os.path.join(out_dir, f"at-{t:05d}.ready")
        done = ready[: -len(".ready")] + ".done"
        open(ready, "w").close()
        log.write(f"holding at step {t}\n")
        for _ in range(600):  # up to a minute
            if os.path.exists(done):
                break
            clock.sleep(0.1)
        log.write(f"released at step {t}\n")
        if not state["left"]:
            open(os.path.join(out_dir, "finished"), "w").close()
        return False


Srand()
Step()
log.write(f"waiting for demo {want_demo} at steps {want}\n")
