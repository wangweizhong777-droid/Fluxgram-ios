# FluxTok / Fluxgram iOS Handoff

> FluxTok iOS now exists at `ios/FluxTok` (commit `0e455ff`). For the next
> product, the full Telegram client, read `FLUXGRAM_IOS_HANDOFF.md` before
> changing anything. This document remains the FluxTok/NAS architecture record.

## Scope

This repository is the Android NAS video browser currently branded as FluxTok
(the repository and Android package still use the historical name `nastok`).
It is not the full Telegram client source. The future iOS work must be a new
native project and must not assume that Android UI code can compile on iOS.

The Android app is for one private user. The NAS backend is the source of truth
for media identity, tags, profiles, likes/favorites, inbox state and recycle
bin state. The client keeps playback and browsing state locally.

## Stable Baseline

- Stable tag: `stable-fluxtok-20260728`
- Stable source branch: `feature/first-batch-optimizations`
- iOS development branch: `codex/ios-fluxgram`
- Android package: `com.example.nastok`
- Android version: `versionName 1.0`, `versionCode 1`
- The tagged source includes the code used to build the APK most recently
  installed on the user's phone before the ADB connection dropped.

Do not rewrite, force-push, reset, or commit on the stable tag. Android fixes
must branch from the stable tag and preserve the existing FluxTok entry point.

## Android Architecture

- Kotlin, Android ViewBinding, coroutines and AndroidX lifecycle components.
- Room stores the local video index, watched state, playback positions and
  local interaction cache.
- DataStore stores NAS connection settings and user preferences.
- Media3/ExoPlayer plays videos through `NasDataSourceFactory`.
- OkHttp implements WebDAV, NAS index and tag API requests.
- `FeedViewModel` owns feed modes and filtering. `FeedActivity` and
  `FeedAdapter` own the immersive vertical player and controls.
- `FailoverDataSource` prefers direct LAN WebDAV. A transient LAN read failure
  is retried locally from the current byte offset; only consecutive failures
  reach the remote gateway.

## NAS Connectivity

The user supplies all connection values in the app settings. Never commit
passwords, gateway tokens, Telegram sessions, proxy links or local config.

There are two kinds of access:

1. Direct WebDAV, normally the fastest route when the phone is on the LAN.
2. An HTTPS NAS gateway for remote access, authenticated with a user-provided
   token. The app should use it only when direct LAN access is unavailable.

The normal media root is configured by the user (historically `/ddd4/mp4/`).
Do not hardcode a user's final NAS path into new iOS code; read it from local
settings.

## NAS API Contract Used by Android

The exact base URL and token are local settings. The API paths currently used
by the Android client are:

- `GET /api/nastok-index?root=<path>`: indexed video paths and folder avatars;
  supports `ETag` and `If-None-Match` with `304 Not Modified`.
- `GET /api/tags?subdir=<folder>&limit=<n>`: tag summaries/suggestions.
- `DELETE /api/tags?tag=<tag>`: delete a tag.
- `PATCH /api/tags?tag=<tag>` with `{ "name": "..." }`: rename or merge a tag.
- `GET /api/tagged-media?tagged=true`: all tagged media paths.
- `GET /api/tagged-media?tags=<comma-separated-tags>`: media matching tags.
- `GET /api/media-tags?path=<relative-path>`: tags for one media item.
- `GET /api/media-profile?path=<relative-path>`: like/favorite/note profile.
- `PATCH /api/media-profile?path=<relative-path>`: update profile fields.
- `GET /api/media-profiles?liked=true`: liked media.
- `GET /api/media-profiles?favorited=true`: favorited media.
- `GET /api/media-detail?path=<relative-path>`: source, tags and download
  metadata for one media item.
- `GET /api/download-history?inbox=true&limit=<n>`: recently downloaded media.
- `GET /api/media-inbox`: media organization inbox state.
- `GET /api/media-trash`: recycle bin list.
- `POST /api/media-trash` with `{ "path": "..." }`: move a media item into
  the recycle bin.
- `POST /api/media-trash/{id}/restore`: restore a recycle-bin item. Expiry and
  permanent deletion remain backend-owned behavior.

The iOS client should first verify these routes against the live backend and
then put them behind a small typed Swift API layer. Do not duplicate endpoint
string building throughout the UI.

## Completed FluxTok Features

- Vertical video feed with swipe navigation and endless reshuffling for broad
  feed modes.
- All, folder, size-range, liked/favorited, tagged, untagged and inbox feeds.
- NAS-backed tags, tag suggestions, tag editing, tag rename/merge and deletion.
- Tap-through tag profiles that show videos sharing a tag.
- Likes/favorites stored through NAS media profiles.
- Media details, source message metadata and folder identity.
- Move-to-recycle-bin, thumbnails in the recycle bin and seven-day expiry
  behavior handled by the backend.
- Progress bar, duration display, tap-to-seek and horizontal percentage seek.
- Orientation handling, video aspect-ratio preservation and immersive playback.
- Local index caching and server ETag validation to avoid full remote scans.
- Current playback tuning: local-first failover, local retry after transient
  read errors, seek recovery and reduced post-seek buffering.

## Current Known Issues / Boundaries

- Native FluxTok iOS is implemented in `ios/FluxTok`; it is a separate NAS
  player/organizer and must remain independent from future Fluxgram work.
- Full Telegram session/chat functionality is outside this repository. Do not
  promise full Fluxgram parity while implementing the first iOS milestone.
- ADB may be disconnected; Android installation is not part of the iOS work.
- The NAS backend has a newer independent codebase and snapshot history. Do
  not deploy the old local TGAPP `server.js` over the NAS version.
- Existing Android files contain historical naming and some older UI/code
  artifacts. Avoid broad formatting or unrelated refactors during the iOS
  work.

## Rules For The iOS Work

1. Do not modify the Android stable tag.
2. Start from `codex/ios-fluxgram`, create a separate `ios/` project or a
   separate iOS repository, and keep Android builds unaffected.
3. Use Swift/SwiftUI for the first iOS client and AVPlayer for playback.
4. Store NAS base URLs, credentials and gateway tokens in local Keychain-backed
   settings. Never put them in source, test fixtures, screenshots or Git.
5. Keep the first milestone narrow: connect to NAS, load the indexed feed,
   play videos, swipe between items, read tags and download to NAS.
6. Reuse the backend API; do not reimplement NAS scanning or tag truth in iOS.
7. Before changing behavior, run the existing Android tests/build and record
   the result. Keep commits small and reversible.

## Completed iOS FluxTok Milestone

The completed implementation provides typed NAS clients, Keychain-backed
credentials, indexed library loading, AVPlayer playback, vertical paging, tags,
profiles, recycle bin and native iOS settings. Future Telegram-client work is
specified in `FLUXGRAM_IOS_HANDOFF.md`.
