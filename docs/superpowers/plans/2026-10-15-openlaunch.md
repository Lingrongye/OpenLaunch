# OpenLaunch Implementation Plan

> **For agentic workers:** Use subagent-driven-development for the isolated input adapter and review; root implements catalog, persistence and AppKit UI. All changes stay in this new repository.

**Goal:** Build a small native LaunchOS-like launcher for this Mac, including global pinch, F4 and hot corners.

**Architecture:** AppKit window and NSCollectionView use a persistent ordered tree of application IDs and folders. Input providers share one activation coordinator. Private touch API is dynamically isolated and reports unavailable input rather than affecting the launcher.

**Tech Stack:** Swift, Foundation, AppKit, Carbon, CoreGraphics; small C shim; Swift Package Manager. No external packages.

## 1. Build and meaningful logic tests
- [x] Create Package.swift with OpenLaunchCore, CTouch, OpenLaunch executable and core tests.
- [x] First test persistent folders/reordering, incomplete scan preservation and corruption refusal; run to observe missing behavior.
- [x] Implement Core/Layout.swift and LayoutStore.swift; pass these tests.

```swift
let app = LayoutNode.application("a")
var layout = Layout(nodes: [app, .application("b")])
let folder = try layout.group("a", with: "b", name: "工具")
XCTAssertEqual(layout.children(of: folder), ["b", "a"])
```

## 2. Input adapters
- [x] Test pinch shrink, finger count rejection, single-trigger and reset with synthetic points; label these algorithm-only tests.
- [x] Implement dynamically loaded MultitouchSupport C shim with start/stop and bounds; Swift InputController monitors touch, F4 and corners; expose statuses and callbacks.
- [x] Runtime input probe reports device count/API support and access status without key text logging.

```swift
let input = InputController()
input.onActivate = { source in print(source) }
input.start()
```

## 3. Native interface
- [x] Discover app bundles with bounded depth, skipping nested helpers; get icons on demand with NSCache.
- [x] Implement NSWindow, search field, paginated NSCollectionView, folder overlay, drag ordering/grouping, context actions and settings.
- [x] Wire actions through Layout and save atomically, preserving corrupt input. No continuously animated hidden window.
- [x] Provide bundle build script and neutral icon; retain source independently of installed LaunchOS.

```sh
swift test
swift build -c release
./scripts/build-app.sh
```

## 4. Verification
- [x] Run complete logic tests and release build; run own-app rendered preview and smoke mode against temporary data.
- [x] Launch real .app, inspect live memory/CPU and measure cold/second activation. Verify actual app launch with selected target.
- [x] 已请求真人捏合/F4/触发角验证；交互结果单独记录，五指真人确认成功；其他尚无结果的项目保持待验证。
- [x] Review spec compliance then quality; repair findings, record local verification and remaining limits in README and verification report.
