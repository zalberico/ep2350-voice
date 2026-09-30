# Optional microphone LED overlay

`firmware/fxmic/led_feedback.py` is a small, standalone adapter for the verified
1.1.2 custom `fxmic` script. It imports no modules and contains no vendor code.
Importing it does nothing to the device. Installation is a separate explicit
call; the existing builder, installer, boot stub, firmware, and custom script are
unchanged by this source addition. Its Python tests use a simulated callback.

## Local hardware validation

The adapter was copied and byte-verified on the connected firmware 1.1.2 device,
then activated against the existing running script without resetting it. The
user confirmed two lower lights while held, a brief three-light release pulse,
restoration to one light, and the usual Mac toast. The runtime remained enabled
with no reported error and the original tick counter continued advancing.

After that test, a guarded optional import/install was appended to the device's
boot stub. The resulting 208-byte file was synced and read back successfully;
the original 76-byte stub is backed up. **A normal power-cycle test is still
pending.** The existing `fxmic.py`, sample files, audio configuration, and firmware
were not replaced. The general installer still does not enable this add-on.

The user observed the lower bank with one light at sample index 0, two at index
1, and three at index 2. These tests used effect index -1 and returned to the
one-light baseline. Live read-only inspection also confirmed the existing script
and 61 ticks in 1.014 seconds, approximately 60 Hz. The source preserves the
current effect index; behavior at other effect selections still needs a live
check. `led_control` and `led_level` remain undocumented and are never called.

Once explicitly enabled, the adapter shows two lower lights while the handle is
held, three on release for 12 subsequent ticks (about 200 ms), then restores the
current stock pair. A new squeeze replaces a pending release pulse. A detected
shake restores stock and suppresses the remainder of that squeeze. These are
physical microphone events, not confirmation that an assistant received,
canceled, or finished anything. A newly enabled adapter waits for a released
handle before accepting a squeeze.

## Callback contract

The adapter registers a plain Python function and calls the original
`fxmic.python_callback` for every event. It neither changes that original
function nor changes the microphone's effect, sample, marker, or audio settings.
Feedback runs only after the original callback returns, on existing type-3 tick
events. It starts no loop, timer, thread, or USB interaction.

The known original tick writes stock LEDs when `fx_primed` or `sam_primed` is 1
before the callback. The adapter observes these conditions so even a stock write
of the same pair wins. It also observes changed stock indices. A stock update
cancels feedback until release and a fresh squeeze; the next squeeze uses the
new effect index. This rule depends on the exact inspected script, whose saved
9,311-byte snapshot has SHA-256
`ae3039dbeacc3d77c52efbe61a9ff9a9401d3579accf671475e70c7e364a94f7`.
Changes to its callback must be reviewed before reusing this adapter.

At most one additional LED write is attempted per tick. A feedback error disables
the overlay while the original callback keeps receiving events. If the failed
write might have changed LEDs, one restoration is attempted on a later tick;
automatic retries then stop. A stock write takes priority over that pending
restoration. Errors from the original callback itself retain their original
behavior and are not hidden. Compiled-firmware LED warnings are not observable
through this contract, so their priority has not been established.

## Explicit activation and removal

For another compatible device, first independently verify its current `fxmic.py` bytes and
stage only this adapter as `/fat/led_feedback.py`, checking the copied bytes.
Do not import or reload `fxmic`, reflash firmware, or reset the interpreter as
part of activation. With the existing `fxmic` module already available:

```python
import led_feedback
overlay = led_feedback.install(fxmic)
print(overlay.enabled, overlay.last_error)
```

Repeated installation returns the same handle instead of nesting callbacks. A
disabled handle is not automatically retried. Registration failure attempts to
restore the original callback. If rollback also fails, installation raises and
retains a disabled recovery handle in `fxmic._ep_led_feedback`; callback state is
then uncertain and must not be reported as restored.

For runtime removal:

```python
print(led_feedback.remove(fxmic))
print(overlay.last_error)
```

`True` means the original callback was reinstated. Any LED restoration error is
reported separately in `last_error`; detachment alone does not confirm the
physical display. If callback restoration raises, the disabled recovery handle
is retained so removal can be retried. A stale handle cannot remove a newer
installation. Repeated removal through the module is otherwise a no-op.

For an explicitly approved source update, remove the old overlay successfully
before replacing its file. Removing the adapter's module-cache entry and
reimporting it is sufficient to load a new adapter without reexecuting `fxmic`:

```python
import sys
del sys.modules['led_feedback']
import led_feedback
overlay = led_feedback.install(fxmic)
```

If memory allocation or import fails, leave the original callback running and
stop; do not try an interpreter reset as an automatic recovery step.

Persistence requires a separate boot-stub change after live validation: keep
its initial `import ui; ui.callback(0)` sequence and existing
`fxmic` import order, then append a guarded adapter import and activation. Do not
replace the existing startup script with this adapter. To undo persistence,
restore the verified original boot stub and remove only the added adapter file;
runtime removal above takes effect immediately. The local device's startup hook
was saved after its live test; this is not part of the general installer.

## Offline validation

```sh
python3 -B -m unittest discover -s Tests/Python -p 'test_led_overlay.py' -v
```

The tests cover original-event delivery, held/release timing, all five effect
indices, same-pair stock writes, effect changes, early activation, cancellation,
bounded failure cleanup, partial registration, failed rollback/removal, and
stale handles. They do not establish remaining memory, firmware warning priority,
or callback behavior on the physical microphone.
