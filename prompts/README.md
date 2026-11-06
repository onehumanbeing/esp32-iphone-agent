# Prompts

English · [简体中文](README.zh-CN.md)

The model prompts the app sends, as plain text. They are bundled into the app at build time
(`ios/project.yml`, read by `ios/IPhoneAgent/Agent/Prompts.swift`).

- `planner.md`: writes a short plan from the goal and the first screen.
- `actor.md`: picks the next action(s) from each screenshot; lists the action syntax the app parses.
- `app-rules.md`: rules for running inside the phone (never touch this app, toggles, home screen icons); appended
  to both.

Edit, rebuild, and compare runs in the app's Runs tab. Keep the action list in `actor.md` in sync with
`ios/IPhoneAgent/Agent/Actions.swift`. Each file's final newline is not part of the prompt.
