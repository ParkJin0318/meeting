#!/bin/zsh
set -euo pipefail

ROOT="${1:-$HOME/Library/Application Support/meeting/diarization}"
MODELS="$ROOT/models"
mkdir -p "$MODELS"

pick_python() {
  for candidate in python3.12 python3.11 python3.10 python3.13; do
    if command -v "$candidate" >/dev/null 2>&1; then echo "$candidate"; return; fi
  done
  echo python3
}

echo "▸ venv: $ROOT/venv"
if [ ! -x "$ROOT/venv/bin/python3" ]; then
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.12 "$ROOT/venv"
  else
    "$(pick_python)" -m venv "$ROOT/venv"
  fi
fi
"$ROOT/venv/bin/python3" -m pip install --quiet --upgrade pip
"$ROOT/venv/bin/python3" -m pip install --quiet sherpa-onnx numpy

RELEASES="https://github.com/k2-fsa/sherpa-onnx/releases/download"
SEG_DIR="$MODELS/sherpa-onnx-pyannote-segmentation-3-0"
EMB="$MODELS/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"

if [ ! -f "$SEG_DIR/model.onnx" ]; then
  echo "▸ 분할 모델(pyannote segmentation 3.0) 내려받기"
  curl -fL "$RELEASES/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2" \
    | tar xj -C "$MODELS"
fi
if [ ! -f "$EMB" ]; then
  echo "▸ 화자 임베딩 모델(3D-Speaker ERes2Net) 내려받기"
  curl -fL -o "$EMB" \
    "$RELEASES/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
fi

echo "▸ 확인"
"$ROOT/venv/bin/python3" -c "import sherpa_onnx, numpy; print('  sherpa-onnx', sherpa_onnx.__version__)"
ls -la "$SEG_DIR/model.onnx" "$EMB"
echo "✓ 완료 — 앱 설정 화면의 화자 구분 상태가 '준비됨'으로 바뀝니다 (앱을 다시 조립하려면 설정을 한 번 저장하십시오)"
