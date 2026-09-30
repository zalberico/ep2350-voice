"""Offline contract tests. Numeric pairs are simulation fixtures, not device claims."""
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "device_feedback", ROOT / "firmware/fxmic/feedback.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
LEDFeedback = MODULE.LEDFeedback

STOCK = (0, 0)
HELD = (0, 1)
RELEASE = (0, 2)
OTHER_STOCK = (0, 3)
PAIRS = (STOCK, HELD, RELEASE, OTHER_STOCK)


class DeviceFeedbackTests(unittest.TestCase):
    def make_feedback(self, **overrides):
        self.writes = []
        options = dict(write_leds=lambda *pair: self.writes.append(pair),
                       stock_pair=STOCK, held_pair=HELD, release_pair=RELEASE,
                       allowed_pairs=PAIRS, release_ticks=3, enabled=True)
        options.update(overrides)
        return LEDFeedback(**options)

    def test_disabled_by_default_never_writes(self):
        self.writes = []
        feedback = LEDFeedback(lambda *pair: self.writes.append(pair), STOCK,
                               HELD, RELEASE, PAIRS)
        for held in (True, False, True, False):
            feedback.tick(held)
        self.assertFalse(feedback.enabled)
        self.assertEqual(self.writes, [])

    def test_steady_hold_release_pulse_then_restores_stock(self):
        feedback = self.make_feedback()
        feedback.tick(True)
        for _ in range(1000):
            feedback.tick(True)
        self.assertEqual(self.writes, [HELD])
        feedback.tick(False)
        for _ in range(2):
            feedback.tick(False)
        self.assertEqual(self.writes, [HELD, RELEASE])
        feedback.tick(False)
        for _ in range(1000):
            feedback.tick(False)
        self.assertEqual(self.writes, [HELD, RELEASE, STOCK])
        self.assertEqual(feedback.phase, "idle")

    def test_restores_clean_effect_stock_index(self):
        stock, held, released = (-1, 0), (-1, 1), (-1, 2)
        feedback = self.make_feedback(stock_pair=stock, held_pair=held,
                                      release_pair=released,
                                      allowed_pairs=(stock, held, released))
        feedback.tick(True)
        feedback.tick(False)
        for _ in range(3):
            feedback.tick(False)
        self.assertEqual(self.writes, [held, released, stock])
        self.assertEqual(feedback.last_pair, stock)
        self.assertEqual(feedback.phase, "idle")

    def test_all_evidenced_stock_combinations_can_be_whitelisted_and_restored(self):
        pairs = tuple((fx, sample) for fx in range(-1, 4) for sample in range(4))
        self.assertEqual(len(pairs), 20)
        for stock in pairs:
            with self.subTest(stock=stock):
                held = (stock[0], (stock[1] + 1) % 4)
                released = (stock[0], (stock[1] + 2) % 4)
                feedback = self.make_feedback(stock_pair=stock, held_pair=held,
                                              release_pair=released, allowed_pairs=pairs)
                self.assertTrue(feedback.enabled)
                feedback.tick(True)
                feedback.tick(False)
                for _ in range(3):
                    feedback.tick(False)
                self.assertEqual(self.writes, [held, released, stock])
                self.assertEqual(feedback.last_pair, stock)

    def test_whitelist_cannot_admit_indices_outside_evidenced_range(self):
        for pair in ((-2, 0), (4, 0), (0, -1), (0, 4)):
            with self.subTest(pair=pair):
                feedback = self.make_feedback(stock_pair=pair,
                                              allowed_pairs=(pair, HELD, RELEASE))
                feedback.tick(True)
                self.assertFalse(feedback.enabled)
                self.assertEqual(feedback.last_error, "invalid_configuration")
                self.assertEqual(self.writes, [])

    def test_repress_replaces_pending_release(self):
        feedback = self.make_feedback()
        for held in (True, False, False, True, True):
            feedback.tick(held)
        self.assertEqual(self.writes, [HELD, RELEASE, HELD])
        self.assertEqual(feedback.phase, "held")

    def test_cancel_restores_and_suppresses_until_release(self):
        feedback = self.make_feedback()
        feedback.tick(True)
        feedback.tick(True, canceled=True)
        for held in (True, True, False, False):
            feedback.tick(held)
        self.assertEqual(self.writes, [HELD, STOCK])
        feedback.tick(True)
        self.assertEqual(self.writes, [HELD, STOCK, HELD])

    def test_cancel_during_release_restores_immediately(self):
        feedback = self.make_feedback()
        feedback.tick(True)
        feedback.tick(False)
        feedback.tick(False, canceled=True)
        self.assertEqual(self.writes, [HELD, RELEASE, STOCK])
        self.assertEqual(feedback.phase, "idle")

    def test_stock_update_wins_and_future_restore_uses_new_stock(self):
        feedback = self.make_feedback()
        feedback.tick(True)
        feedback.stock_changed(OTHER_STOCK)  # Stock writer already took over.
        for held in (True, True, False, False):
            feedback.tick(held)
        self.assertEqual(self.writes, [HELD])
        feedback.tick(True)
        feedback.tick(False)
        for _ in range(3):
            feedback.tick(False)
        self.assertEqual(self.writes, [HELD, HELD, RELEASE, OTHER_STOCK])

    def test_stock_update_cancels_release_or_pending_restore(self):
        for release_first in (False, True):
            with self.subTest(release_first=release_first):
                feedback = self.make_feedback()
                feedback.tick(True)
                if release_first:
                    feedback.tick(False)
                feedback.set_enabled(False)
                feedback.stock_changed(OTHER_STOCK)
                previous = list(self.writes)
                for _ in range(5):
                    feedback.tick(False)
                self.assertEqual(self.writes, previous)
                self.assertEqual(feedback.last_pair, OTHER_STOCK)

    def test_disable_restores_once_and_enable_waits_out_held_handle(self):
        feedback = self.make_feedback()
        feedback.tick(True)
        feedback.set_enabled(False)
        feedback.tick(True)
        feedback.set_enabled(True)
        feedback.tick(True)
        feedback.tick(False)
        self.assertEqual(self.writes, [HELD, STOCK])
        feedback.tick(True)
        self.assertEqual(self.writes, [HELD, STOCK, HELD])

    def test_enabling_an_enabled_overlay_is_idempotent(self):
        feedback = self.make_feedback()
        feedback.tick(True)
        feedback.set_enabled(True)
        feedback.tick(False)
        for _ in range(3):
            feedback.tick(False)
        self.assertEqual(self.writes, [HELD, RELEASE, STOCK])

    def test_stock_write_during_release_ends_the_pulse(self):
        feedback = self.make_feedback()
        feedback.tick(True)
        feedback.tick(False)
        feedback.stock_changed(OTHER_STOCK)
        for _ in range(20):
            feedback.tick(False)
        self.assertEqual(self.writes, [HELD, RELEASE])
        self.assertEqual(feedback.last_pair, OTHER_STOCK)
        self.assertEqual(feedback.phase, "idle")

    def test_stock_write_before_first_held_tick_wins_that_squeeze(self):
        feedback = self.make_feedback()
        feedback.stock_changed(OTHER_STOCK)
        for held in (True, True, False, False):
            feedback.tick(held)
        self.assertEqual(self.writes, [])
        self.assertEqual(feedback.last_pair, OTHER_STOCK)
        feedback.tick(True)
        self.assertEqual(self.writes, [HELD])

    def test_writer_failure_does_not_escape_or_retry_forever(self):
        attempted = []

        def broken_writer(*pair):
            attempted.append(pair)
            raise RuntimeError("simulated LED failure")

        feedback = self.make_feedback(write_leds=broken_writer)
        feedback.tick(True)
        self.assertEqual(attempted, [HELD])
        feedback.tick(True)  # Exactly one best-effort restoration.
        for _ in range(1000):
            feedback.tick(True)
        self.assertEqual(attempted, [HELD, STOCK])
        self.assertFalse(feedback.enabled)
        self.assertFalse(feedback.set_enabled(True))
        self.assertEqual(feedback.last_error, "restore_failed")
        self.assertIsNone(feedback.last_pair)

    def test_failure_can_restore_but_remains_disabled(self):
        attempted = []

        def partial_failure(*pair):
            attempted.append(pair)
            if pair == HELD:
                raise RuntimeError("simulated write failure")

        feedback = self.make_feedback(write_leds=partial_failure)
        feedback.tick(True)
        feedback.tick(False)
        self.assertEqual(attempted, [HELD, STOCK])
        self.assertEqual(feedback.last_pair, STOCK)
        self.assertFalse(feedback.enabled)
        self.assertEqual(feedback.last_error, "writer_failed")

    def test_unverified_stock_update_disables_without_stale_restore(self):
        feedback = self.make_feedback()
        feedback.tick(True)
        feedback.stock_changed((99, 99))
        feedback.tick(False)
        self.assertEqual(self.writes, [HELD])
        self.assertFalse(feedback.enabled)
        self.assertEqual(feedback.last_error, "unverified_stock_pair")

    def test_invalid_input_latches_off_and_restores_next_valid_tick(self):
        feedback = self.make_feedback()
        feedback.tick(True)
        feedback.tick("held")
        self.assertEqual(self.writes, [HELD])
        feedback.tick(False)
        self.assertEqual(self.writes, [HELD, STOCK])
        self.assertFalse(feedback.enabled)

    def test_invalid_configuration_is_inert(self):
        cases = [
            {"allowed_pairs": ()}, {"allowed_pairs": PAIRS * 6},
            {"allowed_pairs": iter(PAIRS)}, {"held_pair": (99, 99)},
            {"held_pair": STOCK}, {"release_ticks": 0},
            {"release_ticks": 121}, {"release_ticks": True},
            {"enabled": "yes"}, {"write_leds": None},
            {"stock_pair": (False, 0)}, {"stock_pair": (-1, 0)},
        ]
        for options in cases:
            with self.subTest(options=options):
                feedback = self.make_feedback(**options)
                feedback.tick(True)
                feedback.tick(False)
                self.assertEqual(self.writes, [])
                self.assertFalse(feedback.set_enabled(True))
                self.assertEqual(feedback.last_error, "invalid_configuration")

    def test_at_most_one_write_per_tick(self):
        feedback = self.make_feedback()
        for held, canceled in ((True, False), (False, False), (True, True),
                               (False, False), (True, False), (False, False)):
            before = len(self.writes)
            feedback.tick(held, canceled)
            self.assertLessEqual(len(self.writes) - before, 1)


if __name__ == "__main__":
    unittest.main()
