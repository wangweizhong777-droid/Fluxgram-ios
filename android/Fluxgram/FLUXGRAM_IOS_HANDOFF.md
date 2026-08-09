# Fluxgram iOS Handoff

## Read This First

FluxTok iOS is complete enough to be the NAS media browser/player. Its native
SwiftUI project lives at `ios/FluxTok` and was added in commit `0e455ff`.
Do not replace it, move it into Fluxgram, or duplicate its NAS-player, tag,
recycle-bin, or library-management UI.

This document starts the next product: **Fluxgram iOS**, a private Telegram
client that submits Telegram media to the existing NAS workflow. It is a
separate app with a separate bundle identifier and signing target.

## Product Boundary

The private Flux stack has four responsibilities:

- **Fluxgram**: Telegram conversations, selected-channel short-video feed,
  media submission to NAS and NAS download status.
- **TGAPP backend**: authoritative download queue, media identity, source
  metadata, tags, notes, inbox and recycle-bin records.
- **FluxTok**: browse/play/manage media already on NAS.
- **Fluxgram Relay**: diagnostics only; it is not a media or chat client.

Fluxgram must send a *Telegram message reference* to the backend. It must not
download a full Telegram file to the iPhone and upload it again. That would
waste mobile data, degrade reliability and create duplicate ownership of media.

## Source Locations And Current Truth

- This repository contains Android FluxTok and native iOS FluxTok only.
- The current Android Fluxgram reference implementation is private and local:
  `<your-workspace>/.worktrees/phone-short-video-download-100`.
- Its current HEAD when this document was written: `f801e259f`.
- The Android Fluxgram source is the behavioral oracle for NAS submission,
  offline retry, download status and short-video workflow. Do not infer those
  contracts from FluxTok alone.
- TGAPP backend source is a separate repository/deployment. Do not deploy an
  old local backend or modify the NAS schema while building iOS Fluxgram.

## Architecture Decision

Build Fluxgram as a **private fork of the official Telegram iOS client**, not
as a new SwiftUI chat client built on top of FluxTok and not as a hand-rolled
MTProto implementation.

Reasons:

- Telegram login, updates, message pagination, media transport, secret-chat
  boundaries and account recovery are mature upstream concerns.
- A custom UI on TDLib would require rebuilding an entire Telegram client
  before reaching the NAS features that matter here.
- Fluxgram-specific work can remain a narrow patch layer over an upstream that
  already works on the user's device.

Create a separate private repository or an isolated checkout for the upstream
fork. Do not vendor a large Telegram upstream tree into `ios/FluxTok`, and do
not modify the existing FluxTok Xcode project.

Keep an `upstream` Git remote and keep Fluxgram changes in small, separately
named commits. Preserve required upstream license notices and Telegram API
terms even though this is personal-only software.

## Required Security Rules

1. Never commit Telegram `api_id`, `api_hash`, account sessions, NAS passwords,
   gateway tokens, proxy subscriptions, certificates or private media paths.
2. Keep user-entered NAS/TGAPP settings in Keychain. Keep build-only Telegram
   credentials in an ignored local Xcode configuration file.
3. Do not copy FluxTok's Keychain service name. Fluxgram must use its own
   service namespace so deleting or reinstalling one app cannot overwrite the
   other app's credentials.
4. Do not add a general-purpose proxy/VPN implementation in this phase. Use
   the upstream Telegram networking configuration first; proxy parity is a
   later, separately tested task.
5. Never send a message, submit a NAS download, or mutate backend data during
   an automatic retry without a persisted idempotency key.

## Phase 0: Upstream Baseline

Before any Fluxgram branding or NAS feature:

1. Clone the official Telegram iOS source into its own private working copy.
2. Follow the upstream build instructions exactly and create an ignored local
   configuration for the user's Telegram API credentials and Apple signing.
3. Build and install an unchanged upstream baseline on the user's iPhone.
4. Verify login, conversation loading, a video message, document message and
   channel navigation.
5. Commit only non-secret build scaffolding and record the upstream revision.

Stop and report the exact failing upstream build step if this phase fails. Do
not attempt to bypass it by reimplementing Telegram login or using FluxTok as a
chat shell.

## Phase 1: Fluxgram Identity And Settings

After the baseline works:

- Brand the app as **Fluxgram** with a distinct app icon and bundle identifier.
- Preserve the upstream chat UI/layout initially. Do not perform a SwiftUI
  rewrite of upstream Telegram views.
- Add a small Fluxgram settings section for NAS/TGAPP endpoint configuration.
- Store the TGAPP base URLs and access token in Keychain.
- Provide a non-destructive connection test that calls the backend version or
  health endpoint and shows only status/latency, never the token.

The only settings fields required initially are local backend URL, remote
backend URL and access token. FluxTok's WebDAV and media-root fields belong in
FluxTok, not Fluxgram.

## Phase 2: Telegram Message To NAS Submission

Implement this before a custom short-video feed.

### Eligible Media

Expose **Download to NAS** for Telegram photos, videos, animations and document
media that the backend can fetch from the original message. Do not hide the
action just because a chat disables ordinary Telegram forwarding: the feature
uses the authenticated original-message reference, not a forwarded copy.

### Request Contract

The Android reference submits:

```text
POST /api/dialogs/{backendDialogId}/messages/{messageId}/download
Header: X-TGAPP-Token: <local Keychain token>
Content-Type: application/json
```

The optional JSON body is:

```json
{
  "downloadSubdir": "optional relative folder",
  "note": "optional note",
  "tags": ["optional", "tags"],
  "inbox": true
}
```

Omit empty fields. Normalize tags by trimming, collapsing internal whitespace,
rejecting line breaks and deduplicating case-insensitively.

The backend dialog ID is not always Telegram's signed local dialog ID:

```text
if dialogId < -1000000000000: backendDialogId = -dialogId - 1000000000000
else if dialogId < 0:         backendDialogId = -dialogId
else:                         backendDialogId = dialogId
```

Treat this mapping as a tested protocol rule. A wrong mapping can submit a
download against the wrong conversation or yield a backend 404.

### Submission UX

The action opens a compact sheet with:

- destination subfolder, with current backend directory suggestions;
- note;
- tags, using NAS-backed recent suggestions;
- `Add to inbox` toggle;
- a clear submission result.

The backend owns deduplication and actual downloading. The client must show a
queued result quickly and must not pretend that the file is already on NAS.

## Phase 3: Resilient Queue And Download Status

Implement a local persistent submission queue before adding bulk actions.

- Queue key: `backendDialogId + messageId + normalizedDownloadSubdir`.
- Persist the message reference and submission options, not Telegram media
  bytes and not account/session credentials.
- On a reachable failure, retain the task and show it as pending.
- Retry on app foreground, explicit Retry and eligible iOS background refresh.
  iOS background execution is opportunistic; it must not be advertised as a
  guaranteed daemon.
- Mutating submissions use local-first then remote sequential fallback. Never
  race two POST requests to both endpoints because it can create duplicate jobs.
- Successful submissions remove the pending task only after a successful HTTP
  response.

Provide a NAS downloads screen backed by the existing backend endpoints:

- `GET /api/downloads?limit=<n>` for active/recent work;
- `GET /api/download-history?limit=<n>` for completed records;
- `GET /api/download-directories?limit=200&maxDepth=4` for folder suggestions;
- `POST /api/downloads/{jobId}/cancel` and `POST /api/downloads/retry-problem`
  only after explicit user action.

Read-only requests may use a quick local-first fallback. Record the route that
succeeded for diagnostics, but never expose credentials in logs.

## Phase 4: Cross-App Workflow

After Phase 2 and 3 are stable:

- From Fluxgram's completed-download detail, offer **Open in FluxTok**.
- Pass only the NAS-root-relative media path through a documented deep link.
- FluxTok already supports `nastok://play?path=<relative-path>`.
- From FluxTok, the existing source metadata should open the matching Telegram
  conversation/message in Fluxgram. Define and test one stable Fluxgram deep
  link contract before shipping it; do not guess an Android intent scheme.
- A cross-app action must degrade to a readable "app unavailable" state rather
  than silently opening the wrong message.

## Phase 5: Short-Video Feed

Only begin after chat browsing and NAS submission are reliable.

Mirror the Android behavior, not a generic social feed:

- user manually selects Telegram source conversations;
- a configurable maximum duration filters candidates;
- scan history is incremental and candidate identity is `dialogId:messageId`;
- shuffle enough candidates to avoid the same small rotation;
- vertical paging preloads the next item and preserves aspect ratio;
- right-side actions: source, download to NAS, like and source avatar;
- liked items have a dedicated playable list;
- an action opens the original message;
- source navigation and NAS submission use the same message-reference mapping
  as Phase 2.

Do not couple this feed to FluxTok's NAS index. Fluxgram short videos are
Telegram-backed; FluxTok is NAS-backed.

## Verification Gates

Do not move to the next phase until its gate passes on a real iPhone:

1. Phase 0: upstream app installs, logs in and loads a real channel.
2. Phase 1: branded build installs without leaking settings into Git or logs.
3. Phase 2: submit one video, one photo and one non-forwardable media item;
   verify the correct backend record and source metadata appear.
4. Phase 3: disable network, submit once, relaunch, restore network and verify
   exactly one backend job is created from the pending queue.
5. Phase 4: open a completed item in FluxTok, then navigate back to its
   original Fluxgram message.
6. Phase 5: refresh selected sources, play at least 30 varied candidates,
   confirm source navigation, like list and NAS submission.

## Explicit Non-Goals For The First Fluxgram iOS Release

- Full Android feature parity.
- A new NAS backend or a schema migration.
- A new proxy/VPN engine.
- Telegram secret-chat changes.
- Automatic Telegram-wide collection without user-selected source chats.
- Copying FluxTok's player UI into the Telegram chat player.

## First Mac Codex Prompt

```text
Read FLUXGRAM_IOS_HANDOFF.md, HANDOFF.md and the current Git history first.
Do not modify ios/FluxTok.

Create a separate private working copy for an official Telegram iOS upstream
fork. Before implementing Fluxgram branding or NAS features, build the
unmodified upstream client, install it on the connected iPhone and verify
Telegram login plus chat/media playback.

Keep Telegram credentials, NAS URLs, tokens and signing files out of Git.
Report the exact upstream revision, build result and any blocker. Do not
implement a custom Telegram protocol client or write NAS submission code until
the upstream baseline runs on device.
```
