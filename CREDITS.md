# Credits

## Frameworks & libraries

| Name | Description | License |
|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | On-device speaker diarization (Sortformer) and speaker embeddings (CAM++) on Apple Silicon | [Apache-2.0](https://github.com/FluidInference/FluidAudio/blob/main/LICENSE) |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | Model Context Protocol server for Claude Code | [MIT](https://github.com/modelcontextprotocol/swift-sdk/blob/main/LICENSE) |
| [Sparkle](https://sparkle-project.org) | App updates | [MIT](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE) |
| SwiftNIO, swift-log, swift-system, EventSource | Dependencies of the MCP Swift SDK | Apache-2.0 / Apache-2.0 / Apache-2.0 / MIT |

## Models (downloaded at first run, not bundled)

| Model | Use | License |
|---|---|---|
| [NVIDIA Streaming Sortformer](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml) (CoreML conversion by FluidInference) | Who spoke when | [NVIDIA Open Model License](https://developer.nvidia.com/open-model-license) |
| CAM++ speaker embedding (CoreML conversion by FluidInference) | Recognizing Aaron's voice | Upstream [FunASR / ModelScope](https://github.com/modelscope/FunASR) model license |
| Apple on-device speech model | Speech to text | Part of macOS |

## Fonts

| Font | Author | License |
|---|---|---|
| Myriad Pro, Minion Pro | Adobe | Northwoods brand license (from `NorthwoodsCommunityChurch/northwoods-brand`) |

## Icons & assets
- Northwoods symbol from `NorthwoodsCommunityChurch/northwoods-brand`
- SF Symbols (Apple) for utility icons

## Tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), Swift Package Manager, Xcode

## Inspiration
- Whisper Verses (Northwoods) — SpeechAnalyzer and process-tap patterns
- Apple sample "Capturing system audio with Core Audio taps"
