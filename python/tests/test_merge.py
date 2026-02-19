from transkriptor.merge import merge_and_label
from transkriptor.models import Segment


def test_merge_and_label_prefers_question_driver_as_interviewer():
    segments = [
        Segment(start_sec=0.0, end_sec=3.0, speaker="A", text="Kan du starte med at fortælle om din baggrund?", confidence=0.9),
        Segment(start_sec=3.1, end_sec=7.0, speaker="B", text="Ja, jeg arbejder som fysioterapeut i Aarhus.", confidence=0.9),
        Segment(start_sec=7.1, end_sec=9.2, speaker="A", text="Hvornår fik du første symptomer?", confidence=0.9),
    ]

    result = merge_and_label(segments)
    assert result[0]["speaker"] == "I"
    assert result[1]["speaker"] == "D"
    assert result[2]["speaker"] == "I"


def test_merge_and_label_respects_ratio_for_multiple_interviewers():
    segments = [
        Segment(start_sec=0.0, end_sec=2.5, speaker="A", text="Kan du kort præsentere dig selv?", confidence=0.9),
        Segment(start_sec=2.6, end_sec=6.5, speaker="B", text="Jeg hedder Mette og arbejder i en børnehave.", confidence=0.9),
        Segment(start_sec=6.6, end_sec=9.0, speaker="C", text="Hvordan oplevede du onboarding-forløbet?", confidence=0.9),
        Segment(start_sec=9.1, end_sec=12.0, speaker="B", text="Det var tydeligt, men lidt for komprimeret.", confidence=0.9),
    ]

    result = merge_and_label(
        segments,
        interviewer_count=2,
        participant_count=1,
    )

    speaker_codes = [str(row["speaker"]) for row in result]
    assert speaker_codes.count("I") >= 2
    assert speaker_codes.count("D") >= 1
