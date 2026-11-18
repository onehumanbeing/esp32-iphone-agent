# The .intent file

**English** | [中文](intent-format.zh-CN.md)

An intent is a saved task: a name, an instruction for the agent, an optional checklist, and optionally the steps
recorded when it was done once. A `.intent` file carries one or more intents between the iOS app, the CLI and
anyone who writes one by hand. It is plain JSON (UTF-8).

| | |
|---|---|
| Extension | `.intent` (files from before 2026-11-16 end in `.esp32intent`; both open) |
| Type (UTI) | `com.onehumanbeing.esp32agent.intent`, conforms to `public.json` |
| MIME | `application/vnd.esp32agent.intent+json` |
| Largest file | 25 MB |
| Written by | iOS `IntentArchive.swift`, CLI `cli/internal/intent/archive.go` |

## Adding one

- **iPhone:** open the file from Mail, Messages, AirDrop or the Files app, or put it in the app's Files tab and
  tap it, then **Add to Intents**. Agent › My intents › ⋯ › Import… does the same.
- **CLI:** `esp32agent intent import FILE`.

An intent whose name and instruction (ignoring case) are already saved is skipped, so adding a file twice is harmless.

## Fields

```json
{
  "format": 1,
  "note": "optional text for whoever opens the file",
  "intents": [
    {
      "name": "Notes hello",
      "prompt": "Open Notes and write hello",
      "icon": "note.text",
      "color": "teal",
      "hints": ["Use the + button"],
      "steps": [
        { "action": "{\"action\": \"tap\", \"x\": 500, \"y\": 800}", "sure": true, "frame": "<base64 JPEG>" },
        { "action": "{\"action\": \"type\", \"text\": \"hello\"}", "sure": true }
      ],
      "until": "optional: repeat the steps until this is on screen",
      "maxLoops": 5
    }
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `format` | yes | `1`. A reader refuses a higher number ("needs a newer version"). |
| `note` | no | Free text for the person receiving the file. |
| `intents[].name` | yes | Shown in the intent list. Empty: the first 30 characters of `prompt`. |
| `intents[].prompt` | yes | The instruction the agent gets. An intent without one is dropped. |
| `intents[].icon` | no | An SF Symbols name. Default `bolt.fill`. |
| `intents[].color` | no | One of `accent red pink purple indigo blue teal green yellow gray`. |
| `intents[].hints` | no | Checklist lines the agent keeps in mind (up to 6 are used). |
| `intents[].steps` | no | Recorded steps, replayed without asking the model when the screen matches. |
| `steps[].action` | yes | One action as a JSON object **in a string**, in the agent's action format (`tap` with `x` `y` in 0–1000 screen units and an optional `label`, `swipe`, `type`, `key`, `open`, `home`, `back` …). A string that isn't a JSON object drops the step. |
| `steps[].sure` | yes | `true` when the step was confirmed (replayed directly), `false` when it was inferred. |
| `steps[].frame` | no | The screen before the step, base64 JPEG. Lets a step be replayed when the screen matches; without it the step is a hint for the model. Not an image: dropped. |
| `intents[].until` | no | For a loop: the text that ends it. |
| `intents[].maxLoops` | no | For a loop: the most rounds. |

Keys are written sorted; readers must not depend on order. Unknown keys are ignored, so a newer writer can add
fields without breaking older apps; a change that older apps would misread raises `format`.

## Privacy

Screenshots are only included when the person exporting asks for them. Run history, run ids and model keys are never
part of the file. Intents mailed to the developer (Send to Developer) have typed text replaced and screenshots
pixelated first.
