# Third-party notices

FlowType packages the following third-party components for local transcription.

## whisper.cpp

- Project: https://github.com/ggml-org/whisper.cpp
- Release: `v1.9.1`
- Source commit: `f049fff95a089aa9969deb009cdd4892b3e74916`
- License: MIT; see `ThirdPartyLicenses/whisper.cpp-LICENSE.txt`

The release build compiles `whisper-cli` from that pinned commit as a static,
universal macOS executable. The upstream source and compiled binary are not
committed to this repository; the binary is generated for release packages.

The CLI's built-in audio decoding also compiles these upstream single-file
libraries from the same pinned whisper.cpp source tree:

- miniaudio `v0.11.24`, Copyright 2025 David Reid, MIT No Attribution;
  see `ThirdPartyLicenses/miniaudio-MIT-0-LICENSE.txt`.
- stb_vorbis `v1.22`, Copyright 2017 Sean Barrett, MIT;
  see `ThirdPartyLicenses/stb_vorbis-LICENSE.txt`.

## OpenAI Whisper model

- Project: https://github.com/openai/whisper
- Converted model host: https://huggingface.co/ggerganov/whisper.cpp
- File: `ggml-small.en.bin`
- Pinned repository revision: `c521a4b02f422512d734391fdf08bb08c0862f68`
- Expected size: `487614201` bytes
- SHA-256: `c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d`
- License: MIT; see `ThirdPartyLicenses/openai-whisper-LICENSE.txt`

The model is not inside the FlowType download. FlowType downloads it only when
the user selects **Install Offline Model**, verifies both its byte size and
SHA-256 digest, and stores it in the user's FlowType Application Support folder.
