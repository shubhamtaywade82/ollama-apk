# Hearth: chat for Ollama

[![CI](https://github.com/shubhamtaywade82/ollama-apk/actions/workflows/ci.yaml/badge.svg)](https://github.com/shubhamtaywade82/ollama-apk/actions/workflows/ci.yaml)

**Your AI, at home.** Hearth is an Android client for
[Ollama](https://ollama.com): chat with models on your own server, a router on
your LAN, or Ollama Cloud.

> Hearth does not run models on the phone. It connects to an Ollama server.

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
  - read-only Binance prices and candles; Hearth never places orders
  - tools from remote **MCP servers** (Streamable HTTP, optional bearer
    token; Settings → MCP servers). Add only servers you trust
- **Reasoning mode** for models that support thinking, streamed live into a
  collapsible "Thinking…" block above the answer
- Attachments: files and PDFs in messages
- Copy, read aloud and regenerate actions under replies
- Add Host checks the connection and warns when `localhost` would point at the
  phone itself
- Chats are stored in an app data file, not in preferences

## Install

Download the latest APK from
[GitHub Releases](https://github.com/shubhamtaywade82/ollama-apk/releases) and
install it on your Android device.

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

### Releases

Releases are automated with [release-please](https://github.com/googleapis/release-please),
driven by [Conventional Commit](https://www.conventionalcommits.org) messages
on `main` (PR titles, since PRs are squash-merged):

| Commit | Release |
|---|---|
| `fix: …` | patch (1.3.1 → 1.3.2) |
| `feat: …` | minor (1.3.1 → 1.4.0) |
| `feat!: …` or a `BREAKING CHANGE:` footer | major |
| `chore:`, `docs:`, `ci:`, `test:`, `refactor:` | none |

release-please keeps one "chore: release x.y.z" PR open with the version bump
and changelog. Merging it tags the release and builds, signs and attaches the
APKs (one universal, plus per-ABI). Pushing a `v*` tag by hand does the same.

Release signing needs these repository secrets: `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`. Without them the release
job fails rather than publishing a debug-signed APK.

### Google Play

Every release also builds a signed App Bundle (`.aab`), kept for 30 days as the
`play-bundle-v<version>` artifact of the Release workflow run. Uploading it to
Google Play is switched off until credentials exist: without them the
`Upload to Google Play` job is skipped (the run stays green) and the GitHub
release with APKs works as usual.

One-time setup:

1. Create a Google Play developer account and the app in Play Console
   (package `com.shubhamtaywade82.ollamaapk`). Complete the store listing: the
   icon and feature graphic are in `assets/brand/` (also under
   `fastlane/metadata/android/en-US/images/`); Play also needs at least two
   phone screenshots, taken from the current app.
2. **Choose the app signing key before the first upload.** Play re-signs every
   app with an app signing key. By default Google generates one, which means
   copies installed from Play and copies installed from the GitHub APKs cannot
   update each other. To keep both channels interchangeable, choose *Export and
   upload a key from Java keystore* in the app signing setup and follow Play's
   PEPK instructions with this project's release keystore (the same one behind
   the `ANDROID_KEYSTORE_*` secrets). This can only be changed before a release
   rolls out to open testing or production.
3. Upload the first `.aab` by hand (Play's API cannot create an app). Take it
   from the `play-bundle` artifact of the latest Release run.
4. In Google Cloud, create a service account, enable the Google Play Android
   Developer API, and create a JSON key. In Play Console → *Users and
   permissions*, invite the service account and give it release permissions for
   this app.
5. Add the JSON key as the repository secret `PLAY_SERVICE_ACCOUNT_JSON`.

From then on each release uploads automatically. Repository variables tune it
without code changes:

| Variable | Default | Values |
|---|---|---|
| `PLAY_TRACK` | `internal` | `internal`, `alpha`, `beta`, `production` |
| `PLAY_RELEASE_STATUS` | `draft` | `draft`, `completed`, `inProgress` |
| `PLAY_USER_FRACTION` | unset | `0` < x < `1`; required with `inProgress`, otherwise leave unset |

Uploads stay drafts by default: Play accepts only drafts until the app's first
release is published, and nothing reaches users without a rollout in Play
Console. The secret applies to releases cut after it is added. Every upload
needs a new version code, so re-run only a failed `Upload to Google Play` job,
and never re-upload a build that was already uploaded by hand.

## License and attribution

Copyright 2026 shubhamtaywade82. Portions Copyright 2024 JHubi1, modified by
shubhamtaywade82. Derived from
[JHubi1/ollama-app](https://github.com/JHubi1/ollama-app), licensed under
Apache 2.0. See [LICENSE](LICENSE).
