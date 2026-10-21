"""Text the board cannot type key by key (Chinese, emoji, accented letters) goes in by paste.

The board is a US keyboard, so it only has keys for ASCII. For anything else the server puts the text on
this Mac's clipboard; Universal Clipboard (same Apple Account on both, Handoff, Bluetooth and Wi-Fi on)
offers it to the iPhone, and Cmd+V from the board pastes it into the focused field. On Linux and Windows
there is no Universal Clipboard, so only ASCII can be typed there.
"""

import os
import subprocess
import sys

_ENV = {**os.environ, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}  # pbcopy/pbpaste keep UTF-8 only then


def supported() -> bool:
    return sys.platform == "darwin"


def write(text: str) -> None:
    subprocess.run(["pbcopy"], input=text.encode("utf-8"), env=_ENV, timeout=5, check=True)
