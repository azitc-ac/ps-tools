"""ansicht.py - fm.ps1 in einem Pseudo-Terminal starten, Tasten senden, Bildschirm als Text ausgeben."""
import sys, time, threading, queue, pyte
from winpty import PtyProcess
cols, rows = 110, 28
proc = PtyProcess.spawn(["powershell.exe", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", sys.argv[1], sys.argv[2], sys.argv[3]], dimensions=(rows, cols))
screen = pyte.Screen(cols, rows); stream = pyte.Stream(screen)
q = queue.Queue()
def leser():
    while True:
        try:
            d = proc.read(4096)
        except Exception:
            return
        if d: q.put(d)
threading.Thread(target=leser, daemon=True).start()
def lies(sek):
    ende = time.time() + sek
    while time.time() < ende:
        try: stream.feed(q.get(timeout=0.1))
        except queue.Empty: pass
def zeige(titel):
    print("=" * 20, titel)
    for z in screen.display: print(z.rstrip())
lies(5); zeige("Start")
for taste in sys.argv[4:]:
    proc.write({"DOWN": "\x1b[B", "UP": "\x1b[A", "TAB": "\t", "SPACE": " ", "F5": "\x1b[15~", "ENTER": "\r", "F1": "\x1bOP"}.get(taste, taste))
    lies(1.0)
zeige("Nach Tasten: " + " ".join(sys.argv[4:]))
import os
sys.stdout.flush()
os._exit(0)
