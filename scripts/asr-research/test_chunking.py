import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from chunking import score


class ChunkingMetricsTests(unittest.TestCase):
    def test_untimed_words_stay_in_wer_but_not_in_common_timing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "chunking"
            directory.mkdir()
            manifest = {"clips": [{"id": "generated", "words": [
                {"text": "um", "start": 1, "end": 1.5},
                {"text": "hello", "start": 2, "end": 2.5},
            ]}]}
            (directory / "manifest.json").write_text(json.dumps(manifest))
            for mode, onset in (("fixed", 0.5), ("pause", 1)):
                actual = {"clips": [{
                    "segments": [{"text": "um", "start": onset, "end": onset + 0.5},
                                 {"text": "hello", "start": 2, "end": 2.5},
                                 {"text": "uh"}],
                    "windows": [{"core": [0, 144000], "candidate": [0, 144000]}],
                    "planning_seconds": 0.001, "wall_seconds": 1,
                }]}
                (directory / f"outputs-baseEnglish-{mode}.json").write_text(json.dumps(actual))
            with contextlib.redirect_stdout(io.StringIO()):
                score(root)
            results = json.loads((directory / "summary.json").read_text())
            self.assertEqual(len(results), 2)
            for result in results:
                self.assertEqual(result["ins"], 1)
                self.assertEqual(result["matched_fillers"], 1)
                self.assertEqual(result["hypothesis_fillers"], 2)
                self.assertEqual(result["timing_boundaries"], 4)
                self.assertEqual(result["wer"], 0.5)
            common = json.loads((directory / "timing-common.json").read_text())
            self.assertEqual([row["common_fillers"] for row in common], [1, 1])
            self.assertEqual([row["common_boundaries"] for row in common], [4, 4])
            self.assertEqual([row["filler_mean_signed_onset"] for row in common], [-0.5, 0])
            self.assertEqual([row["filler_onset_p95"] for row in common], [0.5, 0])


if __name__ == "__main__":
    unittest.main()
