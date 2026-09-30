"""Offline LED feedback contract; no device API is imported or called by default.

Do not install this module yet. The device's LED arguments and stock ownership
must be verified before supplying a writer and a whitelist of observed pairs.
"""


class LEDFeedback:
    """Bounded, tick-driven overlay on a two-index stock LED interface.

    ``write_leds(fx_index, sample_index)`` is injected. A caller must independently
    verify every allowed pair on its hardware; this class cannot establish that
    an integer is safe or that it has a particular color. One tick performs at
    most one writer call. No timers, sleeps, threads, or device imports are used.
    """

    MAX_PAIRS = 20
    MAX_RELEASE_TICKS = 120

    def __init__(self, write_leds, stock_pair=None, held_pair=None,
                 release_pair=None, allowed_pairs=(), release_ticks=6,
                 enabled=False):
        self._writer = write_leds
        self._allowed = ()
        self._stock = None
        self._held_pair = None
        self._release_pair = None
        self._release_ticks = 0
        self._release_left = 0
        self._last_pair = None
        self._last_held = False
        self._suppressed = False
        self._stock_pending = False
        self._owns = False
        self._restore_pending = False
        self._enabled = False
        self._faulted = False
        self.phase = "disabled"
        self.last_error = None

        # Do not consume arbitrary iterators or accept an unbounded schedule.
        if (not callable(write_leds)
                or type(allowed_pairs) not in (tuple, list)
                or not 1 <= len(allowed_pairs) <= self.MAX_PAIRS
                or type(release_ticks) is not int
                or not 1 <= release_ticks <= self.MAX_RELEASE_TICKS
                or type(enabled) is not bool):
            self._invalid_configuration()
            return
        for pair in allowed_pairs:
            if not self._is_pair(pair):
                self._invalid_configuration()
                return
        self._allowed = tuple(tuple(pair) for pair in allowed_pairs)
        if not all(self._is_allowed(pair)
                   for pair in (stock_pair, held_pair, release_pair)):
            self._invalid_configuration()
            return
        self._stock = tuple(stock_pair)
        self._held_pair = tuple(held_pair)
        self._release_pair = tuple(release_pair)
        if len(set((self._stock, self._held_pair, self._release_pair))) != 3:
            self._invalid_configuration()
            return
        self._last_pair = self._stock
        self._release_ticks = release_ticks
        self._enabled = enabled
        self.phase = "idle" if enabled else "disabled"

    @property
    def enabled(self):
        return self._enabled

    @property
    def last_pair(self):
        """Last known LED pair, or None after an uncertain failed write."""
        return self._last_pair

    @staticmethod
    def _is_pair(pair):
        return (type(pair) in (tuple, list) and len(pair) == 2
                and all(type(value) is int for value in pair)
                and -1 <= pair[0] <= 3 and 0 <= pair[1] <= 3)

    def _is_allowed(self, pair):
        return self._is_pair(pair) and tuple(pair) in self._allowed

    def _invalid_configuration(self):
        self._faulted = True
        self.last_error = "invalid_configuration"

    def set_enabled(self, enabled):
        """Disabling restores on the next tick; faults require a new instance."""
        if type(enabled) is not bool:
            self._fail("invalid_enabled_value")
            return False
        if enabled and self._enabled:
            return True
        if not enabled:
            self._enabled = False
            self._release_left = 0
            self._restore_pending = self._restore_pending or self._owns
            self.phase = "fault" if self._faulted else "disabled"
            return False
        if self._faulted:
            return False
        self._enabled = True
        # Enabling during a squeeze waits for release and a fresh squeeze.
        self._suppressed = self._last_held
        self.phase = "yielded" if self._suppressed else "idle"
        return True

    def stock_changed(self, pair):
        """Notify AFTER a successful stock LED write; this method never writes.

        Stock controls win. Cancel any overlay/restore and wait out the current
        squeeze, so the next tick cannot overwrite a stock selection or warning.
        Unverified stock arguments latch this component off without restoring a
        now-stale selection.
        """
        self._owns = False
        self._restore_pending = False
        self._release_left = 0
        # The stock write may precede feedback in the very tick that begins a
        # squeeze. Decide suppression from that tick's fresh handle reading.
        self._stock_pending = True
        if not self._is_allowed(pair):
            self._last_pair = None
            self._fail("unverified_stock_pair")
            return
        self._stock = tuple(pair)
        self._last_pair = self._stock
        if self._enabled:
            self.phase = "yielded" if self._suppressed else "idle"

    def tick(self, held, canceled=False):
        """Call once from an existing tick AFTER audio/marker processing.

        Held: one steady selection. Release: one bounded pulse, then stock.
        Cancel: restore immediately and suppress feedback until release.
        A failing writer is swallowed and disabled; one restoration attempt is
        permitted on the following tick, with no further automatic retries.
        """
        if type(held) is not bool or type(canceled) is not bool:
            self._fail("invalid_input")
            return
        was_held = self._last_held
        self._last_held = held
        if self._stock_pending:
            self._stock_pending = False
            self._suppressed = held
            if self._enabled:
                self.phase = "yielded" if held else "idle"
            return
        if self._restore_pending:
            self._restore_pending = False
            self._restore_once()
            return
        if not self._enabled:
            return
        if canceled:
            self._release_left = 0
            self._suppressed = held
            self.phase = "canceled" if held else "idle"
            self._restore_if_owned()
            return
        if self._suppressed:
            if not held:
                self._suppressed = False
                self.phase = "idle"
            return
        if held:
            self._release_left = 0
            self.phase = "held"
            self._write_if_changed(self._held_pair)
            return
        if was_held:
            self.phase = "release"
            self._release_left = self._release_ticks
            self._write_if_changed(self._release_pair)
            return
        if self._release_left:
            self._release_left -= 1
            if not self._release_left:
                self.phase = "idle"
                self._restore_if_owned()

    def _write_if_changed(self, pair):
        if pair == self._last_pair:
            return
        try:
            self._writer(pair[0], pair[1])
        except Exception:
            self._last_pair = None
            # A writer may have changed the LEDs before raising.
            self._owns = True
            self._fail("writer_failed")
            return
        self._last_pair = pair
        self._owns = pair != self._stock

    def _restore_if_owned(self):
        if self._owns:
            self._write_if_changed(self._stock)

    def _restore_once(self):
        self._owns = False
        try:
            self._writer(self._stock[0], self._stock[1])
        except Exception:
            self._last_pair = None
            self.last_error = "restore_failed"
            self._enabled = False
            self._faulted = True
            self.phase = "fault"
            return
        self._last_pair = self._stock

    def _fail(self, reason):
        self._enabled = False
        self._faulted = True
        self._release_left = 0
        self._restore_pending = self._restore_pending or self._owns
        self.last_error = reason
        self.phase = "fault"
