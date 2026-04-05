# Idle Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play a configurable sound and/or show a macOS notification banner when a Claude session finishes responding in a non-visible worktree.

**Architecture:** Claude Code Stop hook → `tbd notify` CLI (already exists) → daemon stores notification + broadcasts delta → app receives delta via persistent socket subscription → checks worktree visibility → fires sound (NSSound) and/or macOS notification (UNUserNotificationCenter).

**Tech Stack:** Swift, SwiftUI, SwiftNIO, POSIX sockets, NSSound, UNUserNotificationCenter, GRDB

**Spec:** `docs/superpowers/specs/2026-04-04-idle-notifications-design.md`

---

## File Map

**Create:**
- `Sources/TBDApp/Services/NotificationSoundPlayer.swift` — `@MainActor` service that plays system or custom sounds via NSSound
- `Sources/TBDApp/Services/MacNotificationManager.swift` — `@MainActor` service for UNUserNotificationCenter integration
- `Sources/TBDDaemon/Server/RPCRouter+SubscriptionHandler.swift` — `state.subscribe` RPC handler
- `Tests/TBDDaemonTests/StateSubscriptionTests.swift` — subscription cleanup + broadcast tests

**Modify:**
- `Sources/TBDDaemon/Server/StateSubscription.swift` — add dead-subscriber cleanup to broadcast()
- `Sources/TBDDaemon/Server/SocketServer.swift` — handle `state.subscribe` as streaming (don't close after response)
- `Sources/TBDDaemon/Server/RPCRouter.swift:55-138` — add stateSubscribe case to switch
- `Sources/TBDApp/DaemonClient.swift` — add persistent subscription socket + delta reading loop
- `Sources/TBDApp/AppState.swift` — add delta handler, fire sound/notification for non-visible worktrees
- `Sources/TBDApp/Settings/SettingsView.swift:23-44` — expand Notifications section with sound controls
- `Sources/TBDCLI/Commands/SetupHooksCommand.swift:64` — update hook command to pass --message
- `Sources/TBDCLI/Commands/SetupHooksCommand.swift:76-88` — fix migration to update existing entries
- `Sources/TBDCLI/Commands/NotifyCommand.swift:33-51` — check TBD_WORKTREE_ID env var first
- `Sources/TBDDaemon/Tmux/TmuxManager.swift:53-58` — extend newWindowCommand to accept env vars
- `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift:48-53` — pass TBD_WORKTREE_ID when creating tmux window

---

### Task 1: Update StateSubscriptionManager for Dead-Subscriber Cleanup

**Files:**
- Modify: `Sources/TBDDaemon/Server/StateSubscription.swift:117-180`
- Test: `Tests/TBDDaemonTests/StateSubscriptionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/TBDDaemonTests/StateSubscriptionTests.swift`:

```swift
import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("StateSubscriptionManager Tests")
struct StateSubscriptionTests {

    @Test("broadcast removes subscriber when callback returns false")
    func broadcastRemovesDeadSubscriber() {
        let manager = StateSubscriptionManager()

        // Live subscriber
        var liveReceived = 0
        manager.addSubscriber { _ in
            liveReceived += 1
            return true
        }

        // Dead subscriber — returns false (simulating broken pipe)
        manager.addSubscriber { _ in
            return false
        }

        #expect(manager.subscriberCount == 2)

        let delta = StateDelta.notificationReceived(NotificationDelta(
            notificationID: UUID(), worktreeID: UUID(),
            type: .responseComplete, message: "test"
        ))
        manager.broadcast(delta: delta)

        #expect(manager.subscriberCount == 1)
        #expect(liveReceived == 1)
    }

    @Test("broadcast delivers to all live subscribers")
    func broadcastDeliversToAll() {
        let manager = StateSubscriptionManager()
        var count1 = 0
        var count2 = 0

        manager.addSubscriber { _ in count1 += 1; return true }
        manager.addSubscriber { _ in count2 += 1; return true }

        let delta = StateDelta.notificationReceived(NotificationDelta(
            notificationID: UUID(), worktreeID: UUID(),
            type: .responseComplete, message: nil
        ))
        manager.broadcast(delta: delta)

        #expect(count1 == 1)
        #expect(count2 == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StateSubscriptionTests 2>&1 | tail -20`
Expected: compilation error — callback signature doesn't match (currently `(Data) -> Void`, needs `(Data) -> Bool`)

- [ ] **Step 3: Update StateSubscriptionManager callback signature and broadcast**

In `Sources/TBDDaemon/Server/StateSubscription.swift`, change the callback type and broadcast logic:

```swift
// Change line 123:
public typealias SubscriberCallback = @Sendable (Data) -> Bool

// Update broadcast() starting at line 157:
public func broadcast(delta: StateDelta) {
    // Suppress deltas for conductor worktrees/terminals — app doesn't display them
    switch delta {
    case .worktreeCreated(let d), .worktreeRevived(let d):
        if d.status == .conductor { return }
    case .terminalCreated(let d):
        if d.label?.hasPrefix("conductor:") == true { return }
    case .terminalRemoved:
        break
    default:
        break
    }

    guard let data = try? JSONEncoder().encode(delta) else { return }

    lock.lock()
    let currentSubscribers = subscribers
    lock.unlock()

    var deadIDs: [SubscriberID] = []
    for (id, callback) in currentSubscribers {
        if !callback(data) {
            deadIDs.append(id)
        }
    }

    // Remove dead subscribers
    if !deadIDs.isEmpty {
        lock.lock()
        for id in deadIDs {
            subscribers.removeValue(forKey: id)
        }
        lock.unlock()
    }
}
```

- [ ] **Step 4: Fix existing callers of addSubscriber**

All existing `addSubscriber` calls in the codebase currently pass a `(Data) -> Void` closure. Search for them and update to return `true`:

Run: `grep -rn "addSubscriber" Sources/`

For each call site, change the closure to return `true`. If there are no other call sites beyond tests, this step is done.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter StateSubscriptionTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 6: Verify full test suite still passes**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDDaemon/Server/StateSubscription.swift Tests/TBDDaemonTests/StateSubscriptionTests.swift
git commit -m "feat: add dead-subscriber cleanup to StateSubscriptionManager

Change subscriber callback to return Bool (true=alive, false=dead).
broadcast() auto-removes subscribers that return false."
```

---

### Task 2: Add state.subscribe RPC Handler (Daemon Side)

**Files:**
- Create: `Sources/TBDDaemon/Server/RPCRouter+SubscriptionHandler.swift`
- Modify: `Sources/TBDDaemon/Server/SocketServer.swift:122-185`
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift:55-138`

- [ ] **Step 1: Add the stateSubscribe case to the router switch**

In `Sources/TBDDaemon/Server/RPCRouter.swift`, add inside the switch at line ~136 (before the `default` case):

```swift
case RPCMethod.stateSubscribe:
    // Handled specially by SocketServer — never reaches here
    return RPCResponse(error: "state.subscribe must be handled by SocketServer")
```

- [ ] **Step 2: Create the subscription handler extension**

Create `Sources/TBDDaemon/Server/RPCRouter+SubscriptionHandler.swift`:

```swift
import Foundation
import TBDShared

extension RPCRouter {
    /// Register a subscription callback. Returns the subscriber ID for cleanup.
    public func registerSubscription(writer: @escaping @Sendable (Data) -> Bool) -> StateSubscriptionManager.SubscriberID {
        subscriptions.addSubscriber(writer)
    }

    /// Remove a subscription.
    public func removeSubscription(id: StateSubscriptionManager.SubscriberID) {
        subscriptions.removeSubscriber(id)
    }
}
```

- [ ] **Step 3: Update SocketServer to handle state.subscribe as streaming**

In `Sources/TBDDaemon/Server/SocketServer.swift`, the `SocketRPCHandler` needs to detect `state.subscribe` requests and keep the channel open instead of sending a response. Update `processLine`:

```swift
private static func processLine(_ line: String, router: RPCRouter, wrappedCtx: SendableContext) async {
    guard let data = line.data(using: .utf8) else { return }

    // Check if this is a subscription request
    if let request = try? JSONDecoder().decode(RPCRequest.self, from: data),
       request.method == RPCMethod.stateSubscribe {
        // Register this channel as a subscriber — keep it open
        let context = wrappedCtx.context
        let subscriberID = router.registerSubscription { deltaData in
            // Write delta as newline-delimited JSON to the channel
            guard let deltaString = String(data: deltaData, encoding: .utf8) else { return false }
            var success = true
            context.eventLoop.execute {
                guard context.channel.isActive else {
                    success = false
                    return
                }
                var outBuffer = context.channel.allocator.buffer(capacity: deltaData.count + 1)
                outBuffer.writeString(deltaString)
                outBuffer.writeString("\n")
                context.writeAndFlush(Self.wrapOutboundOut(outBuffer), promise: nil)
            }
            return success
        }

        // Clean up subscription when channel closes
        context.channel.closeFuture.whenComplete { _ in
            router.removeSubscription(id: subscriberID)
        }

        // Send an initial ack so the client knows subscription is active
        let ack = RPCResponse.ok()
        if let ackData = try? JSONEncoder().encode(ack),
           let ackString = String(data: ackData, encoding: .utf8) {
            context.eventLoop.execute {
                guard context.channel.isActive else { return }
                var outBuffer = context.channel.allocator.buffer(capacity: ackString.utf8.count + 1)
                outBuffer.writeString(ackString)
                outBuffer.writeString("\n")
                context.writeAndFlush(Self.wrapOutboundOut(outBuffer), promise: nil)
            }
        }
        return
    }

    // Normal RPC handling
    let response = await router.handleRaw(data)

    do {
        let responseData = try JSONEncoder().encode(response)
        guard let responseString = String(data: responseData, encoding: .utf8) else { return }

        let context = wrappedCtx.context
        context.eventLoop.execute {
            guard context.channel.isActive else { return }
            var outBuffer = context.channel.allocator.buffer(capacity: responseString.utf8.count + 1)
            outBuffer.writeString(responseString)
            outBuffer.writeString("\n")
            context.writeAndFlush(Self.wrapOutboundOut(outBuffer), promise: nil)
        }
    } catch {
        // Encoding error - skip
    }
}
```

**Important caveat:** The `success` variable in the subscription callback has a race — `context.eventLoop.execute` is async. A cleaner approach: always return `context.channel.isActive` directly (read from the callback's capture). Update:

```swift
let subscriberID = router.registerSubscription { deltaData in
    guard let deltaString = String(data: deltaData, encoding: .utf8) else { return false }
    let isActive = context.channel.isActive
    guard isActive else { return false }
    context.eventLoop.execute {
        guard context.channel.isActive else { return }
        var outBuffer = context.channel.allocator.buffer(capacity: deltaData.count + 1)
        outBuffer.writeString(deltaString)
        outBuffer.writeString("\n")
        context.writeAndFlush(Self.wrapOutboundOut(outBuffer), promise: nil)
    }
    return true
}
```

- [ ] **Step 4: Build and verify**

Run: `swift build 2>&1 | tail -20`
Expected: successful build

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter+SubscriptionHandler.swift Sources/TBDDaemon/Server/SocketServer.swift Sources/TBDDaemon/Server/RPCRouter.swift
git commit -m "feat: add state.subscribe RPC for real-time delta streaming

Subscription keeps the socket open and streams newline-delimited JSON
deltas. Auto-cleans up when channel closes or write fails."
```

---

### Task 3: Add Subscription Client to DaemonClient (App Side)

**Files:**
- Modify: `Sources/TBDApp/DaemonClient.swift`

- [ ] **Step 1: Add subscription method and delta callback**

Add to `DaemonClient` after the existing `sendRaw` method (~line 245):

```swift
// MARK: - State Subscription

/// Callback type for receiving state deltas.
typealias DeltaHandler = @Sendable (StateDelta) -> Void

/// Open a persistent socket that receives state deltas from the daemon.
/// Runs in a loop until the socket disconnects or the task is cancelled.
func subscribe(onDelta: @escaping DeltaHandler) async {
    guard FileManager.default.fileExists(atPath: socketPath) else { return }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }

    // Connect
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        close(fd)
        return
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
            for i in 0..<pathBytes.count {
                dest[i] = pathBytes[i]
            }
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    guard connectResult == 0 else {
        close(fd)
        return
    }

    // Send subscribe request
    let request = RPCRequest(method: RPCMethod.stateSubscribe)
    guard let requestData = try? JSONEncoder().encode(request) else {
        close(fd)
        return
    }
    var message = requestData
    message.append(contentsOf: [0x0A]) // newline
    let sent = message.withUnsafeBytes { buffer in
        Darwin.send(fd, buffer.baseAddress!, buffer.count, 0)
    }
    guard sent == message.count else {
        close(fd)
        return
    }

    // Read loop — newline-delimited JSON
    let bufferSize = 65536
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer {
        buffer.deallocate()
        close(fd)
    }

    var accumulated = Data()
    let decoder = JSONDecoder()

    while !Task.isCancelled {
        let bytesRead = recv(fd, buffer, bufferSize, 0)
        if bytesRead <= 0 { break } // disconnected

        accumulated.append(buffer, count: bytesRead)

        // Process complete lines
        while let newlineIndex = accumulated.firstIndex(of: 0x0A) {
            let lineData = accumulated[accumulated.startIndex..<newlineIndex]
            accumulated = accumulated[accumulated.index(after: newlineIndex)...]

            // Skip the initial ack response
            if let response = try? decoder.decode(RPCResponse.self, from: Data(lineData)),
               response.success && response.result == nil {
                continue
            }

            // Try to decode as StateDelta
            if let delta = try? decoder.decode(StateDelta.self, from: Data(lineData)) {
                onDelta(delta)
            }
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `swift build 2>&1 | tail -20`
Expected: successful build

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/DaemonClient.swift
git commit -m "feat: add state subscription client to DaemonClient

Opens a persistent POSIX socket for receiving real-time state deltas.
Reads newline-delimited JSON in a loop, decodes StateDelta, calls handler."
```

---

### Task 4: Wire Up Subscription in AppState + Notification Trigger

**Files:**
- Modify: `Sources/TBDApp/AppState.swift`

- [ ] **Step 1: Add subscription task management and delta handler**

Add properties to `AppState` (after `pollTimer` at ~line 80):

```swift
private var subscriptionTask: Task<Void, Never>?
```

Add subscription start/stop methods:

```swift
/// Start listening for real-time state deltas from the daemon.
func startSubscription() {
    subscriptionTask?.cancel()
    subscriptionTask = Task { [weak self] in
        guard let self else { return }
        await self.daemonClient.subscribe { [weak self] delta in
            Task { @MainActor [weak self] in
                self?.handleDelta(delta)
            }
        }
        // If we get here, subscription disconnected — will reconnect on next poll cycle
    }
}

func stopSubscription() {
    subscriptionTask?.cancel()
    subscriptionTask = nil
}

/// Handle an incoming state delta from the subscription.
private func handleDelta(_ delta: StateDelta) {
    switch delta {
    case .notificationReceived(let notification):
        handleNotificationDelta(notification)
    default:
        break // Other deltas handled by polling for now
    }
}

/// Fire sound/notification for non-visible worktrees.
private func handleNotificationDelta(_ notification: NotificationDelta) {
    let visible = visibleWorktreeIDs
    guard !visible.contains(notification.worktreeID) else { return }

    // Update local notification state
    notifications[notification.worktreeID] = notification.type

    // Fire sound + macOS notification (implemented in Tasks 5 & 6)
    notificationSoundPlayer.playIfEnabled()
    macNotificationManager.postIfEnabled(
        worktreeID: notification.worktreeID,
        message: notification.message,
        worktrees: worktrees
    )
}
```

- [ ] **Step 2: Start subscription on connect, stop on disconnect**

In `connectAndLoadInitialState()` (~line 174), add after `await refreshAll()`:

```swift
startSubscription()
```

In `stopPolling()` (~line 138), add:

```swift
stopSubscription()
```

In `startPolling()` (~line 143), add reconnect logic inside the timer block. After the `if !self.isConnected` check succeeds and `refreshAll()` runs, restart subscription if not active:

```swift
if self.subscriptionTask == nil || self.subscriptionTask?.isCancelled == true {
    self.startSubscription()
}
```

- [ ] **Step 3: Add placeholder properties for services (to be implemented in Tasks 5 & 6)**

Add to `AppState` properties:

```swift
let notificationSoundPlayer = NotificationSoundPlayer()
let macNotificationManager = MacNotificationManager()
```

These will be created in the next tasks. For now, this won't compile — that's expected.

- [ ] **Step 4: Commit (WIP — will compile after Tasks 5 & 6)**

```bash
git add Sources/TBDApp/AppState.swift
git commit -m "feat(wip): wire subscription + notification trigger into AppState

Starts persistent subscription on connect, handles NotificationDelta,
fires sound/notification for non-visible worktrees. Depends on Tasks 5+6."
```

---

### Task 5: NotificationSoundPlayer

**Files:**
- Create: `Sources/TBDApp/Services/NotificationSoundPlayer.swift`

- [ ] **Step 1: Create NotificationSoundPlayer**

Create `Sources/TBDApp/Services/NotificationSoundPlayer.swift`:

```swift
import AppKit
import SwiftUI

/// Plays notification sounds when background Claude sessions complete.
/// Must be @MainActor because NSSound.play() requires the main thread.
@MainActor
final class NotificationSoundPlayer {
    @AppStorage("enableNotificationSounds") private var enabled: Bool = true
    @AppStorage("notificationSoundName") private var soundName: String = "Blow"
    @AppStorage("notificationSoundCustomPath") private var customPath: String = ""

    /// Play the configured notification sound if enabled.
    func playIfEnabled() {
        guard enabled else { return }
        resolveSound()?.play()
    }

    /// Play the configured sound unconditionally (for the "Test" button in settings).
    func playTest() {
        resolveSound()?.play()
    }

    /// Resolve the NSSound from settings.
    private func resolveSound() -> NSSound? {
        if !customPath.isEmpty {
            return NSSound(contentsOf: URL(fileURLWithPath: customPath), byReference: true)
        }
        return NSSound(named: NSSound.Name(soundName))
    }

    /// List all system sound names from /System/Library/Sounds/.
    static func systemSoundNames() -> [String] {
        let soundsDir = "/System/Library/Sounds"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: soundsDir) else {
            return []
        }
        return files
            .filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `swift build 2>&1 | tail -20`
Expected: may fail if AppState references aren't complete yet — that's OK, continue to Task 6

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Services/NotificationSoundPlayer.swift
git commit -m "feat: add NotificationSoundPlayer for idle notification sounds

@MainActor service using NSSound. Supports system sounds from
/System/Library/Sounds/ and custom files. Default: Blow."
```

---

### Task 6: MacNotificationManager

**Files:**
- Create: `Sources/TBDApp/Services/MacNotificationManager.swift`

- [ ] **Step 1: Create MacNotificationManager**

Create `Sources/TBDApp/Services/MacNotificationManager.swift`:

```swift
import Foundation
import UserNotifications
import SwiftUI
import TBDShared

/// Posts macOS notification banners for background Claude session completions.
@MainActor
final class MacNotificationManager {
    @AppStorage("enableNotifications") private var enabled: Bool = true

    private var hasRequestedPermission = false

    /// Request notification permission if not already done.
    func requestPermissionIfNeeded() {
        guard !hasRequestedPermission else { return }
        hasRequestedPermission = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                print("[MacNotificationManager] Permission error: \(error)")
            }
        }
    }

    /// Post a notification for a background worktree if enabled.
    func postIfEnabled(worktreeID: UUID, message: String?, worktrees: [Worktree]) {
        guard enabled else { return }
        requestPermissionIfNeeded()

        let worktreeName = worktrees.first(where: { $0.id == worktreeID })?.displayName
            ?? worktreeID.uuidString

        let truncatedMessage: String
        if let msg = message, !msg.isEmpty {
            truncatedMessage = msg.count > 200 ? String(msg.prefix(200)) + "…" : msg
        } else {
            truncatedMessage = "Claude has finished responding."
        }

        let content = UNMutableNotificationContent()
        content.title = worktreeName
        content.body = truncatedMessage
        content.sound = nil  // Sound handled separately via NSSound

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[MacNotificationManager] Post error: \(error)")
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify everything compiles together**

Run: `swift build 2>&1 | tail -20`
Expected: successful build (AppState now has both services available)

- [ ] **Step 3: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Services/MacNotificationManager.swift
git commit -m "feat: add MacNotificationManager for native macOS notification banners

Posts UNUserNotificationCenter notifications with worktree display name
as title and truncated Claude response as body. Requests permission
on first use."
```

---

### Task 7: Settings UI — Sound Controls

**Files:**
- Modify: `Sources/TBDApp/Settings/SettingsView.swift:23-44`

- [ ] **Step 1: Expand GeneralSettingsTab with sound controls**

Replace the `GeneralSettingsTab` body in `Sources/TBDApp/Settings/SettingsView.swift`:

```swift
struct GeneralSettingsTab: View {
    @AppStorage("enableNotifications") private var enableNotifications: Bool = true
    @AppStorage("skipPermissions") private var skipPermissions: Bool = true
    @AppStorage("autoSuspendClaude") private var autoSuspend: Bool = true
    @AppStorage("enableNotificationSounds") private var enableSounds: Bool = true
    @AppStorage("notificationSoundName") private var soundName: String = "Blow"
    @AppStorage("notificationSoundCustomPath") private var customPath: String = ""

    private var systemSounds: [String] { NotificationSoundPlayer.systemSoundNames() }
    private let soundPlayer = NotificationSoundPlayer()

    /// Display name for the picker: system sound name, or custom filename.
    private var soundDisplayName: String {
        if !customPath.isEmpty {
            return URL(fileURLWithPath: customPath).lastPathComponent
        }
        return soundName
    }

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Enable macOS notifications", isOn: $enableNotifications)
                    .help("Show system notifications when background tasks complete")
                Toggle("Enable notification sounds", isOn: $enableSounds)
                    .help("Play a sound when background tasks complete")

                if enableSounds {
                    HStack {
                        Picker("Sound", selection: Binding(
                            get: { customPath.isEmpty ? soundName : "__custom__" },
                            set: { newValue in
                                if newValue == "__custom__" {
                                    pickCustomSound()
                                } else {
                                    soundName = newValue
                                    customPath = ""
                                }
                            }
                        )) {
                            ForEach(systemSounds, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            Divider()
                            Text("Custom…").tag("__custom__")
                            if !customPath.isEmpty {
                                Text(URL(fileURLWithPath: customPath).lastPathComponent)
                                    .tag("__custom__")
                            }
                        }
                        .frame(maxWidth: 200)

                        Button("Test") {
                            soundPlayer.playTest()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Claude") {
                Toggle("Launch claude with --dangerously-skip-permissions", isOn: $skipPermissions)
                    .help("Skip the interactive permission prompt when launching claude in new worktrees")
                Toggle("Auto-suspend idle Claude when switching worktrees", isOn: $autoSuspend)
                    .help("Exit idle Claude instances when you switch away and resume them when you switch back, freeing memory")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func pickCustomSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "aiff")!,
            .init(filenameExtension: "mp3")!,
            .init(filenameExtension: "wav")!,
            .init(filenameExtension: "m4a")!,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a notification sound"

        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            soundName = "__custom__"
        }
    }
}
```

- [ ] **Step 2: Update SettingsView frame height**

In `SettingsView` body, update the frame:

```swift
.frame(width: 500, height: 420)
```

- [ ] **Step 3: Build and verify**

Run: `swift build 2>&1 | tail -20`
Expected: successful build

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Settings/SettingsView.swift
git commit -m "feat: add notification sound settings UI

System sound picker (enumerates /System/Library/Sounds/), custom file
picker via NSOpenPanel, test button, independent toggles for sound
and notifications. Default: Blow."
```

---

### Task 8: Update Stop Hook Command + Migration

**Files:**
- Modify: `Sources/TBDCLI/Commands/SetupHooksCommand.swift:64,76-88`

- [ ] **Step 1: Update hook command and fix migration**

In `Sources/TBDCLI/Commands/SetupHooksCommand.swift`:

Update the hook command string (line 64):

```swift
let tbdNotifyCommand = #"MSG=$(jq -r '.last_assistant_message // empty' 2>/dev/null); tbd notify --type response_complete --message "$MSG" 2>/dev/null || true"#
```

Fix the migration logic (lines 76-88) to update existing entries when the command string differs:

```swift
// Migrate legacy bare-format entries and update stale hook commands
var found = false
for (i, matcher) in stopHooks.enumerated() {
    if let innerHooks = matcher["hooks"] as? [[String: Any]] {
        // Correct format — check if it's ours
        if innerHooks.contains(where: { ($0["command"] as? String)?.contains("tbd notify") == true }) {
            // Update the command if it changed
            stopHooks[i] = correctEntry
            found = true
        }
    } else if let command = matcher["command"] as? String, command.contains("tbd notify") {
        // Legacy bare format — migrate in place
        stopHooks[i] = correctEntry
        found = true
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `swift build 2>&1 | tail -20`
Expected: successful build

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDCLI/Commands/SetupHooksCommand.swift
git commit -m "feat: update Stop hook to pass Claude response message

Hook now extracts last_assistant_message from stdin JSON via jq.
Migration logic also updates existing hook entries when command changes."
```

---

### Task 9: TBD_WORKTREE_ID Environment Variable

**Files:**
- Modify: `Sources/TBDDaemon/Tmux/TmuxManager.swift:53-58`
- Modify: `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift:48-53`
- Modify: `Sources/TBDCLI/Commands/NotifyCommand.swift:33-51`

- [ ] **Step 1: Extend TmuxManager.newWindowCommand to accept env vars**

In `Sources/TBDDaemon/Tmux/TmuxManager.swift`, update the static method (line 53):

```swift
public static func newWindowCommand(server: String, session: String, cwd: String, shellCommand: String, env: [String: String] = [:]) -> [String] {
    let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    // Build env prefix: export VAR1=val1; export VAR2=val2; exec shell -ic cmd
    var envPrefix = ""
    for (key, value) in env {
        // Shell-safe: single-quote the value, escaping internal single quotes
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        envPrefix += "export \(key)='\(escaped)'; "
    }
    let fullCommand = envPrefix.isEmpty ? shellCommand : "\(envPrefix)\(shellCommand)"
    return ["-L", server, "new-window", "-t", session, "-c", cwd, "-PF", "#{window_id} #{pane_id}", userShell, "-ic", fullCommand]
}
```

- [ ] **Step 2: Pass TBD_WORKTREE_ID when creating Claude terminals**

In `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift`, update `handleTerminalCreate` at ~line 48:

```swift
let env = ["TBD_WORKTREE_ID": params.worktreeID.uuidString]

let window = try await tmux.createWindow(
    server: worktree.tmuxServer,
    session: "main",
    cwd: worktree.path,
    shellCommand: shellCommand,
    env: env
)
```

- [ ] **Step 3: Update TmuxManager.createWindow to accept env parameter**

Find the `createWindow` instance method (that calls the static `newWindowCommand`) and pass through the `env` parameter. The instance method signature needs the same `env` parameter:

```swift
public func createWindow(server: String, session: String, cwd: String, shellCommand: String, env: [String: String] = [:]) async throws -> (windowID: String, paneID: String) {
    let args = Self.newWindowCommand(server: server, session: session, cwd: cwd, shellCommand: shellCommand, env: env)
    // ... rest unchanged
```

- [ ] **Step 4: Update NotifyCommand to check TBD_WORKTREE_ID env var**

In `Sources/TBDCLI/Commands/NotifyCommand.swift`, update the worktree resolution block (~line 33-51):

```swift
// Resolve worktree ID
var worktreeID: UUID?
if let worktree = worktree {
    guard let id = UUID(uuidString: worktree) else {
        return
    }
    worktreeID = id
} else if let envID = ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"],
          let id = UUID(uuidString: envID) {
    // Fast path: env var set by TBD when creating the terminal
    worktreeID = id
} else {
    // Fallback: resolve from PWD
    do {
        let resolver = PathResolver(client: client)
        let result = try resolver.resolve()
        worktreeID = result.worktreeID
    } catch {
        return
    }
}
```

- [ ] **Step 5: Update TmuxManager tests if they call newWindowCommand**

Run: `grep -n "newWindowCommand" Tests/`

Update any test that calls `newWindowCommand` to account for the new `env` parameter (it has a default value so existing calls should still compile).

- [ ] **Step 6: Build and run tests**

Run: `swift build 2>&1 | tail -20 && swift test 2>&1 | tail -20`
Expected: build succeeds, all tests pass

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDDaemon/Tmux/TmuxManager.swift Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift Sources/TBDCLI/Commands/NotifyCommand.swift
git commit -m "feat: set TBD_WORKTREE_ID env var in Claude terminals

Terminal creation exports TBD_WORKTREE_ID into the tmux shell env.
NotifyCommand checks this env var first for fast worktree resolution,
falling back to CWD-based PathResolver."
```

---

### Task 10: Final Integration Test + Build Verification

**Files:**
- All previously modified files

- [ ] **Step 1: Full build**

Run: `swift build 2>&1 | tail -30`
Expected: successful build with no warnings related to our changes

- [ ] **Step 2: Full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: all tests pass

- [ ] **Step 3: Verify hook installation works**

Run: `swift run tbd setup-hooks --global 2>&1`
Expected: "Global hooks installed at ~/.claude/settings.json"

Verify the hook content:
Run: `cat ~/.claude/settings.json | jq '.hooks.Stop'`
Expected: shows the updated tbd notify command with `--message "$MSG"`

- [ ] **Step 4: Commit any final fixes**

If any fixes were needed, commit them.

- [ ] **Step 5: Final commit — update spec with any deviations**

If the implementation diverged from the spec, update the spec doc to match reality.

```bash
git add -A
git commit -m "docs: update spec to match implementation"
```
