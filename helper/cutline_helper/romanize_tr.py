"""Turkish (and general Latin) text to the a-z alphabet of the MMS aligner.

Used only for alignment input; the original words are kept for display (U10).
"""
import unicodedata

_TR = str.maketrans({
    "ş": "s", "Ş": "s", "ğ": "g", "Ğ": "g", "ı": "i", "I": "i", "İ": "i",
    "ç": "c", "Ç": "c", "ö": "o", "Ö": "o", "ü": "u", "Ü": "u",
    "â": "a", "Â": "a", "î": "i", "Î": "i", "û": "u", "Û": "u",
})
ALPHABET = set("abcdefghijklmnopqrstuvwxyz'")


def romanize(word: str) -> str:
    """'Sığınakların' -> 'siginaklarin'. Characters outside a-z and ' are dropped."""
    s = word.translate(_TR)
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = s.replace("’", "'").replace("`", "'")
    out = "".join(c for c in s if c in ALPHABET).strip("'")
    return out
