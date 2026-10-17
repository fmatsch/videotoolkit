# Eingebettete KI-Modelle (laufen ausschließlich lokal über Core ML)

## DeepFilterNet3 – Sprachverbesserung
* Modell: Rikorose/DeepFilterNet (DeepFilterNet3), Apache-2.0 / MIT
* Core-ML-Konvertierung (INT8): https://huggingface.co/aufklarer/DeepFilterNet3-CoreML (Apache-2.0)
* Die Signalverarbeitung um das Netz (STFT, ERB-Filterbank, Normalisierung, Deep-Filtering) ist eine eigene Swift-Umsetzung
  nach dem Ablauf des Projekts soniqo/speech-swift (Apache-2.0).

## Real-ESRGAN x4v3 – Hochskalierung
* Modell: xinntao/Real-ESRGAN (realesr-general-x4v3), BSD-3-Clause
* Core-ML-Konvertierung: https://huggingface.co/VincentGOURBIN/RealESRGAN-CoreML (BSD-3-Clause)
