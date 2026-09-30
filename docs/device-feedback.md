# Device LED feedback: offline foundation

`firmware/fxmic/feedback.py` is a disabled-by-default, injectable state machine.
It is **not integrated with the microphone startup script, installed on the
microphone, or verified on hardware**. `tools/build_fxmic_script.py` and the
installer are unchanged. Existing firmware and startup behavior are unaffected.
The index-range correction described below changes source on the Mac only; it
does not change the installed microphone's LED behavior. No USB microphone was
connected during this correction or its offline tests.

## Evidence and limits

A privately extracted vendor startup script for firmware 1.1.2 and a local
custom-script snapshot were inspected. The custom snapshot's 9,311 bytes and
SHA-256 matched its saved installation manifest. Those files are not distributed
in this repository, and the match does not establish the current contents of a
disconnected microphone.

The original initializes `fx_pos = -1` and `sam_pos = 0`, calls
`ui.leds(fx_pos,sam_pos)`, cycles effect indices through -1 to 3, and cycles sample
indices through 0 to 3. These are the 20 combinations reachable through stock
selection. The custom snapshot retains the effect range and pins sample
selection to 0. Three Python LED call sites were found: initialization, effect
selection, and sample selection. Effect loading and sample triggering use
separate calls. Existing custom code reads `ui.handle()` on tick messages.

This evidence establishes the two-index call and stock argument ranges. In
particular, -1 must be accepted for the clean effect state. It does not establish
LED colors, brightness control, refresh ownership within the compiled firmware,
or whether chosen pairs make distinct visible patterns. The device API
implementation has not been inspected. No arbitrary RGB control is assumed.

The official [FX-MIC guide](https://teenage.engineering/guides/ep-2350) describes
orange effect selection, white sample selection, and grey sample triggering.
The [TING guide](https://teenage.engineering/guides/ep-2350/ting) describes orange,
green, and white for those functions. The state machine assigns no behavior by
button color and changes no button mappings.

Microphone markers currently travel through the line output to the Mac. Neither
this module nor the app implements a live Mac-to-device status channel. The USB
raw REPL tool is a development tool, not a tested live status protocol. Thinking,
assistant speaking, connected, and native ChatGPT Voice states cannot be shown
honestly on device LEDs from this implementation.

## Contract

A future integration supplies a `write_leds(fx_index, sample_index)` callable,
the current stock pair, distinct held and release pairs, and a finite whitelist
of **independently verified** pairs. Effect indices must be integers from -1 to
3 and sample indices must be integers from 0 to 3. The whitelist is mandatory;
being inside those ranges does not establish a useful visual pattern. This module
cannot verify its contents. Test fixture numbers are simulation inputs only and
must not be copied to hardware as a calibration. Missing or invalid
configuration stays disabled and performs no writes.

After construction, a caller explicitly enables the component. It calls
`tick(held, canceled=False)` once per existing device tick, after audio and marker
processing. The component never creates a timer or loop, sleeps, imports device
APIs, or accesses USB. Each tick makes at most one writer call. The injected
writer must itself be nonblocking; synchronous code cannot impose a time bound
on an arbitrary callback.

| Event | Simulated behavior |
| --- | --- |
| Squeeze | Select the verified held pair once; hold it without repeated writes. |
| Release | Select the verified release pair once, then restore stock after the configured number of subsequent ticks. |
| Squeeze during release pulse | Replace the pulse with held state. |
| Cancel | Restore stock; suppress further feedback until the handle is released. |
| Disable | Restore on the next tick, then remain inactive. |
| Enable during squeeze | Wait for release and a fresh squeeze. |
| Stock LED update | Yield immediately; cancel pending pulse/restoration and wait out the current squeeze. |
| Writer exception | Swallow the exception, latch feedback off, and attempt restoration once on the next tick. |

The default release duration is six tick intervals; it is deliberately not
described in milliseconds until the device callback cadence is measured. The
duration is bounded to 1–120 ticks. There are at most 20 whitelisted pairs. Earlier
prototype notes describe an approximately 60 Hz callback; its cadence has not
been measured on the currently installed microphone in this work.

`stock_changed(pair)` must be called **after every successful stock LED write**.
It does not write LEDs itself. A later restoration uses that latest stock pair.
The following tick uses its current handle reading to decide whether to suppress
the entire squeeze, including when a stock write happens just before that
squeeze's first tick.
An unverified stock pair disables feedback without restoring an obsolete
selection. This contract requires a complete audit of stock LED writers before
hardware integration; it cannot protect a stock warning it was never told about.

`last_error` exposes configuration, input, writer, or restoration failure.
Exceptions from the injected LED writer do not escape into audio processing.
After a fault, automatic retries stop and enabling the same instance is refused.
A fresh, validated instance is needed to recover. If the one restoration attempt
fails, physical LED state is unknown (`last_pair` is `None`). A successful restore
after a failed write still leaves feedback disabled. LED failures cannot prove
anything about whether recording is healthy.

## Offline validation

Run from the repository root:

```sh
python3 -m unittest discover -s Tests/Python -p 'test_device_feedback.py' -v
```

These tests exercise held/release timing, repress, cancel, stock ownership,
restoration of the clean effect state and all 20 stock index combinations,
default-off behavior, bounded writes, invalid configuration, and
writer failures using an in-memory writer. They open no microphone, audio device,
USB port, or serial console and generate no vendor files. They do not establish
actual LED operation or MicroPython/device compatibility.

For further read-only inspection, power the microphone normally and connect its
own USB-C port to the Mac with a data cable, retaining the 3.5 mm connection to
Sonos. Do not use a firmware or bootloader button sequence. First identify the
exact device and read the mounted startup files without changing them. Reading
ROM documentation or runtime getters through a console requires sending commands
to the device; it is not passive USB observation. The existing raw-REPL helper
also changes console modes and should not be treated as an inert file reader.
Avoid helpers that toggle DTR/RTS or reset the device. No such device investigation
was performed for this source correction.

Before any future opt-in device integration, verify the LED API and every chosen
pair against the user's own device, identify all stock LED writers and priority
warnings, measure tick cadence, and test the module on that MicroPython runtime.
Only then should the builder offer an opt-in hook with the default output left
unchanged. This work does not authorize installing that hook or changing device
firmware.
