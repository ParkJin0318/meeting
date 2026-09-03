#!/usr/bin/env python3
"""미팅 오디오 화자 분리 — sherpa-onnx 로컬 실행 (MeetingCore SherpaDiarizer 계약).

사용:   python3 diarize.py <오디오 경로>
출력:   [{"speaker": "S1", "start": 0.0, "end": 3.2}, ...]  (stdout 한 줄)

모델은 pyannote segmentation ONNX 변환본 + 3D-Speaker 임베딩 — k2-fsa GitHub
릴리즈에서 배포돼 HuggingFace 계정·토큰·약관 동의가 필요 없고, 실행은 전부 로컬이다.
앱(ShellProcessRunner)은 PATH의 python3로 이 스크립트를 부른다 — 어떤 파이썬이든
아래 재실행 가드가 sherpa-onnx가 설치된 전용 venv 파이썬으로 갈아탄다.
설치 구성: $MEETING_DIARIZATION_ROOT/{venv,models} (기본 ~/Library/Application Support/meeting/diarization)
"""
import json
import os
import subprocess
import sys
import tempfile
import wave

BASE = os.environ.get("MEETING_DIARIZATION_ROOT") or os.path.expanduser(
    "~/Library/Application Support/meeting/diarization")
VENV_PYTHON = os.path.join(BASE, "venv/bin/python3")
SEGMENTATION_MODEL = os.path.join(
    BASE, "models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx")
EMBEDDING_MODEL = os.path.join(
    BASE, "models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")

if (os.path.exists(VENV_PYTHON)
        and os.path.realpath(sys.executable) != os.path.realpath(VENV_PYTHON)):
    os.execv(VENV_PYTHON, [VENV_PYTHON, os.path.abspath(__file__)] + sys.argv[1:])

def read_mono_16k(audio_path: str):
    """어떤 입력 포맷이든 afconvert(macOS 내장)로 16kHz mono PCM 변환해 float32로 읽는다"""
    import numpy as np
    with tempfile.TemporaryDirectory() as tmp:
        wav_path = os.path.join(tmp, "audio.wav")
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
             audio_path, wav_path],
            check=True, capture_output=True)
        with wave.open(wav_path, "rb") as w:
            frames = w.readframes(w.getnframes())
    return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0

def main() -> int:
    if len(sys.argv) != 2:
        print("사용법: diarize.py <오디오 경로>", file=sys.stderr)
        return 2
    audio_path = sys.argv[1]
    if not os.path.exists(audio_path):
        print(f"오디오 파일이 없습니다: {audio_path}", file=sys.stderr)
        return 1
    for model in (SEGMENTATION_MODEL, EMBEDDING_MODEL):
        if not os.path.exists(model):
            print(f"모델 파일이 없습니다: {model}", file=sys.stderr)
            return 1

    import sherpa_onnx

    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=SEGMENTATION_MODEL)),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=EMBEDDING_MODEL),
        clustering=sherpa_onnx.FastClusteringConfig(threshold=0.8),
    )
    sd = sherpa_onnx.OfflineSpeakerDiarization(config)

    result = sd.process(read_mono_16k(audio_path)).sort_by_start_time()

    turns = []
    labels = {}
    for seg in result:
        if seg.speaker not in labels:
            labels[seg.speaker] = f"S{len(labels) + 1}"
        turns.append({
            "speaker": labels[seg.speaker],
            "start": round(seg.start, 3),
            "end": round(seg.end, 3),
        })
    print(json.dumps(turns, ensure_ascii=False))
    return 0

if __name__ == "__main__":
    sys.exit(main())
