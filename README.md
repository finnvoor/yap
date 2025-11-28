# 🗣️ yap

A CLI for on-device speech transcription using [Speech.framework](https://developer.apple.com/documentation/speech) on macOS 26.

![Demo](https://github.com/user-attachments/assets/326de51d-5a58-4c96-9d6c-98b07e6d9e58)

### Usage

```
USAGE: yap transcribe [--locale <locale>] [--censor] [--output-locale <output-locale>] <input-file> [--txt] [--srt] [--output-file <output-file>]

ARGUMENTS:
  <input-file>            Path to an audio or video file to transcribe.

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  -ol, --output-locale <output-locale>
                          Locale to translate the transcription to (e.g., de_DE, fr_FR, es_ES).
  --txt/--srt             Output format for the transcription. (default: --txt)
  -o, --output-file <output-file>
                          Path to save the transcription output. If not provided,
                          output will be printed to stdout.
  -h, --help              Show help information.
```

### Installation

#### Homebrew

```bash
brew install finnvoor/tools/yap
```

#### Mint

```bash
mint install finnvoor/yap
```

### Examples

#### Transcribe a YouTube video using yap and [yt-dlp](https://github.com/yt-dlp/yt-dlp)

```bash
yt-dlp "https://www.youtube.com/watch?v=ydejkIvyrJA" -x --exec yap
```

#### Summarize a video using yap and [llm](https://llm.datasette.io/en/stable)

```bash
yap video.mp4 | uvx llm -m mlx-community/Llama-3.2-1B-Instruct-4bit 'Summarize this transcript:'
```

#### Create SRT captions for a video

```bash
yap video.mp4 --srt -o captions.srt
```

#### Transcribe and translate a video to German

```bash
yap video.mp4 -l ja_JP --output-locale de_DE -o transcript_de.txt
```

**Note**: Translation requires the corresponding language models to be installed in **System Settings > General > Language & Region > Translation Languages**. For example, to translate Japanese to German, you need to install the Japanese → German translation model.
