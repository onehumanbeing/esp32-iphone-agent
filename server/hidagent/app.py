"""Web API + control page. Run with `python -m hidagent`."""

import asyncio
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, StrictBool

from .agent import Agent
from .debug import Trace
from .device import Device, DeviceError
from .llm import LLM
from .phone import Phone
from .screen import Screen

DATA_DIR = Path(os.environ.get("HIDAGENT_DATA", Path.home() / ".hidagent"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
DEBUG = os.environ.get("HIDAGENT_DEBUG") == "1"

device = Device()
screen = Screen(os.environ.get("AIRPLAY_NAME", "iPhone Agent"))
phone = Phone(device, DATA_DIR / "calibration.json", screen)
agent = Agent(phone, screen, LLM.from_env("ACTOR"), LLM.from_env("PLANNER"),
              Trace(DATA_DIR / "traces" if DEBUG else None))


@asynccontextmanager
async def lifespan(_):
    server = await device.serve("0.0.0.0", int(os.environ.get("DEVICE_PORT", 7300)))
    screen.start()
    awake = asyncio.create_task(device.keep_awake(screen=screen))
    yield
    awake.cancel()
    screen.stop()
    server.close()


app = FastAPI(lifespan=lifespan)
class Static(StaticFiles):
    """Static files that browsers re-check on every load, so a new version shows up on refresh."""

    async def get_response(self, path, scope):
        response = await super().get_response(path, scope)
        response.headers["Cache-Control"] = "no-cache"
        return response


app.mount("/static", Static(directory=Path(__file__).parent / "static"), name="static")


class Point(BaseModel):
    x: float = Field(ge=0, le=1, allow_inf_nan=False)
    y: float = Field(ge=0, le=1, allow_inf_nan=False)


class Swipe(BaseModel):
    x1: float = Field(ge=0, le=1, allow_inf_nan=False)
    y1: float = Field(ge=0, le=1, allow_inf_nan=False)
    x2: float = Field(ge=0, le=1, allow_inf_nan=False)
    y2: float = Field(ge=0, le=1, allow_inf_nan=False)


class Scroll(Point):
    lines: int = Field(ge=-100, le=100)


class Text(BaseModel):
    text: str


class KeyboardText(Text):
    text: str = Field(min_length=1, max_length=4000)


class EditText(KeyboardText):
    replace: StrictBool = False
    submit: StrictBool = False


def check_keyboard(text):
    if not text.isascii() or any(ord(c) < 32 or ord(c) == 127 for c in text):
        raise HTTPException(422, "keyboard input must be printable ASCII on one line")


manual_lock = asyncio.Lock()


def check_manual():
    if agent.running or manual_lock.locked():
        raise HTTPException(409, "phone is busy; stop the agent or wait for the current action")


async def act(action):
    check_manual()
    try:
        async with manual_lock:
            await action()
    except (DeviceError, RuntimeError) as e:
        raise HTTPException(409, str(e)) from e
    return {"ok": True}


@app.get("/")
def index():
    return FileResponse(Path(__file__).parent / "static" / "index.html")


@app.get("/api/status")
def status():
    return {"device": device.connected, "screen": screen.live, "calibrated": phone.calibrated,
            "debug": DEBUG, "trace": str(agent.trace.dir or ""), "aspect": round(screen.aspect, 4),
            "models": {"planner": agent.planner.model, "actor": agent.actor.model},
            "agent": {"running": agent.running, "task": agent.task, "steps": agent.steps}}


@app.get("/api/frame.jpg")
def frame():
    if not screen.live:
        raise HTTPException(404, "no live screen: start screen mirroring on the phone")
    return Response(screen.frame, media_type="image/jpeg", headers={"Cache-Control": "no-store"})


@app.get("/api/steps/{index}.jpg")
def step_shot(index: int):
    if index not in agent.shots:
        raise HTTPException(404)
    return Response(agent.shots[index], media_type="image/jpeg", headers={"Cache-Control": "max-age=3600"})


@app.post("/api/tap")
async def tap(p: Point):
    return await act(lambda: phone.tap(p.x, p.y))


@app.post("/api/swipe")
async def swipe(s: Swipe):
    return await act(lambda: phone.swipe(s.x1, s.y1, s.x2, s.y2))


@app.post("/api/scroll")
async def scroll(s: Scroll):
    return await act(lambda: phone.scroll(s.x, s.y, s.lines))


@app.post("/api/type")
async def type_text(t: KeyboardText):
    check_keyboard(t.text)
    return await act(lambda: phone.type(t.text))


@app.post("/api/edit_text")
async def edit_text(t: EditText):
    check_keyboard(t.text)
    return await act(lambda: phone.edit_text(t.text, replace=t.replace, submit=t.submit))


@app.post("/api/key")
async def key(t: KeyboardText):
    check_keyboard(t.text)
    return await act(lambda: phone.key(t.text))


@app.post("/api/home")
async def home():
    return await act(phone.go_home)


@app.post("/api/back")
async def back():
    return await act(phone.go_back)


@app.post("/api/raw")
async def raw(t: Text):
    """Debug only: send one protocol line to the board as-is."""
    if not DEBUG:
        raise HTTPException(404)
    return await act(lambda: device.send(t.text))


@app.post("/api/calibrate/start")
async def calibrate_start():
    """Calibrate the pointer. {"auto": true}: done by itself; otherwise the user clicks the pointer next."""
    check_manual()
    try:
        async with manual_lock:
            return {"ok": True, "auto": await phone.start_calibration(), "span": phone.span}
    except (DeviceError, RuntimeError) as e:
        raise HTTPException(409, str(e)) from e


@app.post("/api/calibrate/finish")
async def calibrate_finish(p: Point):
    check_manual()
    if not 0 < p.x < 1 or not 0 < p.y < 1:
        raise HTTPException(422, "calibration pointer must be inside the screen")
    phone.finish_calibration(p.x, p.y)
    return {"ok": True, "span": phone.span}


@app.post("/api/agent")
async def agent_start(t: Text):
    if manual_lock.locked():
        raise HTTPException(409, "phone is busy; wait for the current action")
    try:
        agent.start(t.text)
    except RuntimeError as e:
        raise HTTPException(409, str(e)) from e
    return {"ok": True}


@app.post("/api/agent/stop")
async def agent_stop():
    """Emergency stop: cancel the agent and release the mouse button."""
    agent.stop()
    await asyncio.sleep(0.1)  # let a gesture in flight finish its own release
    # Emergency stop must stay available even while a direct action holds the lock.
    try:
        if device.connected:
            await phone.reset()
    except (DeviceError, RuntimeError) as e:
        raise HTTPException(409, str(e)) from e
    return {"ok": True}


@app.post("/api/agent/clear")
def agent_clear():
    """Forget the last run (steps, screenshots, plan) so the page starts clean."""
    try:
        agent.clear()
    except RuntimeError as e:
        raise HTTPException(409, str(e)) from e
    return {"ok": True}
