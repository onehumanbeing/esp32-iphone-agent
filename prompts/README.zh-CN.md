# 提示词

[English](README.md) · 简体中文

App 发给模型的提示词，纯文本。构建时打包进 App（`ios/project.yml`，由 `ios/IPhoneAgent/Agent/Prompts.swift` 读取）。

- `planner.md`：根据目标和第一张屏幕写一个简短计划。
- `actor.md`：根据每张截图选择下一个（或几个）操作；列出 App 能解析的操作语法。
- `app-rules.md`：在手机里运行的规则（不要动本 App、开关、主屏幕图标）；附加在上面两个之后。

修改、重新构建，然后在 App 的「运行」标签页对比结果。`actor.md` 里的操作列表要和 `ios/IPhoneAgent/Agent/Actions.swift` 保持一致。每个文件末尾的换行不属于提示词。
