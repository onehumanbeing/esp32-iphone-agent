# Prompts

English · [简体中文](README.zh-CN.md)

The model prompts the app sends, as plain text. They are bundled into the app at build time
(`ios/project.yml`, read by `ios/IPhoneAgent/Agent/Prompts.swift`).

- `actor.md`: the one model of a run. Each step it gets the goal, its own plan, the recent actions with what each
  did, and the screen; it replies THINK, an optional PLAN (rewrites the plan), and DO action(s), and says done when
  the whole goal is visible. Lists the action syntax the app parses.
- `app-rules.md`: rules for running inside the phone (never touch this app, toggles, home screen icons, and hand
  the phone back when a screen asks for a password or code); appended to the actor prompt.

Edit, rebuild, and compare runs in the app's Runs tab. Keep the action list in `actor.md` in sync with
`ios/IPhoneAgent/Agent/Actions.swift`. Each file's final newline is not part of the prompt.
