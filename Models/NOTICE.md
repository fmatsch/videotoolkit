# Eingebettete KI-Modelle (laufen ausschließlich lokal über Core ML)

## DeepFilterNet3 – Sprachverbesserung
* Modell: Rikorose/DeepFilterNet (DeepFilterNet3), Apache-2.0 / MIT
* Core-ML-Konvertierung (INT8): https://huggingface.co/aufklarer/DeepFilterNet3-CoreML (Apache-2.0)
* Die Signalverarbeitung um das Netz (STFT, ERB-Filterbank, Normalisierung, Deep-Filtering) ist eine eigene Swift-Umsetzung
  nach dem Ablauf des Projekts soniqo/speech-swift (Apache-2.0).

## Real-ESRGAN x4v3 – Hochskalierung
* Modell: xinntao/Real-ESRGAN (realesr-general-x4v3), BSD-3-Clause
* Core-ML-Konvertierung: https://huggingface.co/VincentGOURBIN/RealESRGAN-CoreML (BSD-3-Clause)

## Optionale Modelle (nicht im Repository; `Scripts/fetch_models.sh`)

### Whisper large-v3 turbo – Spracherkennung
* Modell: OpenAI Whisper (MIT); Core-ML-Konvertierung im WhisperKit-Format: https://huggingface.co/argmaxinc/whisperkit-coreml (MIT)
* Tokenizer-Dateien: https://huggingface.co/openai/whisper-large-v3-turbo (Apache-2.0)
* Laufzeitbibliothek: WhisperKit (argmaxinc, MIT), als Swift-Paket eingebunden

### HTDemucs ft (fused) – Stimme/Hintergrund trennen
* Modell: Meta Demucs (Code: MIT); Core-ML-Konvertierung: https://huggingface.co/raindog-audio-instruments/htdemucs-ft-fused-coreml
* **Hinweis zur Lizenz der Gewichte:** Der Konvertierer verweist auf eine frühere MIT-Kennzeichnung des Upstream-Modells, die später entfernt wurde;
  Meta hatte die Gewichte früher „für wissenschaftliche Zwecke“ freigegeben. Aus diesem Grund wird das Modell **nicht** mit der App ausgeliefert –
  jede Person lädt es selbst und prüft die Lizenz für ihren Einsatzzweck.
