// Keep manual input ordered; a failed request drops pending input instead of replaying it.
function createKeyboardQueue(send, failed, limit = 64) {
  const pending = [];
  let running = false;
  function clear() {
    for (const item of pending.splice(0)) item.resolve.forEach(done => done(null));
  }
  async function drain() {
    if (running) return;
    running = true;
    try {
      while (pending.length) {
        const item = pending.shift();
        let result = null;
        try { result = await send(item.path, item.body); } catch { failed(); }
        item.resolve.forEach(done => done(result));
        if (!result) { clear(); break; }
      }
    } finally { running = false; }
  }
  return {
    clear,
    push(path, body) {
      return new Promise(resolve => {
        const last = pending[pending.length - 1];
        if (path === "/api/type" && last?.path === path && last.body.text.length + body.text.length <= 4000) {
          last.body.text += body.text;
          last.resolve.push(resolve);
        } else if (pending.length < limit) {
          pending.push({ path, body, resolve: [resolve] });
        } else {
          clear();
          failed();
          resolve(null);
        }
        drain();
      });
    },
  };
}

// ASCII is the wire encoding for US HID positions; iOS applies its active hardware layout/IME.
function physicalCharacter(event) {
  const code = event.code || "", shift = Boolean(event.shiftKey);
  if (/^Key[A-Z]$/.test(code)) {
    const letter = code.slice(3);
    return shift !== Boolean(event.getModifierState?.("CapsLock")) ? letter : letter.toLowerCase();
  }
  if (/^Digit[0-9]$/.test(code)) return shift ? ")!@#$%^&*("[Number(code.slice(5))] : code.slice(5);
  const punctuation = {
    Space: [" ", " "], Minus: ["-", "_"], Equal: ["=", "+"],
    BracketLeft: ["[", "{"], BracketRight: ["]", "}"], Backslash: ["\\", "|"],
    Semicolon: [";", ":"], Quote: ["'", '"'], Backquote: ["`", "~"],
    Comma: [",", "<"], Period: [".", ">"], Slash: ["/", "?"],
  };
  return punctuation[code]?.[shift ? 1 : 0] ?? null;
}

function connectPhoneKeyboard({ element, available, text, key, blocked, release, platform = navigator.platform }) {
  const named = {
    Enter: "enter", Backspace: "backspace", Tab: "tab", ArrowUp: "up", ArrowDown: "down",
    ArrowLeft: "left", ArrowRight: "right", Delete: "ctrl+d", Home: "cmd+left", End: "cmd+right",
  };
  element.addEventListener("keydown", event => {
    // Escape keeps the page's existing emergency-stop behavior and releases local focus.
    if (event.key === "Escape" || event.code === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      release();
      element.blur();
      return;
    }
    if (!available()) { event.preventDefault(); return; }
    const character = physicalCharacter(event);
    const special = named[event.code] || named[event.key];
    if (character === null && !special) {
      if (!["Shift", "Control", "Alt", "Meta", "CapsLock"].includes(event.key)) blocked();
      event.preventDefault();
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    // event.key may be Process, kana, Hangul or a host IME character; never send that commit too.
    if (character !== null && !event.metaKey && !event.ctrlKey && !event.altKey) {
      text(character);
      return;
    }
    if (special?.includes("+")) {
      key((event.shiftKey ? "shift+" : "") + special);
      return;
    }
    const letter = character?.toLowerCase();
    const command = event.metaKey || (!/Mac|iPhone|iPad/.test(platform) && event.ctrlKey && !event.altKey &&
      ["a", "c", "v", "x", "z", "y"].includes(letter));
    const modifiers = [command ? "cmd" : null, event.ctrlKey && !command ? "ctrl" : null,
      event.altKey ? "alt" : null, event.shiftKey || character === "+" ? "shift" : null].filter(Boolean);
    let value = special || (character === " " ? "space" : character === "+" ? "=" : letter);
    if (command && letter === "y" && !/Mac|iPhone|iPad/.test(platform)) {
      value = "z";
      if (!modifiers.includes("shift")) modifiers.push("shift");
    }
    key([...modifiers, value].join("+"));
  });
  // A focused preview is not a text editor on the host. Composition/paste never injects Unicode bytes.
  element.addEventListener("paste", event => { event.preventDefault(); blocked(); });
}
