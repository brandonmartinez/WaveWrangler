import unittest

from benchmark import alignment, normalized, text_metrics


class ScoringTests(unittest.TestCase):
    def test_normalization_keeps_disfluencies(self):
        self.assertEqual(
            normalized("Um, I, I don't... uh - twenty-five favourites."),
            ["um", "i", "i", "don't", "uh", "twenty", "five", "favourites"],
        )

    def test_substitution_deletion_insertion(self):
        metrics = text_metrics(["um", "hello", "world"], ["hello", "earth", "today"])
        self.assertEqual(metrics["sub"] + metrics["del"] + metrics["ins"], 3)
        self.assertEqual(metrics["wer"], 1)
        self.assertEqual(metrics["matched_fillers"], 0)

    def test_fillers_must_match_in_sequence(self):
        metrics = text_metrics(["um", "we", "uh", "go"], ["um", "we", "go"])
        self.assertEqual(metrics["filler_recall"], 0.5)
        self.assertEqual(metrics["del"], 1)

    def test_empty_reference_is_not_zero_wer(self):
        metrics = text_metrics([], ["thank", "you"])
        self.assertIsNone(metrics["wer"])
        self.assertEqual(metrics["ins"], 2)
        self.assertIsNone(metrics["filler_recall"])

    def test_non_speech_label_is_not_lexical_hallucination(self):
        self.assertEqual(normalized("[BLANK_AUDIO]"), [])
        self.assertEqual(normalized("Thank you."), ["thank", "you"])

    def test_filler_insertions_reduce_precision(self):
        metrics = text_metrics(["um", "hello"], ["um", "uh", "hello"])
        self.assertEqual(metrics["filler_precision"], 0.5)
        self.assertEqual(metrics["filler_recall"], 1)

    def test_phonetic_content_word_is_not_a_recovered_filler(self):
        metrics = text_metrics(["um", "hello", "uh"], ["am", "hello", "a"])
        self.assertEqual(metrics["sub"], 2)
        self.assertEqual(metrics["matched_fillers"], 0)
        self.assertEqual(metrics["filler_recall"], 0)

    def test_exact_and_empty_alignment(self):
        self.assertEqual(alignment([], []), [])
        self.assertEqual(alignment(["i", "i"], ["i", "i"]), [("equal", 0, 0), ("equal", 1, 1)])


if __name__ == "__main__":
    unittest.main()
