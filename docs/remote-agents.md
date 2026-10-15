# Remote agents (legacy version)

The optional CLI and stdio MCP bridge control the existing Python server over
HTTP. They use the legacy Wi-Fi/TCP firmware and UxPlay setup described in the
README. They do not work with the BLE/iPhone-app version.

Use this route when an external agent runs on a Mac/Linux host or Raspberry Pi
and supplies the decisions. It reuses the existing Wi-Fi/TCP board setup and
requires no app installation or code signing on the iPhone. A separate host
running UxPlay is still required.

Install on the controlling computer:

```sh
pip install -e './server[mcp]'
iphone-agent --url http://127.0.0.1:8890 status
iphone-agent --url http://127.0.0.1:8890 screenshot phone.jpg
```

Use the actual server address if it runs elsewhere, including on a Raspberry Pi.
`IPHONE_AGENT_URL` supplies the default; otherwise the bridge uses localhost.
The legacy server has no authentication. Keep it on a trusted private network;
the bridge adds no public listener. Install without `[mcp]` if only the CLI is needed.

Configure an MCP client to launch this command (stdio transport):

```json
{
  "mcpServers": {
    "iphone": {
      "command": "iphone-agent",
      "args": ["--url", "http://127.0.0.1:8890", "mcp"]
    }
  }
}
```

Start with `iphone_status` and `iphone_screenshot`. Coordinates are image fractions
from 0 to 1. The bridge exposes tap, swipe, scroll, type, key, Home, Back and
calibration. Direct controls need no model credentials. Keyboard input is
printable ASCII on one line; use `iphone_key` for Enter or editing combinations.
Only type into a visibly focused field. Observe after each action: an `ok` reply
is a command acknowledgement, and the latest AirPlay frame can precede its effect.
Home/Back use the existing gestures and need visual confirmation.

`delegate_task` starts the server's existing configured vision agent. `task_status`
reads its single current task (`running`, `task`, `steps`); it is not a job history
and returns no task ID. Poll until `running` is false, inspect the last step for
done/fail/error, and check the screen. `stop_task` invokes the existing emergency
stop, which cancels the agent and releases/re-homes the pointer. The CLI equivalents
are `task 'Open Clock'`, `task-status` and `stop`.

The server rejects direct actions during an agent run and overlapping direct
actions. Use one controller at a time: there are no controller ownership leases.
Do not start another action until the previous one has returned. Calibration
returns `auto: false` when the user must locate the pointer; finish with both
coordinates, e.g. `iphone-agent calibrate --pointer 0.5 0.4`.

The bridge forwards existing controls. The typing guidance below is also included
in the actor prompt; no firmware or autonomous strategy changes are required.
No new hardware/performance results are established by the bridge.

## Type with the phone's keyboard

Click a visibly focused field in the preview, then type with a physical keyboard.
Only the focused preview captures keys; the task and manual input fields remain
normal browser inputs. Escape releases preview focus and invokes the existing
emergency stop. Input is ordered with taps and shortcuts, and unsent input is
dropped on focus loss, a failed request or Stop rather than replayed later.

The browser forwards US HID key positions, and iOS applies the selected hardware
keyboard layout and input method. ASCII describes the wire encoding, not the
language of the resulting text. Host IME commits are not also sent to the phone.
Host Unicode paste, software-keyboard composition and extra JIS/ISO-specific
keys are not supported by this route.

Enable the desired keyboards in Settings → General → Keyboard → Keyboards, and
check their Hardware Keyboard layouts. Switch languages by clicking the actual
globe key on the iPhone's on-screen keyboard through the preview. Agents use
`iphone_tap` on the visible key in the same way. There is no separate browser
language-switch button or language selector.

An attached hardware keyboard can hide the on-screen keyboard. Use the phone's
visible keyboard controls to show it before looking for the globe key; its
position is not fixed or inferred. Inspect the selected keyboard/candidates after
switching. `iphone-agent key ctrl+space` or `iphone_key(combo="ctrl+space")` remains
an optional fallback when needed, not a requirement for the normal GUI path.
See Apple's [keyboard switching](https://support.apple.com/guide/iphone/iph5948b3f2e/ios)
and [hardware layout](https://support.apple.com/guide/iphone/iph3814bb7d5/ios) guides.

The same input path is intended for Chinese Pinyin, Japanese Romaji and Korean
2-set; it does not contain a separate language whitelist or host transliterator.
Example sequences to check with those keyboards selected are `nihao`,
`konnichiha` and `dkssudgktpdy`. Agents send those keystrokes with `iphone_type`,
observe the candidates/composition, and then choose Space, an arrow, Enter or a
visible candidate as appropriate. Enter may commit or submit depending on the
app and IME state; do not send it blindly. The tool does not read the active
language directly or convert arbitrary Unicode strings into keystrokes.

Software tests cover key positions with Chinese/Japanese/Korean host labels,
candidate keys, switching and host-IME duplicate suppression. These checks do
not establish actual language output on a device. Physical acceptance on this
legacy patch is still required for all three keyboards; earlier Pinyin evidence
from a different revision/transport is not counted as a new result here.

## Focused-field editing

After observing a focused field, `iphone_edit_text(text="Calendar", replace=true)`
selects all and types in one request. The CLI equivalent is
`iphone-agent edit Calendar --replace`; REST uses `POST /api/edit_text` with
`{"text":"Calendar","replace":true,"submit":false}`. `submit` defaults to false;
only set it (or `--submit`) when pressing Enter is part of the requested task.
Trailing and all-space text uses existing `key space` commands because legacy
firmware trims protocol lines. No firmware update is required.

The combined edit avoids a client round trip between select-all and typing. It
does not inspect focus, make the HID commands transactional, or guarantee their
visible result. It shares the direct-action lock and refuses an active agent
run. Observe afterward. Capture/settling behavior is unchanged; there is no new
hardware latency benchmark for this endpoint.
