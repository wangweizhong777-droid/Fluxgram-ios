# Fluxgram iOS Handoff

Updated: 2026-09-13 (Asia/Shanghai)

## Resume Here

- Repository: `/Volumes/FluxBuild/Workspace/Fluxgram-iOS`
- Branch: `codex/public-fluxgram`
- Product bundle identifier: `org.11cf5f739aace03b.Telegram`
- Main test device: `王伟忠的 iPhone` (`DF49E90C-3E00-5630-9BE5-445D615EEF89`)
- The repository has a very large pre-existing dirty worktree (about 29,500 paths). Never stage, clean, reset, or commit the whole tree. Always scope Git commands to the files being changed.
- Do not print or commit API keys, passwords, Telegram sessions, private keys, provisioning profiles, or NAS credentials.

## Product Direction

Fluxgram is a private Telegram iOS client. Telegram chat remains the primary product; NAS downloading is secondary. The current NAS download page has an established light, native-iOS visual direction. Do not redesign or replace its download backend unless the user explicitly asks.

The user prefers small, direct UI fixes to be implemented without unnecessary questioning. For ambiguous behavior or data rules, ask one question at a time. Do not install to the iPhone until the user says `推送`. After every device installation, include a short test flow.

## Current Download Page

The download page is implemented as custom UIKit/ListView presentation nodes over the existing NAS service and queue.

Important files:

- `submodules/SettingsUI/Sources/FluxgramDownloadsController.swift`
  - Owns presentation state, entry generation, status filtering, real-time search filtering, and forwarding UI actions to the existing NAS service.
- `submodules/SettingsUI/Sources/FluxgramDownloadHeaderItem.swift`
  - Custom header containing the title, summary, real `UITextField` search, and four status filters.
  - Also owns the shared `FluxgramDownloadDesign` tokens used by the header and cards.
- `submodules/SettingsUI/Sources/FluxgramDownloadCardItem.swift`
  - Custom white task cards, thumbnail/status/progress presentation, and forwarding of primary/more actions.
- `submodules/SettingsUI/Sources/FluxgramNASService.swift`
  - Existing NAS transport, queue, task model, retry/pause/resume/delete operations, and thumbnail data. Treat as business logic; it was not changed in the latest UI work.

### Latest UI State

- Light surface hierarchy:
  - page: `systemGroupedBackground`
  - search and filter controls: `systemGray5`
  - task cards: `systemBackground`
- Shared typography, spacing, icon size, action size, and surface constants live in `FluxgramDownloadDesign`.
- All task states now use the same outer card dimensions:
  - list item height: `106pt`
  - card height: `98pt`
  - thumbnail: `82 x 82pt`
  - card corner radius: `20pt`
  - horizontal margin: `20pt`
  - visible vertical gap: `8pt`
- Percent text has a fixed `40pt` right-aligned area and supports `100%` without truncation.
- Card-level pause/resume/retry/folder/more actions remain wired to existing controller actions.

### Real Search

The old decorative search bar was replaced with a real `UITextField`. Search is local and presentation-only: it does not query the NAS and does not mutate task state.

It matches current active, pending, and history items using available values including:

- task/file/requested title
- source title, label, text, and URL
- save/output path
- note and tags
- pending filename, directory, dialog, and message ID

The query is combined with the selected status filter. Filter counts and the header summary continue to show real unfiltered task totals. An explicit empty-result message appears when no task matches.

The following decorative/non-functional elements were removed:

- header `+`
- header `...`
- decorative filter icon inside the search field
- placeholder NAS storage section without real quota data

Do not reintroduce controls that appear actionable without wiring real behavior.

## Business Logic Boundaries

The latest work did not change DownloadManager/NAS queue semantics, network requests, Telegram media fetching, file naming, file saving, pause/resume/retry/delete operations, or backend deployment.

Keep UI changes in the header/card/controller presentation layer. Before changing download behavior, inspect the existing `FluxgramNASService` methods and preserve per-task action identity.

Opening the download page must remain read-only except for the existing periodic status refresh. It must not resubmit pending downloads merely because the page appeared.

## Verified Build And Installation

Syntax and whitespace checks:

```bash
swiftc -parse \
  submodules/SettingsUI/Sources/FluxgramDownloadHeaderItem.swift \
  submodules/SettingsUI/Sources/FluxgramDownloadCardItem.swift \
  submodules/SettingsUI/Sources/FluxgramDownloadsController.swift

git diff --check -- \
  submodules/SettingsUI/Sources/FluxgramDownloadHeaderItem.swift \
  submodules/SettingsUI/Sources/FluxgramDownloadCardItem.swift \
  submodules/SettingsUI/Sources/FluxgramDownloadsController.swift
```

Unsigned verification build:

```bash
xcodebuild \
  -project Telegram/Telegram.xcodeproj \
  -scheme Telegram \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DeviceDerivedData \
  build CODE_SIGNING_ALLOWED=NO
```

Signed device build:

```bash
xcodebuild \
  -project Telegram/Telegram.xcodeproj \
  -scheme Telegram \
  -configuration Debug \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DeviceDerivedData \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=NU4H68V4GW \
  -allowProvisioningUpdates \
  build
```

Built app path:

```text
/Volumes/FluxBuild/Workspace/Fluxgram-iOS/build/DeviceDerivedData/Build/Products/Debug-iphoneos/bazel-out/ios_arm64-dbg-ios-arm64-min13.0-ST-faee4d1e8780/bin/Telegram/Telegram.app
```

Install and launch only after the user requests a push:

```bash
codesign --verify --deep --strict /absolute/path/to/Telegram.app
xcrun devicectl device install app \
  --device DF49E90C-3E00-5630-9BE5-445D615EEF89 \
  /absolute/path/to/Telegram.app
xcrun devicectl device process launch \
  --device DF49E90C-3E00-5630-9BE5-445D615EEF89 \
  --terminate-existing \
  org.11cf5f739aace03b.Telegram
```

The current development profile observed during the last successful installation expires on 2026-09-18. If a later signed build fails, refresh Xcode managed signing; never add the profile to Git.

## Last Device Verification

The latest signed build was installed and successfully launched on the main iPhone on 2026-09-13. At handoff time, the device build includes:

- unified task card and thumbnail sizes
- real download-list search
- removal of decorative fake controls

Recommended smoke test after the next installation:

1. Open `Fluxgram 设置 -> NAS 下载`.
2. Type several characters continuously into search and confirm text is retained.
3. Search by a known filename and by a source keyword.
4. Clear search and confirm the complete list returns.
5. Combine search with each status filter.
6. Verify download, completed, paused, waiting, and failed cards have equal dimensions.
7. Exercise one per-card action and confirm only that task changes.

## Immediate Follow-up

Wait for the user's visual and interaction feedback from the just-installed build. Likely follow-up work should remain narrowly scoped to download-page polish or search reliability. Do not start a broad frontend refactor without a new explicit request.

## Short Video Stream UI (2026-09-13)

The short video stream page was visually rebuilt while preserving Telegram source selection, scanning, playback, enable/disable actions, persistence, and navigation.

Changed presentation files:

- `submodules/SettingsUI/Sources/FluxgramDesign.swift` — shared page/card surface, typography, spacing, row, icon, and separator tokens.
- `submodules/SettingsUI/Sources/FluxgramShortVideoItems.swift` — UIKit list blocks for intro, unified action card, unified sources card, source rows, and information card.
- `submodules/SettingsUI/Sources/FluxgramShortVideoController.swift` — presentation entry generation only; source rows load real Telegram peer avatars by `dialogId`, with initial fallback when no image is available.

The action area is one white card containing three inset rows. All Telegram sources are rows inside one white card. Card width now follows the NAS page's list inset behavior and avoids applying the page margin twice. Source rows remain chevron-driven because the existing business flow edits enabled state through the source action sheet; no new switch behavior was introduced.

Validation completed:

```bash
swiftc -parse submodules/SettingsUI/Sources/FluxgramShortVideoItems.swift submodules/SettingsUI/Sources/FluxgramShortVideoController.swift
git diff --check -- submodules/SettingsUI/Sources/FluxgramShortVideoItems.swift submodules/SettingsUI/Sources/FluxgramShortVideoController.swift submodules/SettingsUI/Sources/FluxgramDesign.swift
xcodebuild -project Telegram/Telegram.xcodeproj -scheme Telegram -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/DeviceDerivedData CODE_SIGNING_ALLOWED=NO build
```

The unsigned verification build succeeded after fixing the avatar image signal mapping. Commit: `21874ceedc` (`Polish short video stream UI`).

The resulting app was installed over Wi‑Fi on the paired device `王伟忠的iPhone` (`DF49E90C-3E00-5630-9BE5-445D615EEF89`) using `xcrun devicectl device install app`. The second iPhone remains unavailable. Recommended smoke test: open `Fluxgram 设置 -> 短视频流`, confirm the action and sources each occupy one full-width card, verify long source titles truncate cleanly, and confirm real Telegram group/channel avatars appear when cached or loadable.
