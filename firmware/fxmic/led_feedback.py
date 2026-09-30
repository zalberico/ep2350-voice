"""Opt-in LED overlay for the verified 1.1.2 fxmic callback. Import is inert."""


class LEDOverlay:
    def __init__(self, mic):
        self.mic = mic
        self.ui = mic.ui
        self.original = mic.python_callback
        if not all(callable(f) for f in (self.original, self.ui.callback, self.ui.leds)):
            raise ValueError("invalid microphone callbacks")
        for name in ("fx_primed", "sam_primed", "tick_no"):
            value = getattr(mic, name, None)
            if type(value) is not int or value < 0:
                raise ValueError("invalid microphone counters")
        for name in ("handle_down", "canceled_this_squeeze"):
            if type(getattr(mic, name, None)) is not bool:
                raise ValueError("invalid microphone state")
        self.stock = self.pair()
        self.last = self.stock
        self.held = bool(mic.handle_down)
        self.suppressed = True  # Observe release before accepting a squeeze.
        self.left = 0
        self.enabled = True
        self.owned = False
        self.restore = False
        self.last_error = None

    def pair(self):
        a, b = self.mic.fx_pos, self.mic.sam_pos
        if type(a) is not int or type(b) is not int or not (-1 <= a <= 3 and 0 <= b <= 3):
            raise ValueError("invalid stock LED pair")
        return (a, b)

    def write(self, pair):
        if pair != self.last:
            self.owned = True  # A failing write may already have changed LEDs.
            self.ui.leds(*pair)
            self.last = pair
            self.owned = pair != self.stock

    def __call__(self, message):
        tick = stock_write = False
        try:
            tick = message >> 16 == 3
            # The two stock write branches, including same-pair writes.
            stock_write = tick and (self.mic.fx_primed == 1 or self.mic.sam_primed == 1)
        except Exception:
            self.enabled = False
            self.restore = self.owned
            self.last_error = "feedback_failed"
        self.original(message)
        if not tick:
            return
        try:
            stock = self.pair()
            held = bool(self.mic.handle_down)
            was_held, self.held = self.held, held
            if stock_write or stock != self.stock:
                self.stock = self.last = stock
                self.owned = self.restore = False
                self.left = 0
                self.suppressed = held
                return
            if self.restore:
                self.restore = self.owned = False
                try:
                    self.ui.leds(*stock)
                    self.last = stock
                except Exception:
                    self.last = None
                    self.last_error = "restore_failed"
                return
            if not self.enabled:
                return
            if self.suppressed:
                self.suppressed = held
                return
            if held and self.mic.canceled_this_squeeze:
                self.left = 0
                self.suppressed = True
                self.write(stock)
            elif held:
                self.left = 0
                self.write((stock[0], 1))
            elif was_held:
                self.left = 12
                self.write((stock[0], 2))
            elif self.left:
                self.left -= 1
                if not self.left:
                    self.write(stock)
        except Exception:
            self.enabled = False
            self.left = 0
            self.restore = self.owned
            self.last = None
            self.last_error = "feedback_failed"

    def remove(self):
        if getattr(self.mic, "_ep_led_feedback", None) is not self:
            return False
        self.enabled = self.restore = False
        try:
            self.ui.callback(self.original)
        except Exception:
            self.last_error = "callback_restore_failed"
            raise
        if self.owned:
            try:
                self.last = self.pair()
                self.ui.leds(*self.last)
            except Exception:
                self.last = None
                self.last_error = "restore_failed"
        self.owned = False
        self.mic._ep_led_feedback = None
        return True


def install(mic):
    previous = getattr(mic, "_ep_led_feedback", None)
    if previous is not None:
        return previous
    overlay = LEDOverlay(mic)
    # Register a plain function, the same callable kind as the stock callback.
    def callback(message):
        overlay(message)
    overlay.callback = callback
    mic._ep_led_feedback = overlay
    try:
        mic.ui.callback(callback)
    except Exception:
        overlay.enabled = False
        overlay.last_error = "registration_failed"
        try:
            mic.ui.callback(overlay.original)
        except Exception:
            overlay.last_error = "callback_restore_failed"
            raise RuntimeError("callback registration and rollback failed")
        mic._ep_led_feedback = None
        raise
    return overlay


def remove(mic):
    overlay = getattr(mic, "_ep_led_feedback", None)
    if overlay is not None:
        return overlay.remove()
    return False
