# Prompts

English · [简体中文](README.zh-CN.md)

The model prompts the app sends, as plain text. They are bundled into the app at build time
(`ios/project.yml`, read by `ios/IPhoneAgent/Agent/Prompts.swift`).

- `actor.md`: the one model of a run. Each step it gets the goal, its own plan, the recent actions with what each
  did, and the screen; it replies THINK, an optional PLAN (rewrites the plan), and DO action(s), and says done when
  the whole goal is visible. Lists the action syntax the app parses.
- `app-rules.md`: rules for running inside the phone (never touch this app, toggles, home screen icons); appended
  to the actor prompt.
- `reader.md`: copies the items a `read` action asks for off one screen, for the notebook.
- `ipad/`: the same three files for an iPad, which gets them instead: its layouts (tab bars in the middle or a
  sidebar, panels and popovers, small targets), the dock, Split View and Slide Over, back on a left-hand pane.
  Change both sets together; the action syntax lines must stay word for word the same (PromptTests checks).

Edit, rebuild, and compare runs in the app's Runs tab. Keep the action list in `actor.md` in sync with
`ios/IPhoneAgent/Agent/Actions.swift`. Each file's final newline is not part of the prompt.
