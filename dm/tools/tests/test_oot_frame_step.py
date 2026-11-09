"""Execute Ocarina's frame-step stub (patches.py frame_step): the host's step × base / 60, never below the measured frame time.

Base 30 is the framework's half rate, two calcs a drawn frame (bit 0 of its +0x24f the mode, bit 1 the calc that is not drawn): each
calc takes half the frame's step, and the frame's vsyncs are counted once. PR #1996 took the step alone there, twice the speed.

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

BASE, FUNC, AREA, STATE, FRAMEWORK = 0x4000000, 0x6e6be0, 0x800000, 0x900000, 0x700000
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


def run(base_rate, game_rate, target, step, seconds, clobber_x17=False, half_rate=0, stepped=0, full=False):
    """One pass of the site. half_rate: the framework's +0x24f (0, or 3 / 1 for the two calcs of a half-rate frame); stepped: the vsyncs counted so far"""
    assert unicorn is not None and arm is not None
    m = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
    m.mem_map(BASE, 0xa00000)
    m.reg_write(arm.UC_ARM64_REG_CPACR_EL1, 3 << 20)   # the FP unit is off at reset
    ctx = Ctx(m)
    profile.frame_step(ctx)
    m.mem_write(BASE + STATE + 0x00, struct.pack('<f', target))
    m.mem_write(BASE + STATE + 0x20, struct.pack('<I', step))
    m.mem_write(BASE + STATE + 0x30, struct.pack('<Q', stepped))
    m.mem_write(BASE + STATE + 0x38, struct.pack('<f', seconds))
    m.mem_write(BASE + FRAMEWORK + 0x24f, bytes([half_rate]))
    m.reg_write(arm.UC_ARM64_REG_X21, BASE + FRAMEWORK)
    m.reg_write(arm.UC_ARM64_REG_S1, f32(base_rate))
    m.reg_write(arm.UC_ARM64_REG_S0, f32(game_rate))
    if clobber_x17:
        def after_store(uc, access, address, size, value, data):   # the rewriter's store sequence may leave x17 = 0
            uc.reg_write(arm.UC_ARM64_REG_X17, 0)
        m.hook_add(unicorn.UC_HOOK_MEM_WRITE, after_store)
    m.emu_start(BASE + SITE, BASE + SITE + 4, count=64)
    ratio = struct.unpack('<f', struct.pack('<I', m.reg_read(arm.UC_ARM64_REG_S8) & 0xffffffff))[0]
    mark = struct.unpack('<I', m.mem_read(BASE + STATE + 0x3c, 4))[0]
    if full: return ratio, struct.unpack('<Q', m.mem_read(BASE + STATE + 0x30, 8))[0]
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

    def test_half_rate_takes_half_the_step_at_each_of_its_two_calcs(self):
        for step in (1, 2, 3):   # 30 / 30 = 1 twice a frame on the console; here the two calcs of a frame add up to its step
            first, stepped = run(30.0, 30.0, 60.0, step, 0.0, half_rate=3, full=True)
            self.assertEqual(first, step / 2)
            self.assertEqual(stepped, 0)   # the calc that is not drawn does not count the frame's vsyncs
            second, stepped = run(30.0, 30.0, 60.0, step, 0.0, half_rate=1, stepped=stepped, full=True)
            self.assertEqual(first + second, step)
            self.assertEqual(stepped, step)   # counted once, at the drawn calc

    def test_full_rate_counts_every_calc(self):
        _, stepped = run(60.0, 60.0, 60.0, 2, 0.0, stepped=7, full=True)
        self.assertEqual(stepped, 9)

    def test_half_rate_frame_time_is_halved_too(self):   # a 50 ms frame is 3 vsyncs: 1.5 at each calc
        for bits in (3, 1):
            self.assertAlmostEqual(run(30.0, 30.0, 60.0, 2, 0.05, half_rate=bits)[0], 1.5, places=5)

    def test_half_rate_survives_x17_lost_after_a_store(self):
        for bits in (3, 1):
            ratio, mark, pc = run(30.0, 30.0, 60.0, 2, 0.0, clobber_x17=True, half_rate=bits)
            self.assertEqual((ratio, mark, pc), (1.0, 1, BASE + SITE + 4))

    def test_target_zero_runs_the_games_division(self):
        ratio, _, pc = run(60.0, 30.0, 0.0, 0, 0.0)
        self.assertEqual(ratio, 2.0)
        self.assertEqual(pc, BASE + SITE + 4)

    def test_step_not_decided_yet_runs_the_games_division(self):   # the first frames: the phone faulted here
        ratio, _, pc = run(60.0, 30.0, 60.0, 0, 0.0)
        self.assertEqual(ratio, 2.0)
        self.assertEqual(pc, BASE + SITE + 4)


HALF_FUNC, MODULE = 0x650d00, 0x710000   # the function of the half-rate request (the site at +0x1a4) and a ModuleSystem (x19)


def ask(own, host):
    """The request the game writes to the framework's +0x24e (2 = enter the half rate, 1 = leave), for its own flags at [x19+0xa30] and the host's ask at state +0x44"""
    assert unicorn is not None and arm is not None
    m = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
    m.mem_map(BASE, 0xa00000)
    ctx = Ctx(m)
    ctx.others['half rate request'] = HALF_FUNC
    profile.half_rate(ctx)
    site = HALF_FUNC + 0x1a4
    assert ctx.sites == {site: '68324ab9'} and 'HALF_RATE' in ctx.capabilities
    m.mem_write(BASE + site + 4, struct.pack('<3I', 0x7200011f, 0x52800028, 0x1a880508))   # the game's own words: tst w8,#1; mov w8,#1; cinc w8,w8,ne
    m.mem_write(BASE + MODULE + 0xa30, struct.pack('<I', own))
    m.mem_write(BASE + STATE + 0x44, struct.pack('<I', host))
    m.reg_write(arm.UC_ARM64_REG_X19, BASE + MODULE)
    m.emu_start(BASE + site, BASE + site + 16, count=32)
    return m.reg_read(arm.UC_ARM64_REG_X8) & 0xffffffff


@unittest.skipIf(unicorn is None, 'optional ARM64 execution dependency: unicorn')
class HalfRate(unittest.TestCase):
    def test_the_games_own_flag_still_decides_without_an_ask(self):
        self.assertEqual(ask(0, 0), 1)
        self.assertEqual(ask(1, 0), 2)
        self.assertEqual(ask(0xfffffffe, 0), 1)   # its other flags are not the request

    def test_the_hosts_ask_enters_the_half_rate(self):
        self.assertEqual(ask(0, 1), 2)
        self.assertEqual(ask(0xfffffffe, 1), 2)
        self.assertEqual(ask(1, 1), 2)

    def test_no_stub_without_the_function(self):
        ctx = Ctx(None)
        profile.half_rate(ctx)   # the locator did not find it: nothing is written
        self.assertEqual((ctx.sites, ctx.cursor, ctx.capabilities), ({}, AREA, set()))


if __name__ == '__main__':
    unittest.main()
