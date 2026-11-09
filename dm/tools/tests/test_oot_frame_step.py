"""Execute Ocarina's frame-step stub (patches.py frame_step): the host's step × base / 60, never below the measured frame time.

Runs the emitted code under Unicorn. In the rewritten code x17 is the rewriter's scratch, so it does not survive a store: an
iPhone 18 Pro Max faulted at x17 + 0x3c with x17 = 0 on the first frame when the measured-time block addressed the state page
through x17. The `clobber_x17` runs zero x17 after every store, as the rewriter can, so a stub that relies on it fails here.
"""
import importlib
import importlib.util
from pathlib import Path
import struct
import sys
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))

spec = importlib.util.spec_from_file_location('oot_patches', REPO / 'dm/games/0400486024DEC000/patches.py')
assert spec is not None and spec.loader is not None
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
try:
    unicorn = importlib.import_module('unicorn')
    arm = importlib.import_module('unicorn.arm64_const')
except ImportError:
    unicorn = arm = None

BASE, FUNC, AREA, STATE = 0x4000000, 0x6e6be0, 0x800000, 0x900000
SITE = FUNC + 0xe4


class Ctx:
    state = STATE
    base = FUNC

    def __init__(self, machine):
        self.machine, self.cursor, self.sites, self.others, self.capabilities = machine, AREA, {}, {}, set()

    def here(self):
        return self.cursor

    def emit(self, word):
        self.machine.mem_write(BASE + self.cursor, struct.pack('<I', word))
        self.cursor += 4

    def site(self, offset, original):
        self.sites[offset] = original

    def put(self, offset, words, reason):
        self.machine.mem_write(BASE + offset, b''.join(struct.pack('<I', w) for w in words))


def f32(v):
    return struct.unpack('<I', struct.pack('<f', v))[0]


def run(base_rate, game_rate, target, step, seconds, clobber_x17=False):
    assert unicorn is not None and arm is not None
    m = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
    m.mem_map(BASE, 0xa00000)
    m.reg_write(arm.UC_ARM64_REG_CPACR_EL1, 3 << 20)   # the FP unit is off at reset
    ctx = Ctx(m)
    profile.frame_step(ctx)
    m.mem_write(BASE + STATE + 0x00, struct.pack('<f', target))
    m.mem_write(BASE + STATE + 0x20, struct.pack('<I', step))
    m.mem_write(BASE + STATE + 0x38, struct.pack('<f', seconds))
    m.reg_write(arm.UC_ARM64_REG_S1, f32(base_rate))
    m.reg_write(arm.UC_ARM64_REG_S0, f32(game_rate))
    if clobber_x17:
        def after_store(uc, access, address, size, value, data):   # the rewriter's store sequence may leave x17 = 0
            uc.reg_write(arm.UC_ARM64_REG_X17, 0)
        m.hook_add(unicorn.UC_HOOK_MEM_WRITE, after_store)
    m.emu_start(BASE + SITE, BASE + SITE + 4, count=64)
    ratio = struct.unpack('<f', struct.pack('<I', m.reg_read(arm.UC_ARM64_REG_S8) & 0xffffffff))[0]
    mark = struct.unpack('<I', m.mem_read(BASE + STATE + 0x3c, 4))[0]
    return ratio, mark, m.reg_read(arm.UC_ARM64_REG_PC)


@unittest.skipIf(unicorn is None, 'optional ARM64 execution dependency: unicorn')
class FrameStep(unittest.TestCase):
    def test_at_the_target_the_ratio_is_the_hosts_step(self):
        ratio, mark, pc = run(60.0, 60.0, 60.0, 1, 0.0)
        self.assertEqual(ratio, 1.0)
        self.assertEqual(mark, 1)
        self.assertEqual(pc, BASE + SITE + 4)

    def test_a_slow_frame_moves_by_its_time(self):
        self.assertAlmostEqual(run(60.0, 60.0, 60.0, 1, 0.025)[0], 1.5, places=5)
        self.assertAlmostEqual(run(30.0, 30.0, 60.0, 1, 0.05)[0], 1.5, places=5)

    def test_never_below_the_hosts_step(self):
        self.assertEqual(run(60.0, 60.0, 60.0, 2, 0.02)[0], 2.0)

    def test_x17_lost_after_a_store_is_survived(self):
        ratio, mark, pc = run(60.0, 60.0, 60.0, 1, 0.025, clobber_x17=True)
        self.assertAlmostEqual(ratio, 1.5, places=5)
        self.assertEqual(mark, 1)
        self.assertEqual(pc, BASE + SITE + 4)

    def test_target_zero_runs_the_games_division(self):
        ratio, _, pc = run(60.0, 30.0, 0.0, 0, 0.0)
        self.assertEqual(ratio, 2.0)
        self.assertEqual(pc, BASE + SITE + 4)

    def test_step_not_decided_yet_runs_the_games_division(self):   # the first frames: the phone faulted here
        ratio, _, pc = run(60.0, 30.0, 60.0, 0, 0.0)
        self.assertEqual(ratio, 2.0)
        self.assertEqual(pc, BASE + SITE + 4)


if __name__ == '__main__':
    unittest.main()
