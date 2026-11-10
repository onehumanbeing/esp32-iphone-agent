# 提示词

[English](README.md) · 简体中文

App 发给模型的提示词，纯文本。构建时打包进 App（`ios/project.yml`，由 `ios/IPhoneAgent/Agent/Prompts.swift` 读取）。

- `actor.md`：一次任务里唯一的模型。每一步看目标、自己的计划、最近的操作及效果和屏幕，回复 THINK、可选的 PLAN（重写计划）和 DO 操作；整个目标在屏幕上可见时说 done。列出 App 能解析的操作语法。
- `app-rules.md`：在手机里运行的规则（不要动本 App、开关、主屏幕图标）；附加在 actor 提示词之后。
- `reader.md`：`read` 操作用它从一屏里抄出要的条目，记进笔记本。
- `ipad/`：同样三个文件的 iPad 版，iPad 用它们代替上面的：iPad 布局（标签栏在中间或侧边栏、面板和弹出框、目标小）、程序坞、分屏和侧拉、返回作用在左侧窗格。两套要一起改；操作语法那几行必须逐字相同（PromptTests 会检查）。

修改、重新构建，然后在 App 的「运行」标签页对比结果。`actor.md` 里的操作列表要和 `ios/IPhoneAgent/Agent/Actions.swift` 保持一致。每个文件末尾的换行不属于提示词。
