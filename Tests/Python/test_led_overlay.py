"""Synthetic callback tests; never opens the microphone or imports vendor code."""
import importlib.util
from pathlib import Path
import unittest


PATH = Path(__file__).resolve().parents[2] / "firmware/fxmic/led_feedback.py"
SPEC = importlib.util.spec_from_file_location("led_feedback", PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
TICK = 3 << 16


class UI:
    def __init__(self, mic):
        self.mic = mic
        self.delegate = None
        self.fail_leds = 0
        self.fail_callback = False
        self.callback_failures = 0
        self.partial_callback = False
        self.callback_calls = []

    def callback(self, callback):
        self.callback_calls.append(callback)
        if self.fail_callback or self.callback_failures:
            if self.callback_failures:
                self.callback_failures -= 1
            if self.partial_callback:
                self.delegate = callback
            raise RuntimeError("callback unavailable")
        self.delegate = callback

    def leds(self, fx, sample):
        self.mic.events.append(("led", fx, sample))
        if self.fail_leds:
            self.fail_leds -= 1
            raise RuntimeError("LED writer failed")


class Mic:
    def __init__(self, fx=-1, held=False):
        self.fx_pos = fx
        self.sam_pos = 0
        self.fx_primed = self.sam_primed = 0
        self.tick_no = 0
        self.handle_down = self.next_held = held
        self.canceled_this_squeeze = False
        self.events = []
        self.ui = UI(self)

    def python_callback(self, message):
        self.events.append(("original", message))
        if message >> 16 != 3:
            return
        self.tick_no += 1
        self.handle_down = self.next_held
        if self.fx_primed:
            self.fx_primed -= 1
            if not self.fx_primed:
                self.fx_pos = -1 if self.fx_pos == 3 else self.fx_pos + 1
                self.ui.leds(self.fx_pos, self.sam_pos)
        if self.sam_primed:
            self.sam_primed -= 1
            if not self.sam_primed:
                # The installed script pins sample selection to its first slot.
                self.sam_pos = 0
                self.ui.leds(self.fx_pos, self.sam_pos)

    def tick(self, held=None):
        if held is not None:
            self.next_held = held
        self.ui.delegate(TICK)

    def writes(self):
        return [event[1:] for event in self.events if event[0] == "led"]


class LEDOverlayTests(unittest.TestCase):
    def ready(self, fx=-1):
        mic = Mic(fx)
        overlay = MODULE.install(mic)
        mic.tick(False)
        return mic, overlay

    def test_install_is_explicit_inert_and_idempotent(self):
        mic = Mic()
        self.assertIsNone(mic.ui.delegate)
        original = mic.python_callback
        overlay = MODULE.install(mic)
        self.assertEqual(mic.events, [])
        self.assertIs(MODULE.install(mic), overlay)
        self.assertIs(mic.ui.delegate, overlay.callback)
        self.assertEqual(len(mic.ui.callback_calls), 1)
        self.assertEqual(mic.python_callback, original)

    def test_original_receives_all_events_before_feedback(self):
        mic, _ = self.ready()
        messages = [(1 << 16) | 2, (2 << 16) | 1, (4 << 16) | 1, TICK]
        mic.next_held = True
        mic.events.clear()
        for message in messages:
            mic.ui.delegate(message)
        self.assertEqual(mic.events, [("original", m) for m in messages] + [("led", -1, 1)])

    def test_hold_release_pulse_and_restore(self):
        mic, _ = self.ready()
        for _ in range(100):
            mic.tick(True)
        self.assertEqual(mic.writes(), [(-1, 1)])
        mic.tick(False)
        for _ in range(11):
            mic.tick(False)
        self.assertEqual(mic.writes(), [(-1, 1), (-1, 2)])
        mic.tick(False)
        for _ in range(100):
            mic.tick(False)
        self.assertEqual(mic.writes(), [(-1, 1), (-1, 2), (-1, 0)])

    def test_preserves_every_effect_index(self):
        for fx in range(-1, 4):
            with self.subTest(fx=fx):
                mic, _ = self.ready(fx)
                mic.tick(True)
                mic.tick(False)
                for _ in range(12):
                    mic.tick(False)
                self.assertEqual(mic.writes(), [(fx, 1), (fx, 2), (fx, 0)])
                self.assertEqual((mic.fx_pos, mic.sam_pos), (fx, 0))

    def test_effect_selection_wins_and_new_squeeze_uses_new_effect(self):
        mic, _ = self.ready()
        mic.tick(True)
        mic.fx_primed = 1
        mic.tick(True)
        for held in (True, False, False):
            mic.tick(held)
        self.assertEqual(mic.writes(), [(-1, 1), (0, 0)])
        mic.tick(True)
        self.assertEqual(mic.writes()[-1], (0, 1))

    def test_same_pair_stock_write_wins_until_next_squeeze(self):
        mic, _ = self.ready()
        mic.tick(True)
        mic.sam_primed = 1
        mic.tick(True)
        for held in (True, False, False):
            mic.tick(held)
        self.assertEqual(mic.writes(), [(-1, 1), (-1, 0)])
        mic.tick(True)
        self.assertEqual(mic.writes()[-1], (-1, 1))

    def test_same_pair_stock_write_cancels_release_pulse(self):
        mic, _ = self.ready()
        mic.tick(True)
        mic.tick(False)
        mic.sam_primed = 1
        mic.tick(False)
        for _ in range(20):
            mic.tick(False)
        self.assertEqual(mic.writes(), [(-1, 1), (-1, 2), (-1, 0)])

    def test_enable_waits_out_already_held_and_first_refreshed_handle(self):
        for initial_held in (False, True):
            with self.subTest(initial_held=initial_held):
                mic = Mic(held=initial_held)
                MODULE.install(mic)
                for held in (True, True, False):
                    mic.tick(held)
                self.assertEqual(mic.writes(), [])
                mic.tick(True)
                self.assertEqual(mic.writes(), [(-1, 1)])

    def test_repress_replaces_release_pulse(self):
        mic, _ = self.ready()
        for held in (True, False, True):
            mic.tick(held)
        for _ in range(20):
            mic.tick(True)
        self.assertEqual(mic.writes(), [(-1, 1), (-1, 2), (-1, 1)])

    def test_cancel_restores_and_suppresses_until_release(self):
        mic, _ = self.ready()
        mic.tick(True)
        mic.canceled_this_squeeze = True
        for held in (True, True, False):
            mic.tick(held)
        self.assertEqual(mic.writes(), [(-1, 1), (-1, 0)])
        mic.canceled_this_squeeze = False
        mic.tick(True)
        self.assertEqual(mic.writes()[-1], (-1, 1))

    def test_writer_failure_disables_with_one_restore_and_original_continues(self):
        for failures in (1, 2):
            with self.subTest(failures=failures):
                mic, overlay = self.ready()
                mic.ui.fail_leds = failures
                for _ in range(50):
                    before = len(mic.writes())
                    mic.tick(True)
                    self.assertLessEqual(len(mic.writes()) - before, 1)
                self.assertFalse(overlay.enabled)
                self.assertEqual(mic.writes(), [(-1, 1), (-1, 0)])
                self.assertEqual(len([e for e in mic.events if e[0] == "original"]), 51)
                self.assertIs(MODULE.install(mic), overlay)  # No automatic fault retry.

    def test_stock_write_replaces_pending_failure_restore(self):
        mic, overlay = self.ready()
        mic.ui.fail_leds = 1
        mic.tick(True)
        mic.fx_primed = 1
        mic.tick(True)
        mic.tick(True)
        self.assertFalse(overlay.enabled)
        self.assertEqual(mic.writes(), [(-1, 1), (0, 0)])

    def test_remove_restores_current_stock_and_original_callback(self):
        mic, overlay = self.ready()
        mic.tick(True)
        mic.fx_pos = 2
        MODULE.remove(mic)
        self.assertEqual(mic.writes(), [(-1, 1), (2, 0)])
        self.assertEqual(mic.ui.delegate, mic.python_callback)
        self.assertIsNone(mic._ep_led_feedback)
        mic.tick(True)
        MODULE.remove(mic)
        self.assertEqual(mic.writes(), [(-1, 1), (2, 0)])
        self.assertIsNot(MODULE.install(mic), overlay)

    def test_remove_still_detaches_if_led_restoration_fails(self):
        mic, overlay = self.ready()
        mic.tick(True)
        mic.ui.fail_leds = 1
        MODULE.remove(mic)
        self.assertEqual(mic.ui.delegate, mic.python_callback)
        self.assertEqual(overlay.last_error, "restore_failed")

    def test_partial_registration_failure_restores_original_and_is_retryable(self):
        mic = Mic()
        mic.ui.callback_failures = 1
        mic.ui.partial_callback = True
        with self.assertRaises(RuntimeError):
            MODULE.install(mic)
        self.assertIsNone(mic._ep_led_feedback)
        self.assertEqual(mic.ui.delegate, mic.python_callback)
        self.assertEqual(mic.events, [])
        self.assertIsInstance(MODULE.install(mic), MODULE.LEDOverlay)

    def test_failed_registration_rollback_keeps_disabled_recovery_handle(self):
        mic = Mic()
        mic.ui.fail_callback = True
        with self.assertRaisesRegex(RuntimeError, "rollback failed"):
            MODULE.install(mic)
        overlay = mic._ep_led_feedback
        self.assertFalse(overlay.enabled)
        self.assertEqual(overlay.last_error, "callback_restore_failed")
        self.assertIs(MODULE.install(mic), overlay)
        mic.ui.fail_callback = False
        self.assertTrue(MODULE.remove(mic))
        self.assertEqual(mic.ui.delegate, mic.python_callback)

    def test_failed_removal_keeps_disabled_recovery_handle(self):
        mic, overlay = self.ready()
        mic.tick(True)
        mic.ui.fail_callback = True
        with self.assertRaises(RuntimeError):
            MODULE.remove(mic)
        self.assertIs(mic._ep_led_feedback, overlay)
        self.assertFalse(overlay.enabled)
        self.assertEqual(overlay.last_error, "callback_restore_failed")
        mic.ui.fail_callback = False
        self.assertTrue(MODULE.remove(mic))
        self.assertEqual(mic.writes()[-1], (-1, 0))

    def test_stale_handle_cannot_remove_new_installation(self):
        mic, old = self.ready()
        old.remove()
        new = MODULE.install(mic)
        self.assertFalse(old.remove())
        self.assertIs(mic._ep_led_feedback, new)
        self.assertIs(mic.ui.delegate, new.callback)

    def test_invalid_state_is_rejected_before_callback_registration(self):
        for name, value in (("fx_pos", -2), ("sam_pos", -1), ("fx_primed", None),
                            ("sam_primed", -1), ("tick_no", True),
                            ("handle_down", 0), ("canceled_this_squeeze", None),
                            ("python_callback", None)):
            with self.subTest(name=name):
                mic = Mic()
                setattr(mic, name, value)
                with self.assertRaises(ValueError):
                    MODULE.install(mic)
                self.assertEqual(mic.ui.callback_calls, [])

    def test_metadata_failure_does_not_block_original_callback(self):
        mic = Mic()
        mic.python_callback = lambda message: mic.events.append(("original", message))
        overlay = MODULE.install(mic)
        del mic.fx_primed
        mic.ui.delegate(TICK)
        self.assertEqual(mic.events, [("original", TICK)])
        self.assertFalse(overlay.enabled)

    def test_original_callback_error_is_not_hidden(self):
        mic = Mic()
        def original(message):
            raise RuntimeError("original callback error")
        mic.python_callback = original
        MODULE.install(mic)
        with self.assertRaisesRegex(RuntimeError, "original callback error"):
            mic.tick(False)


if __name__ == "__main__":
    unittest.main()
