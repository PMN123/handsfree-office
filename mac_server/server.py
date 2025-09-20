import asyncio
import json
import subprocess
import sys
import time
import pyautogui
import pyperclip
import websockets

# pyautogui safety
pyautogui.FAILSAFE = True
pyautogui.PAUSE = 0.05

HOST = "0.0.0.0"
PORT = 8765

def run_applescript(script: str):
    subprocess.run(["osascript", "-e", script], check=False)

def open_gmail_compose():
    # Open Gmail compose in Chrome
    script = r'''
    tell application "Google Chrome"
        activate
        if (count of windows) = 0 then
            make new window
        end if
        set newTab to make new tab at end of tabs of front window
        set URL of newTab to "https://mail.google.com/mail/u/0/#inbox?compose=new"
    end tell
    '''
    run_applescript(script)
    time.sleep(1.5)

def open_keynote_and_start():
    # Keynote must have your deck ready as the most recent document
    script = r'''
    tell application "Keynote"
        activate
        if not (exists document 1) then
            reopen -- open most recent
        end if
        activate
        play document 1
    end tell
    '''
    run_applescript(script)
    time.sleep(1.0)

def open_powerpoint_and_start():
    # Alternative if using PowerPoint
    script = r'''
    tell application "Microsoft PowerPoint"
        activate
        if not (exists active presentation) then
            reopen
        end if
        activate
        start slideshow active presentation
    end tell
    '''
    run_applescript(script)
    time.sleep(1.0)

def focused_typing(text: str):
    # Use clipboard paste to avoid IME quirks
    pyperclip.copy(text)
    pyautogui.hotkey("command", "v")

def send_email():
    # Gmail send shortcut: Cmd + Enter
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
    # Pick one. Default to Keynote for demo reliability.
    open_keynote_and_start()
    # If you prefer PowerPoint:
    # open_powerpoint_and_start()

def handle_command(cmd: str, payload: dict):
    c = cmd.strip().lower()

    if c.startswith("open gmail"):
        open_gmail_compose()
        return "opened_gmail"

    if c.startswith("type "):
        # everything after 'type ' is the text
        text = cmd[5:]
        focused_typing(text)
        return "typed"

    if c == "send email" or c == "send":
        send_email()
        return "sent_email"

    if c == "open presentation":
        open_presentation()
        return "opened_presentation"

    if c in ("next slide", "next"):
        next_slide()
        return "next_slide"

    if c in ("previous slide", "prev", "previous"):
        prev_slide()
        return "prev_slide"

    if c in ("scroll down", "scroll"):
        scroll_down()
        return "scroll_down"

    if c in ("scroll up"):
        scroll_up()
        return "scroll_up"

    return "unknown_command"

def handle_gesture(payload: dict):
    # Expect payload like {"type":"gesture","kind":"tilt","roll":..., "pitch":..., "yaw":...}
    kind = payload.get("kind", "")
    if kind == "tilt":
        # simple thresholds
        roll = payload.get("roll", 0.0)
        # roll > +0.25 radians → next, roll < -0.25 → previous
        if roll > 0.25:
            next_slide()
            return "gesture_next_slide"
        elif roll < -0.25:
            prev_slide()
            return "gesture_prev_slide"
    return "gesture_ignored"

async def handler(websocket):
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
    async with websockets.serve(handler, HOST, PORT, ping_interval=None):
        await asyncio.Future()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)