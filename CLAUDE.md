# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Relay (formerly NEBox) is a native iOS client for BoxJS — a management tool for JavaScript automation scripts across proxy tools (Loon, Surge, Shadowrocket, Quantumult X). Built with SwiftUI + MVVM + Combine.

## Build & Run

```bash
# Open in Xcode (SPM dependencies resolve automatically)
open Relay.xcodeproj

# Build from command line
xcodebuild -project Relay.xcodeproj -scheme Relay -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Model-layer tests (Foundation-only, plain swiftc — no simulator or test target)
Tools/ModelTests/run.sh            # optionally: run.sh <dir of saved /query/boxdata JSON>
```

- **Xcode 15.4+**, **iOS 15.0+**, **Swift 5.0**
- Dependencies managed via Xcode SPM integration (no Package.swift or Podfile)

## Architecture

**MVVM + Combine** with a single shared ViewModel:

```
BoxJSAPI (Moya TargetType) → NetworkProvider (parse to JSONValue + envelope check) → models projected from JSON → BoxJsViewModel (@Published state) → Views (@EnvironmentObject)
```

### Key layers:

- **Models/** — The foundation; read it first. `JSONValue.swift` (dynamic JSON + JS-faithful coercions), `LenientDecoding.swift` (`JSONFields` reader, `DecodeReport`), then the projected models: `BoxDataModel.swift` (`BoxDataResp` + derived views, other responses), `AppModel.swift` (apps, scripts, settings), `SubscriptionModels.swift`, `UserConfig.swift`, `SessionModels.swift`.
- **Services/BoxJSAPI.swift** — Moya `TargetType` enum defining all API endpoints with paths, methods, and parameter encoding.
- **Services/NetworkProvider.swift** — Generic `request<T: JSONProjectable>()`; `mapBoxJS` checks HTTP status and, for `/api/*`, the `{ code, message }` envelope, then projects the body. Only a non-JSON body can fail.
- **Services/ApiRequest.swift** — High-level API helpers that compose ViewModel calls.
- **ViewModels/BoxJsViewModel.swift** — Single shared ViewModel holding all app state via `@Published` properties. Injected as `@EnvironmentObject`.
- **Managers/ApiManager.swift** — Singleton managing the BoxJS API base URL, persisted to UserDefaults.
- **Managers/ToastManager.swift** — Singleton for toast notifications.

### View hierarchy:

`ContentView` (welcome setup + TabView) routes to:

- `HomeView` — Favorite apps grid using UICollectionView wrapper, edit mode with jiggle animation
- `SubcribeView` — Subscription card management with drag-to-reorder
- `ProfileView` — User profile, global backup/restore, JSON import/export
- `AppDetailView` — App settings forms (radio/checkbox/text), session management, data viewer, script execution

### BoxJS API contract:

Errors from `/api/*` use the envelope `{ "code": -1, "message": "..." }`; successful responses are the payload itself (usually `/query/boxdata`). `/query/*` results are user data and are never treated as an envelope.

### BoxJS data is weakly typed — models are projections, not `Codable`

Subscriptions are hand-written by third parties, and stored values are written by the web UI, scripts and old BoxJS versions, so any field can arrive as a string, number, array or `null`. Rules:

- Parse with `JSONValue`, then project with `JSONFields` (`init(json:)` / `init(_:path:report:)`). Never add a strict `Decodable` model for BoxJS data: one odd field must not hide everything else.
- A missing or odd field falls back to the web UI's default; entries that are unusable (no `id`) are skipped and recorded in `DecodeReport`, which the view model logs once per change.
- Read values through the coercions (`wireText`, `boolValue`, `numberValue`, `listItems`, `displayText`), which mirror the web UI.
- Write setting values as text (`JSONValue.wireText`, lodash `_.toString`) via `BoxJsViewModel.saveSettings` — scripts expect what the web UI writes. Never send `null` to `/api/save` to clear a key (BoxJS ignores it); send `""`.
- Lists rewritten whole (sessions, `usercfgs.appsubs`) go back from the stored objects (`Session.jsonValue`, `UserConfig.appsubsJSON`), so fields and entries this client doesn't model survive.

## Code Patterns

- **Async/await** throughout the networking layer (no callbacks)
- **UICollectionView wrappers** (`CollectionViewWrapper`, `SubCollectionViewWrapper`) for high-performance grid layouts bridged into SwiftUI
- **Fire-and-forget vs explicit errors**: `updateData()` is fire-and-forget; `updateDataAsync()` returns `Result<Void, UpdateError>`
- **Proxy tool detection**: Reads `syscfgs.env` from BoxDataResp to identify the active proxy tool (Loon/Surge/etc.)
- **Subscription recovery**: when BoxJS cannot cache a subscription Relay can read (UTF-8 BOM, missing `id`), `ApiRequest` stores Relay's copy under the same URL on add and on refresh
- **NSAllowsArbitraryLoads** enabled in Info.plist (required — BoxJS runs on local HTTP)
- **JSON document support**: App is registered as a JSON file handler for import/export of app data and backups

## Source Layout

All source files live under `Relay/`:

```
Relay/
├── RelayApp.swift          # App entry point
├── Views/                  # SwiftUI views organized by feature
│   ├── Home/
│   ├── Subscribe/
│   ├── Profile/
│   ├── AppDetail/
│   └── Components/
├── ViewModels/
├── Models/
├── Services/
├── Managers/
├── Helpers/
└── Extension/
```

## Dependencies (SPM)

| Package           | Purpose                    |
| ----------------- | -------------------------- |
| Moya / Alamofire  | Network abstraction + HTTP |
| SDWebImageSwiftUI | Image loading & caching    |
