import asyncio
import json

import httpx
import pytest

from hidagent import cli
from hidagent.client import IPhoneClient
from hidagent.phone import Phone


class Board:
    links = 0

    def __init__(self):
        self.commands, self.text = [], ""

    async def send(self, command):
        self.commands.append(command)
        name, _, arg = command.strip().partition(" ")  # firmware's line.trim()
        if name == "type":
            self.text += arg
        elif command == "key space":
            self.text += " "


@pytest.mark.parametrize("text", ["Calendar", " Calendar ", "  ", " leading", "trailing  "])
def test_type_preserves_spaces_with_unchanged_firmware(tmp_path, text):
    board = Board()
    asyncio.run(Phone(board, tmp_path / "calibration.json").type(text))
    assert board.text == text


def test_edit_orders_commands_and_submits_only_when_requested(tmp_path):
    board = Board()
    phone = Phone(board, tmp_path / "calibration.json")
    asyncio.run(phone.edit_text("Calendar", replace=True))
    assert board.commands == ["key cmd+a", "type Calendar"]
    board.commands.clear()
    asyncio.run(phone.edit_text("Clock", submit=True))
    assert board.commands == ["type Clock", "key enter"]


@pytest.mark.parametrize("text", ["", "你好", "Clock\nhome", "\x7f"])
def test_invalid_edit_does_not_even_select_all(tmp_path, text):
    board = Board()
    with pytest.raises(ValueError):
        asyncio.run(Phone(board, tmp_path / "calibration.json").edit_text(text, replace=True))
    assert not board.commands


@pytest.mark.parametrize("text", ["你好", "日本語", "안녕하세요", "Clock\nhome"])
def test_native_typing_rejects_unicode_or_protocol_lines_before_sending(tmp_path, text):
    board = Board()
    with pytest.raises(ValueError):
        asyncio.run(Phone(board, tmp_path / "calibration.json").type(text))
    assert not board.commands


def test_native_ime_sequence_and_language_switch_use_old_firmware(tmp_path):
    board = Board()
    phone = Phone(board, tmp_path / "calibration.json")

    async def scenario():
        await phone.key("ctrl+space")
        await phone.type("nihao")
        await phone.key("space")

    asyncio.run(scenario())
    assert board.commands == ["key ctrl+space", "type nihao", "key space"]


@pytest.mark.parametrize("failure", ["key cmd+a", "type Clock"])
def test_edit_never_submits_after_a_command_failure(tmp_path, failure):
    class BrokenBoard(Board):
        async def send(self, command):
            self.commands.append(command)
            if command == failure:
                raise RuntimeError("board disconnected")

    board = BrokenBoard()
    with pytest.raises(RuntimeError):
        asyncio.run(Phone(board, tmp_path / "calibration.json").edit_text("Clock", replace=True, submit=True))
    assert board.commands[-1] == failure and "key enter" not in board.commands


def test_cancelled_edit_does_not_submit(tmp_path):
    async def scenario():
        entered = asyncio.Event()

        class SlowBoard(Board):
            async def send(self, command):
                self.commands.append(command)
                entered.set()
                await asyncio.Event().wait()

        board = SlowBoard()
        phone = Phone(board, tmp_path / "calibration.json")
        job = asyncio.create_task(phone.edit_text("Clock", submit=True))
        await entered.wait()
        job.cancel()
        with pytest.raises(asyncio.CancelledError):
            await job
        assert board.commands == ["type Clock"]

    asyncio.run(scenario())


def test_cli_edit_forwards_explicit_flags(monkeypatch, capsys):
    requests = []

    def respond(request):
        requests.append((request.url.path, json.loads(request.content)))
        return httpx.Response(200, json={"ok": True})

    monkeypatch.setattr(cli, "IPhoneClient", lambda url: IPhoneClient(url, transport=httpx.MockTransport(respond)))
    assert cli.main(["--url", "http://legacy", "edit", "Calendar", "--replace"]) == 0
    assert json.loads(capsys.readouterr().out) == {"ok": True}
    assert requests == [("/api/edit_text", {"text": "Calendar", "replace": True, "submit": False})]
