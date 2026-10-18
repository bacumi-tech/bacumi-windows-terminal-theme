"""Check the files Windows Terminal consumes, not a private workspace dependency."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
ANSI = "black red green yellow blue purple cyan white brightBlack brightRed brightGreen brightYellow brightBlue brightPurple brightCyan brightWhite".split()


def contrast(first, second):
    def luminance(value):
        rgb = [int(value[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in rgb]
        return sum(v * weight for v, weight in zip(linear, (.2126, .7152, .0722)))
    a, b = sorted((luminance(first), luminance(second)))
    return (b + .05) / (a + .05)


class Schemes(unittest.TestCase):
    def test_fragment_adds_only_two_schemes(self):
        fragment = json.loads((ROOT / "fragments/bacumi.json").read_text())
        self.assertEqual(set(fragment), {"schemes"})
        self.assertEqual([s["name"] for s in fragment["schemes"]], ["Bacumi Dark", "Bacumi Light"])
        for mode, scheme in zip(("dark", "light"), fragment["schemes"]):
            with self.subTest(mode=mode):
                self.assertEqual(scheme, json.loads((ROOT / f"schemes/bacumi-{mode}.json").read_text()))
                self.assertEqual(set(scheme), set(ANSI + ["name", "foreground", "background", "cursorColor", "selectionBackground"]))
                for key, value in scheme.items():
                    if key != "name":
                        self.assertRegex(value, r"^#[0-9A-F]{6}$")
                for key in ANSI + ["foreground"]:
                    self.assertGreaterEqual(contrast(scheme[key], scheme["background"]), 4.5, key)
                self.assertGreaterEqual(contrast(scheme["cursorColor"], scheme["background"]), 3)
                self.assertGreaterEqual(contrast(scheme["foreground"], scheme["selectionBackground"]), 4.5)

    def test_bacumi_identity_and_purple_mapping(self):
        dark = json.loads((ROOT / "schemes/bacumi-dark.json").read_text())
        light = json.loads((ROOT / "schemes/bacumi-light.json").read_text())
        self.assertEqual((dark["background"], dark["foreground"], dark["purple"], dark["brightPurple"]),
                         ("#17191F", "#D8D9DD", "#C8AFD6", "#DBC2E9"))
        self.assertEqual((light["background"], light["foreground"], light["purple"], light["brightPurple"]),
                         ("#FAFAF8", "#30343C", "#73508A", "#694280"))


if __name__ == "__main__":
    unittest.main()
