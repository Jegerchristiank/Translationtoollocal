from transkriptor.editing import parse_editor_text


def test_parse_editor_text_parses_each_prefixed_line_without_merge():
    text = """
I: Hej og velkommen
I: til interviewet i dag
D: Tak for det.
D: Det er fint.
""".strip()

    parsed = parse_editor_text(text, [])
    assert len(parsed) == 4
    assert parsed[0]["speaker"] == "I"
    assert parsed[0]["text"] == "Hej og velkommen"
    assert parsed[1]["speaker"] == "I"
    assert parsed[1]["text"] == "til interviewet i dag"
    assert parsed[2]["speaker"] == "D"
    assert parsed[2]["text"] == "Tak for det."
    assert parsed[3]["speaker"] == "D"
    assert parsed[3]["text"] == "Det er fint."
    assert parsed[0]["startSec"] == 0.0
    assert parsed[0]["endSec"] == 1.0
    assert parsed[1]["startSec"] == 3.0
    assert parsed[2]["startSec"] == 6.0
    assert parsed[3]["startSec"] == 9.0


def test_parse_editor_text_requires_prefix_on_every_non_empty_line():
    invalid = """
I: Dette er ok
Dette er ikke ok
""".strip()

    try:
        parse_editor_text(invalid, [])
    except ValueError as exc:
        assert "Linje 2 mangler taler-prefix" in str(exc)
    else:
        raise AssertionError("Expected ValueError when a non-empty line has no speaker prefix")


def test_parse_editor_text_raises_when_no_speaker_prefix():
    invalid = "Dette er en linje uden speaker-prefix."
    try:
        parse_editor_text(invalid, [])
    except ValueError as exc:
        assert "Linje 1 mangler taler-prefix" in str(exc)
    else:
        raise AssertionError("Expected ValueError for invalid transcript format")


def test_parse_editor_text_raises_when_body_is_empty():
    invalid = "I:"
    try:
        parse_editor_text(invalid, [])
    except ValueError as exc:
        assert "Linje 1 er tom efter taler-prefix" in str(exc)
    else:
        raise AssertionError("Expected ValueError for empty speaker line")


def test_parse_editor_text_raises_when_line_is_blank():
    invalid = "I: Hej\n\nD: Hej tilbage"
    try:
        parse_editor_text(invalid, [])
    except ValueError as exc:
        assert "Linje 2 er tom" in str(exc)
    else:
        raise AssertionError("Expected ValueError for blank line")
