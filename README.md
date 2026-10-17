# Video Toolkit

Native macOS-App (SwiftUI, macOS 14+) zum „Reparieren" schlecht aufgenommener Videos. **Alles läuft lokal** – die App
ist mit App-Sandbox **ohne Netzwerk-Berechtigung** signiert, macOS verhindert also technisch jede Internetverbindung.

## Bauen und starten

```bash
Scripts/build_app.sh          # erzeugt build/Video Toolkit.app (Release, ad-hoc signiert)
open "build/Video Toolkit.app"
```

Benötigt nur Swift 5.9+ (Command Line Tools genügen, Xcode ist nicht nötig).

## Funktionen

* **Automatische Diagnose** beim Laden: Belichtung, Schatten/Lichter, Kontrast, Farbstich, Sättigung, Rauschen,
  Schärfe, Gesichter im Gegenlicht (Apple Vision), Wackeln, Helligkeitsflackern, Auflösung – und im Ton:
  Rauschen, Netzbrummen (50/60 Hz), Dröhnen, Mulm/dumpfer Klang, S-Laute, Dynamik, Lautheit, Übersteuerung.
  Jedes Problem hat eine Empfehlung, die einzeln zu- und abgeschaltet werden kann; ein Regler skaliert die Stärke.
* **Einfach-Modus**: Diagnose → Häkchen setzen → Exportieren.
* **Experten-Modus**: alle Parameter (Licht, Farbe, Entrauschen, Schärfen, Stabilisierung, Flackern, Upscaling,
  Rauschminderung, Stimmen-Fokus, De-Esser, Kompressor, Lautheit, 5-Band-EQ), Vorher/Nachher-Schieber, Probehören.
* **Referenzbild**: Farben und Tonwerte des Videos werden per Histogramm-Matching (3D-LUT) an ein Bild angeglichen.
* **Audio**: spektrale Rauschminderung (Wiener-Filter mit Rauschprofil), Brummfilter, Sprach-Erkennung für
  „Stimme in den Vordergrund", Klarheits-EQ, Kompression, EBU-R128-Normalisierung, True-Peak-Limiter.

## Technik

| Bereich | Umsetzung |
|---|---|
| Video lesen/schreiben | AVFoundation (AVAssetReader/Writer), H.264 oder HEVC, Audio AAC |
| Bildverarbeitung | Core Image (GPU) |
| Stabilisierung | Vision `VNTranslationalImageRegistrationRequest` + Gauß-geglättete Kamerabahn |
| Gesichter | Vision (on-device) |
| Audio | eigene DSP-Kette mit Accelerate/vDSP (FFT, Biquads) |
| KI: Stimmen-Entrauschen | **DeepFilterNet3** (Core ML, INT8, 2 MB, Neural Engine) – ca. 6× Echtzeit |
| KI: Hochskalierung | **Real-ESRGAN x4v3** (Core ML, kachelweise) – langsam: ca. 0,65 s pro 540p-Frame |

Headless-Test: `.build/release/VideoToolkit --cli selftest | analyze <datei> | fix <ein> <aus>`.

## KI-Modelle (lokal, eingebettet)

Die Modelle liegen im Ordner `Models/` und werden in die App kopiert; die App lädt nichts nach. Quellen und Lizenzen:
siehe [Models/NOTICE.md](Models/NOTICE.md). Zeitliche Entrauschung, Stabilisierung und Referenzabgleich nutzen
klassische Verfahren bzw. Apple Vision.

## Grenzen (v1)

* Ausgabe ist 8 Bit SDR (HDR-Material wird nicht korrekt behandelt).
* Stabilisierung korrigiert Translation, keine Rotation/Rolling Shutter.
* Zeitliche Entrauschung (klassisch) und Hochskalierung sind erst im Export sichtbar, nicht in der Vorschau.
* KI-Hochskalierung ist rechenintensiv (1080p-Material: mehrere Sekunden pro Frame).
