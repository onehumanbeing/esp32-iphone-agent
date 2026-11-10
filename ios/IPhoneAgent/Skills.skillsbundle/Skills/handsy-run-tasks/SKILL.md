---
name: handsy-run-tasks
description: Guides Siri through multi-step work with ESP32 Agent (Handsy), which operates a real iPhone by looking at the screen and tapping, swiping and typing. Use when a request needs a phone task done or a recorded run replayed, and more than one step or tool may be involved.
---

# Working with ESP32 Agent (Handsy)

ESP32 Agent drives a physical iPhone through a board plugged into it. It sees the phone's screen and
moves the pointer, so it can do what a person would do by hand. Every task is one run, and every run
is recorded so it can be replayed.

Use the tools by what they do:

- **run a task on this iPhone** — starts a run from one sentence.
- **check the run** — whether the board, Screen Mirroring, the pointer and the model are ready,
  and what the current or last run is doing.
- **stop the run** — stops the run in progress.
- **replay a run** — opens a recorded run so the person can go through its steps.

## Turning a request into one task sentence

A run takes a single sentence describing the goal and the app to use in it. Write that sentence
from what the person said, in their language, then start the run.

Keep it to the goal, not to the steps. The run works out its own steps by looking at the screen,
so naming menus or buttons is wasted and can be wrong. The phone in the person's hand may differ
from what either of you expects.

Include the app when the request implies one. "Find cafés near me" is weaker than "Find cafés near
me in Google Maps", because the run has to start somewhere.

Ask one short clarifying question only when the goal is genuinely ambiguous — which app, or which
of two very different outcomes. Do not interview the person for details the run can see on screen.

## Before a run starts

Starting a run needs the board connected, Screen Mirroring on, the pointer calibrated and a model
chosen. The person sets these up in the app; no tool can do it.

When a run cannot start, it says what is missing. Relay that in one sentence and offer to open the
app, rather than retrying — the missing piece is on the phone, not in the request.

A run needs the person's agreement before screenshots and the task go to the model they configured.
If the run reports that, tell them to open ESP32 Agent and allow it, then ask again. Do not work
around it.

## While a run is going

A run puts the phone to work. The app goes to the Home Screen and the person watches progress in a
Live Activity, so the app is not in the foreground while the run works.

Do not start a second run while one is going: check the run, and offer to stop the current run
if the person wants the new one instead.

If the run says it needs help, it has stopped at a screen it cannot handle. Tell the person what it
is stuck on and let them decide: continue after they fix it, or stop. Never claim a run is still
going once it has asked for help.

## Replaying and reporting

Every run is recorded step by step with the screen it saw. To walk someone through what happened,
replay the run — it opens the same review screen a tap on the run in the list opens. Refer to runs by
the task sentence, and prefer the most recent one when the person says "the last one".

When reporting, say what the run did in plain words and whether it finished. Do not read out raw
steps or screen coordinates, and do not present a run that stopped early as done.

## Boundaries

The phone holds the person's accounts, messages and money. Before anything that spends money, sends
a message or email, posts, calls someone, deletes data, or changes a password or security setting,
ask the person to confirm, and pass the task along only after they agree.

If a task needs a password, passcode, Face ID or a one-time code, the run waits and the person does that
on the phone. Do not ask them to say such a value out loud to you. When they are done they tap Continue
and the run goes on.

Help: support@handsy.tech
