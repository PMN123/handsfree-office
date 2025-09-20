# server.py — Hands-Free Office (no-LLM, JSON-driven intents)

import os
import sys
import re
import json
import time
import asyncio
import subprocess
from pathlib import Path
from urllib.parse import urlparse
from collections import deque

import pyautogui
import pyperclip
import websockets

from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics.pairwise import cosine_similarity
from urllib.parse import quote

# --------------------------- Config ---------------------------------

HOST = "0.0.0.0"
PORT = 8765

# pyautogui safety
pyautogui.FAILSAFE = True
pyautogui.PAUSE = 0.05

BASE = Path(__file__).parent

def _load_json(name: str):
    path = BASE / name
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

INTENTS = _load_json("intents.json")
KEYMAP  = _load_json("keymap.json")
SLOTS   = _load_json("slots.json")

# ----------------------- Slot utilities -----------------------------

def slot_app(name: str) -> str:
    """Map spoken app alias → real macOS app name."""
    n = (name or "").lower().strip()
    return SLOTS.get("apps", {}).get(n, name)

def slot_site(token: str) -> str:
    """Map site alias → URL and normalize bare domains to https://"""
    t = (token or "").lower().strip()
    site_map = SLOTS.get("sites", {})
    if t in site_map:
        return site_map[t]
    if not t:
        return ""
    # If it looks like a bare domain, prepend https://
    if not t.startswith(("http://", "https://")) and "." in t and " " not in t:
        return "https://" + t
    return t

# ----------------------- AppleScript helpers ------------------------

def run_applescript(script: str):
    """
    Run AppleScript safely. Pass a PLAIN triple-quoted string (no f/rf),
    especially when using braces in AppleScript to avoid Python formatting.
    """
    try:
        # Using -e with a multiline string works; alternatively write to a temp file.
        subprocess.run(["osascript", "-e", script], check=False)
    except Exception as e:
        print("AppleScript error:", e)

# ----------------------- UI action helpers --------------------------

def open_gmail_compose():
    # Opens Gmail compose in Chrome (new tab)
    script = """
    tell application "Google Chrome"
        activate
        if (count of windows) = 0 then
            make new window
        end if
        set newTab to make new tab at end of tabs of front window
        set URL of newTab to "https://mail.google.com/mail/u/0/#inbox?compose=new"
    end tell
    """
    run_applescript(script)
    time.sleep(1.2)  # small settle time

def focused_typing(text: str):
    # Paste via clipboard to avoid IME quirks
    if not text:
        return
    pyperclip.copy(text)
    pyautogui.hotkey("command", "v")

def send_email():
    # Gmail send shortcut
    pyautogui.hotkey("command", "enter")

def next_slide():
    # Works for Keynote and PowerPoint
    pyautogui.press("right")

def prev_slide():
    pyautogui.press("left")

def scroll_down():
    pyautogui.scroll(-600)

def scroll_up():
    pyautogui.scroll(600)

def open_presentation():
    """
    Keynote-native start; avoids System Events braces that caused (-2741).
    Requires your deck to appear in Keynote > File > Open Recent.
    """
    script = """
    tell application "Keynote"
        activate
        if (count of documents) = 0 then
            if (count of recent documents) > 0 then
                set recentDoc to item 1 of recent documents
                open recentDoc
            else
                return "no_recent"
            end if
        end if
        delay 0.4
        start document 1
    end tell
    """
    run_applescript(script)
    return "opened_presentation"

def _mailto_url(to_addr: str, subject: str = "", body: str = "") -> str:
    to = to_addr.strip()
    qs = []
    if subject:
        qs.append("subject=" + quote(subject))
    if body:
        qs.append("body=" + quote(body))
    tail = ("?" + "&".join(qs)) if qs else ""
    return f"mailto:{to}{tail}"
# ----------------------- Repeat-last support ------------------------

LAST_EXECUTED = None   # {"intent": str, "plan": dict, "slots": dict}
HISTORY = deque(maxlen=10)

# risky actions we don't want to auto-repeat
REPEAT_BLOCKLIST = {
    "send_email",
}

def repeat_last_action() -> str:
    global LAST_EXECUTED
    if not LAST_EXECUTED:
        print("repeat_last: no last action")
        return "no_last_action"
    if LAST_EXECUTED["intent"] in REPEAT_BLOCKLIST:
        print(f"repeat_last: blocked {LAST_EXECUTED['intent']}")
        return "repeat_blocked"
    print("repeat_last: replaying", LAST_EXECUTED)
    return _apply_plan(LAST_EXECUTED["plan"], LAST_EXECUTED["slots"])

# ----------------------- Plan executor ------------------------------

def _apply_plan(plan: dict, slots: dict) -> str:
    """Low-level execution. Does NOT record last action."""
    t = plan.get("type")

    # high-level AppleScript wrappers
    if t == "applescript_gmail_compose":
        open_gmail_compose(); return "opened_gmail"

    if t == "applescript_open_url":
        url = slot_site(slots.get("url", ""))
        if not url:
            return "bad_url"
        script = f"""
        tell application "Google Chrome"
            activate
            if (count of windows) = 0 then make new window
            set newTab to make new tab at end of tabs of front window
            set URL of newTab to "{url}"
        end tell
        """
        run_applescript(script); return "opened_url"

    if t == "applescript_open_app":
        app = slot_app(slots.get("app", ""))
        if not app:
            return "bad_app"
        script = f"""
        tell application "{app}"
            activate
        end tell
        """
        run_applescript(script); return "opened_app"

    if t == "applescript_keynote_start":
        return open_presentation()

    # typing / primitives
    if plan.get("intent") == "type_text":
        txt = (slots.get("text") or "").strip()
        if txt:
            focused_typing(txt); return "typed"
        return "typed_empty"

    if t == "hotkey":
        pyautogui.hotkey(*plan["keys"]); return "hotkey"
    if t == "key":
        pyautogui.press(plan["key"]); return "key"
    if t == "scroll":
        pyautogui.scroll(plan.get("amount", -600)); return "scroll"

    if t == "repeat_last":
        return repeat_last_action()
    
    if t == "mailto_compose":
        to = (slots.get("to") or "").strip()
        subject = (slots.get("subject") or "").strip()
        body = (slots.get("body") or "").strip()
        if not to:
            # no recipient → just ensure Gmail compose opens
            open_gmail_compose()
            return "opened_gmail"
        url = _mailto_url(to, subject, body)
        script = f"""
        tell application "Google Chrome"
            activate
            if (count of windows) = 0 then make new window
            set newTab to make new tab at end of tabs of front window
            set URL of newTab to "{url}"
        end tell
        """
        run_applescript(script)
        time.sleep(1.0)
        return "mailto_composed"

    return "noop"

def execute_intent(intent: str, slots: dict) -> str:
    """High-level execute: calls _apply_plan and records last action (unless blocked)."""
    global LAST_EXECUTED, HISTORY
    plan = KEYMAP.get(intent)
    if not plan:
        return "unknown_intent"

    # Annotate the plan with logical intent (used by _apply_plan for type_text)
    plan = {**plan, "intent": intent}

    # Never record the 'repeat' itself
    if plan.get("type") == "repeat_last":
        return _apply_plan(plan, slots)

    status = _apply_plan(plan, slots)

    # Record last successful action (unless blocklisted/noop)
    if intent not in REPEAT_BLOCKLIST and status not in {"noop", "unknown_intent", "bad_plan"}:
        LAST_EXECUTED = {"intent": intent, "plan": plan, "slots": slots}
        HISTORY.append(LAST_EXECUTED)

    return status

# ----------------------- Intent routing -----------------------------

class IntentRouter:
    """TF-IDF over examples from intents.json as a fuzzy fallback."""
    def __init__(self, intents: dict, threshold: float = 0.42):
        self.threshold = threshold
        self.examples = []
        self.labels = []
        for intent, obj in intents.items():
            if intent == "meta":
                continue
            for ex in obj.get("examples", []):
                self.examples.append(ex.lower())
                self.labels.append(intent)
        if self.examples:
            self.vectorizer = TfidfVectorizer(ngram_range=(1, 2), min_df=1)
            self.X = self.vectorizer.fit_transform(self.examples)
        else:
            self.vectorizer = None
            self.X = None

    def infer(self, text: str):
        if not self.vectorizer or not text:
            return (None, 0.0)
        q = text.lower().strip()
        if not q:
            return (None, 0.0)
        qv = self.vectorizer.transform([q])
        sims = cosine_similarity(qv, self.X)[0]
        idx = sims.argmax()
        score = float(sims[idx])
        label = self.labels[idx]
        if score >= self.threshold:
            return (label, score)
        return (None, score)

ROUTER = IntentRouter(INTENTS, threshold=0.42)

# Regex-first extraction for structured commands
def handle_command(cmd: str, payload: dict):
    raw = (cmd or "").strip().lower()
    print("handle_command (raw):", repr(raw))

    # 1) Regex patterns with named groups → capture slots
    for intent, spec in INTENTS.items():
        if intent == "meta":
            continue
        for pat in spec.get("patterns", []):
            m = re.match(pat, raw)
            if m:
                slots = {k: v for k, v in m.groupdict().items() if v}
                print(f"regex → intent={intent} slots={slots}")
                return execute_intent(intent, slots)

    # 2) Keyword contains → match examples literally (simple and fast)
    for intent, spec in INTENTS.items():
        if intent == "meta":
            continue
        for ex in spec.get("examples", []):
            if ex in raw:
                print(f"keyword → intent={intent}")
                return execute_intent(intent, {})

    # 3) TF-IDF fuzzy fallback
    try:
        intent, score = ROUTER.infer(raw)
        if intent:
            print(f"tfidf → intent={intent} score={score:.2f}")
            return execute_intent(intent, {})
    except Exception as e:
        print("router error:", e)

    print("unhandled command")
    return "unknown"

def handle_gesture(payload: dict):
    # Expect payload: {"type":"gesture","kind":"tilt","roll":..., "pitch":..., "yaw":...}
    kind = payload.get("kind", "")
    if kind == "tilt":
        roll = float(payload.get("roll", 0.0))
        if roll > 0.25:
            next_slide()
            return "gesture_next_slide"
        if roll < -0.25:
            prev_slide()
            return "gesture_prev_slide"
    return "gesture_ignored"

# ----------------------- WebSocket server ---------------------------

async def ws_handler(websocket):
    async for message in websocket:
        try:
            data = json.loads(message)
        except Exception:
            await websocket.send(json.dumps({"ok": False, "error": "bad_json"}))
            continue

        mtype = data.get("type", "")
        if mtype == "command":
            cmd = data.get("text", "")
            result = handle_command(cmd, data)
            await websocket.send(json.dumps({"ok": True, "result": result}))
        elif mtype == "gesture":
            result = handle_gesture(data)
            await websocket.send(json.dumps({"ok": True, "result": result}))
        else:
            await websocket.send(json.dumps({"ok": False, "error": "unknown_type"}))

async def main():
    print(f"Server listening on ws://{HOST}:{PORT}")
    async with websockets.serve(ws_handler, HOST, PORT, ping_interval=None):
        # keep running forever
        await asyncio.Future()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        # clean exit, avoid scary tracebacks on Ctrl+C
        try:
            loop = asyncio.get_event_loop()
            loop.stop()
        except Exception:
            pass
        sys.exit(0)