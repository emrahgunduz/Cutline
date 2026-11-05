import math

from cutline_helper.align import Word, cross_check, finalize, interpolate, match_words


def W(text, key, start=math.nan, end=math.nan, score=0.0, source="none", checked=False):
    return Word(text=text, key=key, start=start, end=end, score=score, confidence=score, source=source, checked=checked)


def test_substituted_word_still_pairs_the_rest():
    known = ["kor", "aynalarda", "yuzumu", "kaybedisim"]
    heard = ["kor", "aynalarla", "yuzunu", "kaybettim"]
    pairs = match_words(known, heard)
    assert (0, 0) in pairs and (1, 1) in pairs and (2, 2) in pairs


def test_extra_and_missing_words():
    pairs = dict(match_words(["rastlanti", "degilmis"], ["ah", "rastlanti", "degil", "mis"]))
    assert pairs[0] == 1


def test_unaligned_middle_word_is_interpolated_with_zero_confidence():
    ws = [W("a", "a", 1.0, 1.4, 0.9, "mms"), W("—", ""), W("c", "c", 2.0, 2.4, 0.9, "mms")]
    interpolate(ws)
    assert ws[1].source == "interpolated"
    assert ws[1].confidence == 0
    assert math.isclose(ws[1].start, 1.4) and math.isclose(ws[1].end, 2.0)


def test_whisper_agreement_raises_confidence_and_fills_unaligned_word():
    ws = [W("a", "kor", 1.0, 1.3, 0.4, "mms", checked=True),
          W("b", "ayna", checked=True),
          W("c", "yuz", 3.0, 3.3, 0.9, "mms")]
    cross_check(ws, [("kor", 1.1, 1.4), ("ayna", 2.0, 2.4)])
    assert ws[0].confidence > 0.6 and ws[0].start == 1.0
    assert ws[1].source == "whisper" and ws[1].start == 2.0 and ws[1].confidence < 0.6


def test_whisper_never_moves_an_mms_word():
    ws = [W("a", "kor", 1.0, 1.3, 0.9, "mms"),
          W("b", "ayna", 2.0, 2.3, 0.2, "mms", checked=True),
          W("c", "yuz", 3.0, 3.3, 0.9, "mms")]
    cross_check(ws, [("ayna", 2.6, 2.9)])
    assert ws[1].start == 2.0 and ws[1].source == "mms" and ws[1].confidence <= 0.4


def test_finalize_keeps_order_and_holds_short_words():
    ws = [W("a", "a", 1.0, 1.05), W("b", "b", 1.5, 1.6), W("c", "c", 1.4, 1.8)]
    finalize(ws)
    assert ws[0].end > 1.05 and ws[0].end < ws[1].start
    assert ws[2].start > ws[1].start
