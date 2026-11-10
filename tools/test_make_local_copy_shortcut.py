"""Portable checks for the generated Shortcut; no signing identity or device is needed."""
import plistlib
import unittest

from make_local_copy_shortcut import workflow


class LocalCopyShortcutTests(unittest.TestCase):
    def setUp(self):
        self.workflow = workflow("org.example.handsy", "TESTTEAM")
        self.actions = self.workflow["WFWorkflowActions"]
        self.parameters = [a["WFWorkflowActionParameters"] for a in self.actions]

    def test_only_seven_local_actions_copy_and_read_back_before_acknowledging(self):
        self.assertEqual([a["WFWorkflowActionIdentifier"] for a in self.actions], [
            "org.example.handsy.GetLocalInputIntent", "is.workflow.actions.detect.dictionary",
            "is.workflow.actions.getvalueforkey", "is.workflow.actions.setclipboard",
            "is.workflow.actions.getclipboard", "is.workflow.actions.getvalueforkey",
            "org.example.handsy.CompleteLocalInputIntent",
        ])
        self.assertIs(self.parameters[3]["WFLocalOnly"], True)
        self.assertEqual(self.parameters[2]["WFDictionaryKey"], "text")
        self.assertEqual(self.parameters[5]["WFDictionaryKey"], "id")
        # Completion must return the clipboard read-back, not just echo the packet's text.
        returned = self.parameters[6]["copiedText"]["Value"]["attachmentsByRange"]["{0, 1}"]
        self.assertEqual(returned["OutputUUID"], self.parameters[4]["UUID"])
        request = self.parameters[6]["requestID"]["Value"]["attachmentsByRange"]["{0, 1}"]
        self.assertEqual(request["OutputUUID"], self.parameters[5]["UUID"])

    def test_all_output_references_are_unique_and_point_to_earlier_actions(self):
        ids = [p["UUID"] for p in self.parameters]
        self.assertEqual(len(ids), len(set(ids)))

        def references(value):
            if isinstance(value, dict):
                if "OutputUUID" in value:
                    yield value["OutputUUID"]
                for child in value.values():
                    yield from references(child)
            elif isinstance(value, list):
                for child in value:
                    yield from references(child)

        for index, parameters in enumerate(self.parameters):
            for reference in references(parameters):
                self.assertIn(reference, ids[:index])

    def test_identity_routes_both_intents_and_binary_plist_round_trips(self):
        for index in [0, 6]:
            descriptor = self.parameters[index]["AppIntentDescriptor"]
            self.assertEqual(descriptor["BundleIdentifier"], "org.example.handsy")
            self.assertEqual(descriptor["TeamIdentifier"], "TESTTEAM")
            self.assertIs(self.parameters[index]["ShowWhenRun"], False)
        blob = plistlib.dumps(self.workflow, fmt=plistlib.FMT_BINARY)
        self.assertEqual(plistlib.loads(blob), self.workflow)
        self.assertEqual(self.workflow["WFWorkflowInputContentItemClasses"], [])


if __name__ == "__main__":
    unittest.main()
