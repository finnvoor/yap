# 🗣️ yap

A CLI for on-device speech transcription using [Speech.framework](https://developer.apple.com/documentation/speech) on macOS 26.

![Demo](https://github.com/user-attachments/assets/326de51d-5a58-4c96-9d6c-98b07e6d9e58)

### Usage

```
USAGE: yap transcribe [--locale <locale>] [--censor] <input-file> [--txt] [--srt] [--output-file <output-file>]

ARGUMENTS:
  <input-file>            Path to an audio or video file to transcribe.

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt             Output format for the transcription. (default: --txt)
  -o, --output-file <output-file>
                          Path to save the transcription output. If not provided,
                          output will be printed to stdout.
  -h, --help              Show help information.
```

### Installation

#### Homebrew

```bash
brew install yap
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

### Live System Audio

`yap listen` transcribes system audio in real time — anything playing on your computer.

```
USAGE: yap listen [--locale <locale>] [--censor]

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  -h, --help              Show help information.
```

> Screen Recording permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Screen Recording.

#### Examples

```bash
# Transcribe system audio live
yap listen

# Pipe live transcription to another tool
yap listen | uvx llm 'Translate this to French:'
```

### Dictation

`yap dictate` transcribes microphone input in real time.

```
USAGE: yap dictate [--locale <locale>] [--censor]

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  -h, --help              Show help information.
```

> Microphone permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Microphone.

#### Examples

```bash
# Dictate from your microphone
yap dictate

# Dictate and save to a file
yap dictate > notes.txt
```

### MCP Server

yap includes an [MCP](https://modelcontextprotocol.io) server that exposes a `transcribe` tool, allowing any MCP-compatible agent to transcribe audio and video files.

#### Claude Code

```bash
claude mcp add yap -- yap mcp
```

#### Codex

```bash
codex mcp add yap -- yap mcp
```
