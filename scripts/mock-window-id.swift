import AppKit

// Prints the on-screen window number owned by <pid> with the largest area.
// Uses CGWindowList (owner PID + bounds need no extra permission beyond the
// Screen Recording grant screencapture already requires).

guard CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: mock-window-id.swift <pid>\n".utf8))
    exit(2)
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

var best: (number: Int, area: CGFloat)?
for window in windows {
    guard let owner = window[kCGWindowOwnerPID as String] as? Int32, owner == pid,
          let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
          let width = bounds["Width"], let height = bounds["Height"] else { continue }
    let area = width * height
    if best == nil || area > best!.area { best = (number, area) }
}

guard let best else { exit(1) }
print(best.number)
