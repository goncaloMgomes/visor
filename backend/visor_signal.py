#!/usr/bin/env python3
"""Tell the robot what an AI tool is doing: the status side of the protocol,
for any agent that can run a command on its events (hooks, notify scripts).

  visor signal <mood>
      idle | thinking | working | input | done | error | nervous | love

  visor signal --event <start|stop|ask|error> [--title T] [--text X]
               [--source NAME] [--sid ID] [--mood M]
      also a balloon message: stop = "T is done: X", ask = "T needs your
      approval", error = "T hit an error". A stop shorter than 20 s after its
      start (same --sid) isn't announced. --mood defaults to the event's own
      (start=thinking, stop=done, ask=input, error=error).
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import append_event, set_mood  # noqa: E402

MOODS = {"idle", "thinking", "working", "input", "done", "error", "nervous", "love"}
EVENT_MOOD = {"start": "thinking", "stop": "done", "ask": "input", "error": "error"}


def main():
    if os.environ.get("VISOR_QUIET"):
        return
    ap = argparse.ArgumentParser(prog="visor signal", description=__doc__.split("\n\n")[0])
    ap.add_argument("mood", nargs="?")
    ap.add_argument("--event", choices=sorted(EVENT_MOOD))
    ap.add_argument("--title", default="")
    ap.add_argument("--text", default="")
    ap.add_argument("--source", default="")
    ap.add_argument("--sid", default="")
    ap.add_argument("--mood", dest="mood2")
    a = ap.parse_args()
    mood = a.mood or a.mood2 or EVENT_MOOD.get(a.event or "")
    if not mood and not a.event:
        ap.error("give a mood or --event")
    if mood:
        if mood not in MOODS:
            ap.error(f"unknown mood {mood!r}; one of {', '.join(sorted(MOODS))}")
        set_mood(mood)
    if a.event:
        ev = {"kind": a.event, "t": int(time.time()), "source": a.source, "sid": a.sid or a.title,
              "title": a.title, "text": a.text}
        append_event({k: v for k, v in ev.items() if v != ""})


if __name__ == "__main__":
    main()
