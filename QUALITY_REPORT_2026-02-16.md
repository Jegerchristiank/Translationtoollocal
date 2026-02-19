# QA Report - 2026-02-16

## Scope
- Audio input: `/Users/christiankristensen/Translationtoollocal/eksempel-på-lydfiler/ID1.MP3` to `ID3.MP3`
- Human ground truth: `/Users/christiankristensen/Translationtoollocal/eksempler-på-allerede-menneske-transkriberet-interviews/ID1.docx` to `ID3.docx`
- Evaluated jobs: `qa-id1-v3`, `qa-id2-v3`, `qa-id3-v3` in `~/Library/Application Support/Transkriptor/jobs.db`

## Method
- Human transcript extracted from DOCX table column 3 and reconstructed into speaker turns (`I:` / `D:`).
- Model transcript loaded from `jobs.transcript_json`.
- Text normalized (lowercase, punctuation removed, whitespace collapsed).
- Metrics:
  - WER (word error rate)
  - CER (character error rate)
  - Role-aware WER (speaker-tag sequence, best with optional I/D swap)

## Baseline (before merge cleanup)
- ID1 WER: 0.2166 (match 78.34%)
- ID2 WER: 0.3564 (match 64.36%)
- ID3 WER: 0.6041 (match 39.59%)
- Average WER: 0.3923 (match 60.77%)

## After changes
Implemented in `/Users/christiankristensen/Translationtoollocal/python/transkriptor/merge.py`:
- filler filtering
- backchannel filtering
- technical meeting-noise filtering
- micro-interruption compaction
- adjacent same-speaker run merge

Final scores:
- ID1
  - WER: 0.2149 (match 78.51%)
  - CER: 0.1609 (match 83.91%)
  - Role-aware WER: 0.2219 (match 77.81%)
- ID2
  - WER: 0.3465 (match 65.35%)
  - CER: 0.2711 (match 72.89%)
  - Role-aware WER: 0.3519 (match 64.81%)
- ID3
  - WER: 0.5513 (match 44.87%)
  - CER: 0.4570 (match 54.30%)
  - Role-aware WER: 0.5656 (match 43.44%)

Average:
- WER: 0.3709 (match 62.91%)
- CER: 0.2963 (match 70.37%)

## Interpretation
- Improvement is consistent across ID1-ID3.
- Largest absolute gain is ID3, driven by removal of irrelevant technical-call chatter and compacting short interjections.
- Remaining gap appears mostly editorial:
  - human files condense dialogue more aggressively
  - some sensitive details and low-value utterances are omitted in ground truth
  - occasional ASR lexical errors remain

## OpenAI usage
- OpenAI API is used for transcription (`gpt-4o-transcribe-diarize` + `whisper-1` two-pass strategy).
