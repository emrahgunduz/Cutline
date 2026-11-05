from cutline_helper.romanize_tr import romanize


def test_turkish_letters():
    assert romanize("Sığınakların") == "siginaklarin"
    assert romanize("değilmiş") == "degilmis"
    assert romanize("Yüzümü") == "yuzumu"
    assert romanize("Göğü") == "gogu"
    assert romanize("İnletse") == "inletse"
    assert romanize("IŞIK") == "isik"


def test_punctuation_and_apostrophes():
    assert romanize("de,") == "de"
    assert romanize("Ali’nin") == "ali'nin"
    assert romanize("—") == ""
    assert romanize("café") == "cafe"
