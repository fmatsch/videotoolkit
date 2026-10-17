#!/bin/bash
# Lädt die optionalen, großen Core-ML-Modelle nach Models/Optional/ (werden nicht ins Repo eingecheckt).
# Aufruf:  Scripts/fetch_models.sh [whisper|demucs|all]
#   whisper  OpenAI Whisper large-v3 turbo (Core ML, WhisperKit-Format, ca. 640 MB) + Tokenizer – für Untertitel/Pausenschnitt
#   demucs   HTDemucs-ft fused (Core ML, ca. 411 MB) – Stimme vom Hintergrund trennen (Lizenz der Gewichte: siehe Models/NOTICE.md)
# Danach die App neu bauen (Scripts/build_app.sh) oder die Ordner über „Modelle“ in der App importieren.
set -euo pipefail
cd "$(dirname "$0")/.."
WHAT="${1:-all}"
OUT="Models/Optional"
mkdir -p "$OUT"

hf_download_dir() {   # repo  pfad-im-repo  zielordner
  python3 -I - "$1" "$2" "$3" <<'PY'
import json, sys, os, subprocess, urllib.request
repo, path, dest = sys.argv[1:4]
def tree(p):
    url = f"https://huggingface.co/api/models/{repo}/tree/main/{p}".rstrip("/")
    return json.load(urllib.request.urlopen(url, timeout=60))
def walk(p):
    for f in tree(p):
        if f["type"] == "directory": yield from walk(f["path"])
        else: yield f["path"]
for fp in walk(path):
    rel = fp[len(path):].lstrip("/") if path else fp
    target = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if os.path.exists(target) and os.path.getsize(target) > 0: continue
    print("lade", rel, flush=True)
    subprocess.check_call(["curl", "-sfL", "--retry", "3", "-o", target + ".part", f"https://huggingface.co/{repo}/resolve/main/{fp}"])
    os.rename(target + ".part", target)
PY
}

if [[ "$WHAT" == "whisper" || "$WHAT" == "all" ]]; then
  W="$OUT/whisper-large-v3-turbo"
  hf_download_dir argmaxinc/whisperkit-coreml openai_whisper-large-v3-v20240930_turbo_632MB "$W"
  for f in tokenizer.json tokenizer_config.json; do      # Tokenizer neben dem Modell, damit nichts nachgeladen werden muss
    [ -s "$W/$f" ] || curl -sfL --retry 3 -o "$W/$f" "https://huggingface.co/openai/whisper-large-v3-turbo/resolve/main/$f"
  done
  echo "Whisper bereit: $W"
fi

if [[ "$WHAT" == "demucs" || "$WHAT" == "all" ]]; then
  D="$OUT/htdemucs-ft-fused"
  mkdir -p "$D"
  if [ ! -d "$D/htdemucs_ft_fused.mlpackage" ]; then
    curl -fL --retry 3 -o "$D/model.zip" "https://huggingface.co/raindog-audio-instruments/htdemucs-ft-fused-coreml/resolve/main/htdemucs_ft_fused.mlpackage.zip"
    echo "edecbac3c8610360d8fb0e5370406fdf900742462f7bb66e2f3a6515800614b3  $D/model.zip" | shasum -a 256 -c -
    (cd "$D" && unzip -q model.zip && rm model.zip)
  fi
  echo "Demucs bereit: $D"
fi
