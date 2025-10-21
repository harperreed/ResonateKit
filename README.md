# ResonateKit

A Swift client library for the [Resonate Protocol](https://github.com/Resonate-Protocol/spec) - enabling synchronized multi-room audio playback on Apple platforms.

## Features

- 🎵 **Player Role**: Synchronized audio playback with microsecond precision
- 🎛️ **Controller Role**: Control playback across device groups
- 📝 **Metadata Role**: Display track information and progress
- 🔍 **Auto-discovery**: mDNS/Bonjour server discovery
- 🎵 **Multi-codec**: FLAC, Opus, and PCM support
- ⏱️ **Clock Sync**: NTP-style time synchronization

## Requirements

- iOS 17.0+ / macOS 14.0+ / tvOS 17.0+ / watchOS 10.0+
- Swift 6.0+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/YOUR_ORG/ResonateKit.git", from: "0.1.0")
]
```

## Quick Start

```swift
import ResonateKit

// Create client with player role
let client = ResonateClient(
    clientId: "my-device",
    name: "Living Room Speaker",
    roles: [.player],
    playerConfig: PlayerConfiguration(
        bufferCapacity: 1_048_576, // 1MB
        supportedFormats: [
            AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48000, bitDepth: 16),
            AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44100, bitDepth: 16),
        ]
    )
)

// Discover servers
let discovery = ResonateDiscovery()
await discovery.startDiscovery()

for await server in discovery.discoveredServers {
    if let url = await discovery.resolveServer(server) {
        try await client.connect(to: url)
        break
    }
}

// Client automatically handles:
// - WebSocket connection
// - Clock synchronization
// - Audio stream reception
// - Synchronized playback
```

## License

Apache 2.0
