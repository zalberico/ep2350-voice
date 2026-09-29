#!/usr/bin/env python3
"""Run Python on the EP-2350 through MicroPython's raw REPL, opening the port without touching DTR/RTS
(pyserial's modem-line toggling resets the mic). usage: tools/mp_exec.py [-t seconds] file.py | -c "code" """
import os, select, subprocess, sys, time, glob

def open_port():
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    port = next((p for p in ports if "EP" in p), ports[0] if ports else None)
    if not port: sys.exit("no EP-2350 serial port: is the mic on and connected with a USB-C data cable?")
    subprocess.run(["stty", "-f", port, "115200", "raw", "-echo", "clocal"], check=False)
    return os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)

def read_until(fd, marker, timeout):
    buf = b""; end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: buf += os.read(fd, 65536)
            except BlockingIOError: pass
            if marker in buf: return buf, True
    return buf, False

def raw_exec(fd, code, timeout):
    os.write(fd, b"\r\x01")                       # enter raw REPL
    buf, ok = read_until(fd, b"raw REPL; CTRL-B to exit\r\n>", 3)
    if not ok: return None, "no raw REPL prompt: " + buf[-200:].decode("utf-8", "replace")
    data = code.encode()
    for i in range(0, len(data), 256):            # feed in chunks so the device keeps up
        os.write(fd, data[i:i + 256]); time.sleep(0.01)
    os.write(fd, b"\x04")                         # execute
    buf, ok = read_until(fd, b"OK", 3)
    if not ok: return None, "no OK after submit: " + buf[-200:].decode("utf-8", "replace")
    out, done = read_until(fd, b"\x04\x04>", timeout)   # stdout \x04 stderr \x04 >
    os.write(fd, b"\x02")                         # back to the friendly REPL
    text = out.decode("utf-8", "replace")
    if text.startswith("OK"): text = text[2:]
    parts = text.split("\x04")
    stdout = parts[0] if parts else text
    stderr = parts[1] if len(parts) > 1 else ""
    if not done: stderr += "\n[timeout waiting for completion]"
    return stdout, stderr

if __name__ == "__main__":
    args = sys.argv[1:]; timeout = 20.0
    if args and args[0] == "-t": timeout = float(args[1]); args = args[2:]
    code = args[1] if args and args[0] == "-c" else open(args[0]).read()
    fd = open_port()
    try:
        out, err = raw_exec(fd, code, timeout)
    finally:
        os.close(fd)
    if out is None: sys.exit(err)
    sys.stdout.write(out)
    if err.strip(): sys.stderr.write("\n[device stderr]\n" + err)
