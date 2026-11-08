# Ollama APK

[![CI](https://github.com/shubhamtaywade82/ollama-apk/actions/workflows/ci.yaml/badge.svg)](https://github.com/shubhamtaywade82/ollama-apk/actions/workflows/ci.yaml)

Android client for [Ollama](https://ollama.com): chat with models on your own
server, a LAN router, or Ollama Cloud.

> This app does not run models on the phone. It connects to an Ollama server.

## Features

- Streaming chat, multiple conversations, Markdown, image input for vision models
- Voice mode (speech-to-text and text-to-speech)
- **Multiple hosts** in priority order with live health checks
- **Automatic failover**: if the active host stops answering before a reply
  starts, the next healthy host takes over
- **Ollama Cloud** with an API key kept in Android Keystore-backed storage, plus
  a usage and balance screen (spend, tokens, per-model breakdown, credits left)
- **Models screen**: installed models, which are loaded and their VRAM use,
  unload and delete
- **Agent tools** (Settings → Behavior), sent only to models that report tool
  support:
  - web search and page fetch through Ollama Cloud
  - read-only Binance prices and candles; the app never places orders
  - tools from remote **MCP servers** (Streamable HTTP, optional bearer
    token; Settings → MCP servers). Add only servers you trust
- **Reasoning mode** for models that support thinking, streamed live into a
  collapsible "Thinking…" block above the answer
- Add Host checks the connection and warns when `localhost` would point at the
  phone itself
- Chats are stored in an app data file, not in preferences

## Connecting

On a phone, `localhost` is the phone itself. Use your computer's LAN address:

```text
http://192.168.1.100:11434
```

and start Ollama so it listens on the network:

```bash
OLLAMA_HOST=0.0.0.0 ollama serve
```

Add hosts under **Settings → Hosts**. Drag to reorder priority; tap to make one
active.

### Ollama Cloud

1. Create a key at [ollama.com/settings/keys](https://ollama.com/settings/keys)
2. Add host `https://ollama.com` with that key

The key is only ever sent to `https://ollama.com` over HTTPS, never to local or
custom hosts. `http://ollama.com` is upgraded to HTTPS automatically.

### Self-signed certificates

Not accepted. Put a trusted certificate on HTTPS hosts, or use plain HTTP on a
trusted LAN.

## Development

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

CI runs analyze, tests and a debug APK build on every push and pull request.
Pushing a `v*` tag builds per-ABI release APKs and publishes a GitHub release.
Release signing needs these repository secrets: `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`.

## License and attribution

Derived from [JHubi1/ollama-app](https://github.com/JHubi1/ollama-app),
licensed under Apache 2.0. See [LICENSE](LICENSE).
