# CodexBar Codebase Overview

This document summarizes the repository with emphasis on architecture, providers, icon rendering, usage flow, polling, and where to hook burn-rate logic/animation.

## Burn Rate Context (from `BURN_RATE.md`)

The target feature is real-time burn-rate visibility on top of existing usage meters:

- Compute provider and aggregate burn pace (tokens/min over a short sliding window, plus optional input/output split).
- Map burn tiers to animation states (Idle, Low, Medium, High, Burning) and make thresholds user-configurable.
- Surface burn rate and cost rate in menu UI.
- Support higher-frequency sampling (around 10-15 seconds) without breaking existing usage polling.
- Prefer icon-driven feedback (pulse/heat/fire-style states) integrated with the current menubar rendering path.

## 1) Overall Architecture and Module Structure

### Top-level layout

- `Sources/CodexBar`: Main macOS menu bar app (SwiftUI + AppKit bridge), settings, usage store, status item/menu control, provider UI integration.
- `Sources/CodexBarCore`: Shared/core domain logic used by app and tools: usage models, provider descriptors/fetch pipelines, parsing/fetching, credential helpers.
- `Sources/CodexBarCLI`: CLI entry points and output rendering, reusing `CodexBarCore` models.
- `Sources/CodexBarClaudeWatchdog` and `Sources/CodexBarClaudeWebProbe`: Auxiliary Claude-related executables.
- `Sources/CodexBarWidget`: Widget extension consuming shared usage data surfaces.
- `Sources/CodexBarMacroSupport` and `Sources/CodexBarMacros`: Macro infrastructure used for provider registration/boilerplate reduction.
- `Tests/CodexBarTests`: XCTest suites for parsing, provider logic, icon behavior, status probes, and usage formatting.
- `Scripts`: Build/test/package/notarization/release helpers (`compile_and_run.sh`, `package_app.sh`, etc.).
- `docs`: Release process and related project documentation.

### Runtime architecture (main app)

- App entry point: `Sources/CodexBar/CodexbarApp.swift`
  - Boots settings, usage fetch/store, preferences selection, and account info.
  - Wires `AppDelegate` and `StatusItemController`.
- Primary state container: `Sources/CodexBar/UsageStore.swift`
  - Holds per-provider usage snapshots, errors, status indicators, stale/loading flags, credits, runtime instances, and timers.
- Provider integration boundary:
  - Registry/catalog: `Sources/CodexBar/ProviderRegistry.swift`, `Sources/CodexBar/Providers/Shared/ProviderCatalog.swift`
  - Interfaces/runtime: `Sources/CodexBar/Providers/Shared/ProviderImplementation.swift`, `Sources/CodexBar/Providers/Shared/ProviderRuntime.swift`
- UI bridge/controller:
  - Menubar + menu orchestration: `Sources/CodexBar/StatusItemController.swift`
  - Animation/icon updates: `Sources/CodexBar/StatusItemController+Animation.swift`
  - Menu composition: `Sources/CodexBar/MenuDescriptor.swift`, `Sources/CodexBar/StatusItemController+Menu.swift`

Core boundary principle: `CodexBarCore` owns provider-fetch domain and usage models; `CodexBar` owns app lifecycle, timers, status item rendering, settings UX, and provider-specific presentation hooks.

## 2) How Providers Are Implemented (Claude Example)

### Provider abstraction

Provider implementations are split into two layers:

- Core descriptor/fetch layer (in `CodexBarCore`): declares source modes, fetch strategies, and how usage is produced.
- App implementation/presentation layer (in `CodexBar`): settings UI, menu actions, login/runtime affordances, and provider-specific UI text.

Key pieces:

- Descriptor + fetch planning: `Sources/CodexBarCore/Providers/ProviderFetchPlan.swift`
- Provider metadata/registration:
  - `Sources/CodexBar/Providers/Shared/ProviderImplementation.swift`
  - `Sources/CodexBar/Providers/Shared/ProviderImplementationRegistry.swift`
  - `Sources/CodexBar/ProviderRegistry.swift`

`UsageStore` gets provider specs from the registry, executes per-provider fetches, and stores results keyed by provider.

### Claude as a concrete example

- Descriptor: `Sources/CodexBarCore/Providers/Claude/ClaudeProviderDescriptor.swift`
  - Defines Claude source modes (`auto/web/cli/oauth`) and fetch behavior selection.
- Fetcher/parser: `Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift`
  - Resolves credentials/availability and loads usage through OAuth/CLI/web paths.
  - Produces `UsageSnapshot` consumed by the app store/UI.
- App-side implementation: `Sources/CodexBar/Providers/Claude/ClaudeProviderImplementation.swift`
  - Provider-specific settings controls, menu additions, and login/runtime actions.

### Provider isolation guardrail

Provider identity and usage data are kept provider-scoped in `UsageSnapshot` and `UsageStore` maps, then queried via provider-specific accessors. This is the enforcement point for the rule that identity/plan fields must not leak across providers.

## 3) Menubar Icon Rendering (NSImage, Animation, Meter Bars)

### Rendering pipeline

- Renderer: `Sources/CodexBar/IconRenderer.swift`
  - Builds template `NSImage` icons (bitmap-backed) at menu bar size.
  - Draws one or more meter bars (primary/weekly/credits) with provider style variants.
  - Applies dimming for stale/idle states and overlays status indicators.
  - Uses cache keys derived from rounded usage/style/status inputs to avoid re-rasterization.

### Meter model

Icon bars are driven by `RateWindow` usage percentages from snapshots (`Sources/CodexBarCore/UsageFetcher.swift`), typically using remaining/used values for:

- Primary window bar.
- Secondary/weekly bar (if present).
- Credits lane for providers that expose it.

### Animation path

- Controller-side animation logic: `Sources/CodexBar/StatusItemController+Animation.swift`
  - Decides if icon should animate based on loading/refresh/flags.
  - Advances animation phase (display link + timer-assisted effects).
  - Applies either static `makeIcon(...)` rendering or animated `LoadingPattern`/morph rendering.
- Display-link driver: `Sources/CodexBar/DisplayLink.swift`
  - Frame callback for smooth phase advancement.
- Shared loading patterns: `Sources/CodexBar/LoadingPattern.swift`
  - Pattern curves (`race`, `pulse`, `unbraid`, etc.) used by AppKit status icons and SwiftUI icon view.
- SwiftUI mirror: `Sources/CodexBar/IconView.swift`
  - Uses the same pattern vocabulary so app surfaces stay visually consistent.

## 4) Usage Data Flow: Provider Polling -> UI Update

End-to-end flow:

1. `UsageStore` schedules refresh.
2. For each provider, `UsageStore+Refresh` builds provider fetch context and executes descriptor fetch outcome (`Sources/CodexBar/UsageStore+Refresh.swift`).
3. Provider fetch path (core descriptors/fetchers) returns a `UsageSnapshot`.
4. `UsageStore` updates provider-keyed snapshot/error/status maps and runtime callbacks.
5. `StatusItemController` observes store changes (`menuObservationToken`) and triggers:
   - icon updates (`applyIcon`, merged/per-provider),
   - menu invalidation/rebuild,
   - blinking/status/visibility updates.
6. `MenuDescriptor` and menu-building logic convert snapshots into textual/section UI (`Sources/CodexBar/MenuDescriptor.swift`, `Sources/CodexBar/StatusItemController+Menu.swift`).

Net effect: provider poll results in `CodexBarCore` become `UsageStore` state, which is the single input stream for menubar icon state and menu content.

## 5) Polling / Refresh Mechanism

Primary refresh logic sits in `Sources/CodexBar/UsageStore.swift` plus `Sources/CodexBar/UsageStore+Refresh.swift`:

- `startTimer()` sets recurring refresh cadence based on settings (`refreshFrequency`).
- `refresh()` fans out provider refreshes + status/credits side refreshes.
- `refreshProvider(_:)` enforces provider enablement/availability, runs fetch, persists snapshot or error, and updates failure gating.
- Token-account related refresh has separate scheduling (`startTokenTimer()` / token refresh helpers).
- Store tracks staleness/loading/last-source labels so UI can signal quality and recency of data.

This is currently well-factored for introducing a second, higher-frequency sampling stream for burn rate if needed.

## 6) Extension Points for Burn Rate Calculation and Animation

Based on current structure and `BURN_RATE.md`, the clean hooks are:

### A) Burn-rate data model and computation

- Extend snapshot model in core:
  - `Sources/CodexBarCore/UsageFetcher.swift` (where `UsageSnapshot` and `RateWindow` live).
- Compute per-provider burn rate inside provider fetchers (example: `Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift`) so data is source-aware.
- Persist in `UsageStore` alongside existing snapshots (no new app-wide state container needed).

Recommended shape:

- Add a typed burn-rate payload (e.g., tokens/min, optional input/output rates, sample interval, confidence/source).
- Optionally add aggregate helper in `UsageStore` to compute merged/global burn from provider snapshots.

### B) Refresh cadence for burn windows

- Add a dedicated fast timer path in `UsageStore` (10-15s) for burn sampling.
- Keep current heavier provider refresh cadence intact; only run lightweight source paths where possible.
- Reuse existing failure gates and stale handling so burn visuals degrade gracefully on missing samples.

### C) Icon animation coupling

- `Sources/CodexBar/StatusItemController+Animation.swift`:
  - Scale `animationPhase` step by burn tier/rate (slow pulse to aggressive motion).
  - Select loading/animation pattern by burn tier.
- `Sources/CodexBar/LoadingPattern.swift`:
  - Add burn-aware patterns or parameterized variants.
- `Sources/CodexBar/IconRenderer.swift`:
  - Add explicit burn overlays (heat tint, ember/fire accent, flashing threshold treatment) while preserving provider style.

### D) Menu/UI surface

- `Sources/CodexBar/MenuDescriptor.swift` + provider-specific menu extras:
  - Show current burn rate, short trend/sparkline, and estimated cost rate.
- Provider implementations (example Claude file above) are natural insertion points for provider-specific burn semantics.

### E) Unified icon selection behavior

- Existing merged-icon logic already picks a primary provider (including highest-usage mode) in `StatusItemController+Animation`.
- Burn-rate tier can reuse that same selection policy to decide which provider drives global animation when icons are merged.

## Practical Implementation Sequence

1. Add burn-rate fields to core snapshot models.
2. Compute/populate burn rate in one provider (Claude) end-to-end.
3. Thread fields through `UsageStore` and menu descriptor output.
4. Add burn-tier mapping in animation controller and renderer.
5. Introduce configurable thresholds in settings.
6. Add tests in `Tests/CodexBarTests` for model parsing, tier mapping, and icon state selection.

