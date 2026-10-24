#!/usr/bin/env python3
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from build_number import write_build_number


class BuildNumberTests(unittest.TestCase):
    def test_utc_millisecond_stamp_and_header(self):
        with tempfile.TemporaryDirectory() as folder:
            header = Path(folder) / "generated" / "BuildNumber.h"
            number = write_build_number(header, datetime(2026, 10, 23, 3, 30, 1, 123456, tzinfo=timezone.utc))
            self.assertEqual(number, "20261023033001123")
            self.assertEqual(header.read_text(), f"#define WW_BUILD_NUMBER {number}\n")

    def test_repeated_clock_and_clock_rollback_still_advance(self):
        with tempfile.TemporaryDirectory() as folder:
            header = Path(folder) / "BuildNumber.h"
            now = datetime(2026, 10, 23, tzinfo=timezone.utc)
            first = write_build_number(header, now)
            second = write_build_number(header, now)
            third = write_build_number(header, datetime(2026, 10, 22, tzinfo=timezone.utc))
            self.assertEqual(int(second), int(first) + 1)
            self.assertEqual(int(third), int(second) + 1)

    def test_invalid_existing_metadata_is_an_explicit_error(self):
        with tempfile.TemporaryDirectory() as folder:
            header = Path(folder) / "BuildNumber.h"
            header.write_text("invalid metadata")
            with self.assertRaisesRegex(ValueError, "Invalid generated build-number header"):
                write_build_number(header)


if __name__ == "__main__":
    unittest.main()
