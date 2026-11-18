# .intent 文件

[English](intent-format.md) | **中文**

意图（Intent）是保存下来的任务：名称、给 Agent 的指令、可选的检查清单，以及可选的、做过一次时录下的步骤。
`.intent` 文件用来在 iOS App、CLI 和手写者之间传递一个或多个意图。它是纯 JSON（UTF-8）。

| | |
|---|---|
| 扩展名 | `.intent`（2026-11-16 之前的文件是 `.esp32intent`，两种都能打开） |
| 类型（UTI） | `com.onehumanbeing.esp32agent.intent`，遵循 `public.json` |
| MIME | `application/vnd.esp32agent.intent+json` |
| 文件上限 | 25 MB |
| 读写实现 | iOS `IntentArchive.swift`，CLI `cli/internal/intent/archive.go` |

## 怎么添加

- **iPhone：** 从邮件、信息、隔空投送或「文件」App 打开它；或者放进 App 的「文件」页点开，再点 **添加到我的意图**。
  助手 › 我的意图 › ⋯ › 导入… 效果一样。
- **CLI：** `esp32agent intent import FILE`。

名称和指令（不区分大小写）都和已有意图相同的会跳过，所以重复添加同一个文件没有副作用。

## 字段

```json
{
  "format": 1,
  "note": "可选，写给打开文件的人",
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
      "until": "可选：重复这些步骤，直到屏幕上出现这段文字",
      "maxLoops": 5
    }
  ]
}
```

| 字段 | 必填 | 含义 |
|---|---|---|
| `format` | 是 | `1`。读到更大的数字会拒绝（提示需要新版本）。 |
| `note` | 否 | 写给收到文件的人的说明。 |
| `intents[].name` | 是 | 在意图列表里显示。为空时取 `prompt` 前 30 个字符。 |
| `intents[].prompt` | 是 | 给 Agent 的指令。没有指令的意图会被丢弃。 |
| `intents[].icon` | 否 | SF Symbols 名称，默认 `bolt.fill`。 |
| `intents[].color` | 否 | `accent red pink purple indigo blue teal green yellow gray` 之一。 |
| `intents[].hints` | 否 | Agent 要记住的检查项（最多用 6 条）。 |
| `intents[].steps` | 否 | 录下的步骤；屏幕对得上时直接回放，不问模型。 |
| `steps[].action` | 是 | 一个动作，**JSON 对象写成字符串**，格式同 Agent 的动作（`tap` 带 0–1000 屏幕坐标 `x` `y` 和可选 `label`，以及 `swipe`、`type`、`key`、`open`、`home`、`back` 等）。不是 JSON 对象的步骤会被丢弃。 |
| `steps[].sure` | 是 | `true` 表示确认过（直接回放），`false` 表示推断出来的。 |
| `steps[].frame` | 否 | 这一步之前的屏幕，base64 JPEG。有它才能在屏幕匹配时回放；没有就只是给模型的提示。不是图片会被丢弃。 |
| `intents[].until` | 否 | 循环用：出现这段文字就结束。 |
| `intents[].maxLoops` | 否 | 循环用：最多几轮。 |

写入时键按字母排序，读取方不能依赖顺序。不认识的键会被忽略，所以新版本可以加字段而不影响旧 App；
旧 App 会读错的改动要提升 `format`。

## 隐私

只有导出的人勾选时才包含截图。运行记录、运行 id 和模型 key 永远不会写进文件。
通过「发给开发者」邮寄的意图，会先替换掉输入的文字、给截图打码。
