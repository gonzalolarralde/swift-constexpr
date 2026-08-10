#!/usr/bin/env python3
"""Synthetic checks for Package Index harness argument reproducibility."""

from __future__ import annotations

from pathlib import Path
import sys
import unittest
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parent))
import run as harness  # noqa: E402


class PackageIndexArgumentsTests(unittest.TestCase):
    def test_default_package_list_commit_is_pinned(self) -> None:
        with mock.patch.object(sys, "argv", ["run.py"]):
            options = harness.arguments()
        self.assertEqual(
            options.package_list_commit,
            "32b0256f7de1ab6385b550f21a1e10aabf923a2e",
        )
        self.assertEqual(
            harness.package_list_commit(None),
            harness.DEFAULT_PACKAGE_LIST_COMMIT,
        )

    def test_explicit_package_list_commit_overrides_pin(self) -> None:
        revision = "1" * 40
        with mock.patch.object(
            sys,
            "argv",
            ["run.py", "--package-list-commit", revision],
        ):
            options = harness.arguments()
        self.assertEqual(options.package_list_commit, revision)
        self.assertEqual(harness.package_list_commit(revision), revision)


if __name__ == "__main__":
    unittest.main()
