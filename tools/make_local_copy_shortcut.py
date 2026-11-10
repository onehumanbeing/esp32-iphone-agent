#!/usr/bin/env python3
"""Build the reviewable phone-only copy shortcut. Sign with Apple's `shortcuts sign` before importing.

The file contains no user text, key, URL or network action. Its app identity comes from the signed app.
Workflow encoding references: https://github.com/frontboat/shortcutkit (author's format/action reference).
This generator does not depend on or copy that package's code.
"""
import argparse
import json
import plistlib
import re
import subprocess
import uuid
from pathlib import Path


def attachment(action_id, name):
    return {"WFSerializationType": "WFTextTokenAttachment",
            "Value": {"Type": "ActionOutput", "OutputUUID": action_id, "OutputName": name}}


def text_reference(action_id, name):
    return {"WFSerializationType": "WFTextTokenString", "Value": {
        "string": "\ufffc", "attachmentsByRange": {"{0, 1}": attachment(action_id, name)["Value"]}}}


def workflow(bundle, team):
    actions = []

    def action(identifier, **parameters):
        identity = str(uuid.uuid4()).upper()
        parameters["UUID"] = identity
        actions.append({"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": parameters})
        return identity

    def intent(identifier, **parameters):
        return action(bundle + "." + identifier, AppIntentDescriptor={
            "TeamIdentifier": team, "BundleIdentifier": bundle, "Name": "ESP32 Agent",
            "AppIntentIdentifier": identifier}, ShowWhenRun=False, **parameters)

    packet = intent("GetLocalInputIntent")
    dictionary = action("is.workflow.actions.detect.dictionary", WFInput=attachment(packet, "Local Input Packet"))
    text = action("is.workflow.actions.getvalueforkey", WFDictionaryKey="text", WFGetDictionaryValueType="Value",
                  WFInput=attachment(dictionary, "Dictionary"))
    action("is.workflow.actions.setclipboard", WFInput=attachment(text, "Dictionary Value"), WFLocalOnly=True)
    copied = action("is.workflow.actions.getclipboard")
    request = action("is.workflow.actions.getvalueforkey", WFDictionaryKey="id", WFGetDictionaryValueType="Value",
                     WFInput=attachment(dictionary, "Dictionary"))
    intent("CompleteLocalInputIntent", requestID=text_reference(request, "Dictionary Value"),
           copiedText=text_reference(copied, "Clipboard"))
    return {
        "WFWorkflowName": "Handsy Local Copy", "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "4018.0.4", "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900", "WFWorkflowTypes": [], "WFQuickActionSurfaces": [],
        "WFWorkflowInputContentItemClasses": [], "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowImportQuestions": [], "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Info.plist").read_bytes())
    signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(args.app)], text=True, capture_output=True, check=True)
    team = re.search(r"^TeamIdentifier=(\w+)$", signature.stderr, re.M)
    if not team or team[1] == "not":
        raise SystemExit("Use a device-signed app so Shortcuts can route its App Intents.")
    metadata = json.loads((args.app / "Metadata.appintents/extract.actionsdata").read_text())
    for identifier in ["GetLocalInputIntent", "CompleteLocalInputIntent"]:
        if identifier not in metadata["actions"]:
            raise SystemExit("Build the app with the local copy App Intents first: " + identifier)
    result = workflow(info["CFBundleIdentifier"], team[1])
    assert len(result["WFWorkflowActions"]) == 7
    assert result["WFWorkflowActions"][3]["WFWorkflowActionParameters"]["WFLocalOnly"] is True
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(plistlib.dumps(result, fmt=plistlib.FMT_BINARY, sort_keys=False))
    print("Created seven local-only actions; no user text or network access included.")


if __name__ == "__main__":
    main()
