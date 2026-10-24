import AppKit
import ApplicationServices
import Foundation

struct Options {
    let command: String
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String]) {
        command = arguments.dropFirst().first ?? ""
        var index = 2
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let body = String(argument.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    values[String(body[..<equals])] = String(body[body.index(after: equals)...])
                } else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    values[body] = arguments[index + 1]
                    index += 1
                } else {
                    flags.insert(body)
                }
            }
            index += 1
        }
    }

    func value(_ key: String) -> String? { values[key] }
    func int(_ key: String) -> Int? { values[key].flatMap(Int.init) }
    func double(_ key: String) -> Double? { values[key].flatMap(Double.init) }
    func has(_ key: String) -> Bool { flags.contains(key) }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return error == .success ? value : nil
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    if let value = attribute(element, name) as? String { return value }
    if let value = attribute(element, name) as? NSString { return value as String }
    if let value = attribute(element, name) as? NSNumber { return value.stringValue }
    return nil
}

func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
    (attribute(element, name) as? NSNumber)?.boolValue
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

func actions(_ element: AXUIElement) -> [String] {
    var value: CFArray?
    let error = AXUIElementCopyActionNames(element, &value)
    guard error == .success, let names = value as? [String] else { return [] }
    return names
}

func frame(_ element: AXUIElement) -> (CGPoint, CGSize)? {
    guard let positionValue = attribute(element, kAXPositionAttribute as String),
          let sizeValue = attribute(element, kAXSizeAttribute as String) else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    return (point, size)
}

func elementInfo(_ element: AXUIElement) -> [String: Any] {
    var info: [String: Any] = [
        "role": stringAttribute(element, kAXRoleAttribute as String) ?? "",
        "actions": actions(element),
    ]
    if let subrole = stringAttribute(element, kAXSubroleAttribute as String) { info["subrole"] = subrole }
    if let identifier = stringAttribute(element, kAXIdentifierAttribute as String) { info["identifier"] = identifier }
    if let title = stringAttribute(element, kAXTitleAttribute as String) { info["title"] = title }
    if let description = stringAttribute(element, kAXDescriptionAttribute as String) { info["description"] = description }
    if let help = stringAttribute(element, kAXHelpAttribute as String) { info["help"] = help }
    if let value = stringAttribute(element, kAXValueAttribute as String) { info["value"] = value }
    if let enabled = boolAttribute(element, kAXEnabledAttribute as String) { info["enabled"] = enabled }
    if let selected = boolAttribute(element, kAXSelectedAttribute as String) { info["selected"] = selected }
    if let focused = boolAttribute(element, kAXFocusedAttribute as String) { info["focused"] = focused }
    if let (point, size) = frame(element) {
        info["x"] = point.x
        info["y"] = point.y
        info["width"] = size.width
        info["height"] = size.height
    }
    return info
}

func labelText(_ element: AXUIElement) -> String {
    [
        stringAttribute(element, kAXTitleAttribute as String),
        stringAttribute(element, kAXDescriptionAttribute as String),
        stringAttribute(element, kAXValueAttribute as String),
        stringAttribute(element, kAXHelpAttribute as String),
    ].compactMap { $0 }.joined(separator: " ")
}

func matches(_ element: AXUIElement, id: String?, prefix: String?, role: String?, label: String?) -> Bool {
    let identifier = stringAttribute(element, kAXIdentifierAttribute as String)
    if let id, identifier != id { return false }
    if let prefix, !(identifier ?? "").hasPrefix(prefix) { return false }
    if let role, stringAttribute(element, kAXRoleAttribute as String) != role { return false }
    if let label {
        let needle = label.lowercased()
        if !labelText(element).lowercased().contains(needle) { return false }
    }
    return id != nil || prefix != nil || role != nil || label != nil
}

func walk(_ root: AXUIElement, visitor: (AXUIElement, Int) -> Bool) {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var seen: Set<CFHashCode> = []
    var count = 0
    while let (element, depth) = stack.popLast() {
        count += 1
        if count > 20_000 { return }
        let hash = CFHash(element)
        if seen.contains(hash) { continue }
        seen.insert(hash)
        if !visitor(element, depth) { return }
        if depth >= 60 { continue }
        for child in children(element).reversed() {
            stack.append((child, depth + 1))
        }
    }
}

func findElements(_ root: AXUIElement, options: Options) -> [AXUIElement] {
    let id = options.value("id")
    let prefix = options.value("id-prefix")
    let role = options.value("role")
    let label = options.value("label")
    var found: [AXUIElement] = []
    walk(root) { element, _ in
        if matches(element, id: id, prefix: prefix, role: role, label: label) {
            found.append(element)
        }
        return true
    }
    return found
}

func appElement(_ options: Options) -> AXUIElement? {
    guard let pid = options.int("pid") else { return nil }
    return AXUIElementCreateApplication(pid_t(pid))
}

func waitForElement(_ root: AXUIElement, options: Options) -> AXUIElement? {
    let timeout = options.double("timeout") ?? 0
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let found = findElements(root, options: options)
        if found.count > (options.int("index") ?? 0) {
            return found[options.int("index") ?? 0]
        }
        if Date() >= deadline { break }
        usleep(100_000)
    } while true
    return nil
}

func json(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}

func fail(_ message: String, code: Int32 = 4) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func activate(_ pid: pid_t) {
    guard let running = NSRunningApplication(processIdentifier: pid),
          running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) else {
        fail("could not activate test app")
    }
    usleep(150_000)
}

func raiseWindow(_ app: AXUIElement) {
    guard let windows = attribute(app, kAXWindowsAttribute as String) as? [AXUIElement], let window = windows.first else { return }
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    usleep(100_000)
}

func windowOwner(at point: CGPoint) -> pid_t? {
    guard let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else { return nil }
    for window in windows {
        if let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue != 0 { continue }
        if let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 { continue }
        guard let b = window[kCGWindowBounds as String] as? [String: NSNumber],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { continue }
        let rect = CGRect(x: x.doubleValue, y: y.doubleValue, width: w.doubleValue, height: h.doubleValue)
        if rect.contains(point), let owner = window[kCGWindowOwnerPID as String] as? NSNumber {
            return owner.int32Value
        }
    }
    return nil
}

func click(_ element: AXUIElement, pid: pid_t) {
    guard let (point, size) = frame(element) else { fail("element has no frame") }
    let target = CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
    activate(pid)
    let app = AXUIElementCreateApplication(pid)
    raiseWindow(app)
    guard let windows = attribute(app, kAXWindowsAttribute as String) as? [AXUIElement],
          !windows.isEmpty else {
        fail("test app has no window; refusing to click")
    }
    func contains(_ window: AXUIElement) -> Bool {
        guard let (windowPoint, windowSize) = frame(window) else { return false }
        return target.x >= windowPoint.x && target.x <= windowPoint.x + windowSize.width
            && target.y >= windowPoint.y && target.y <= windowPoint.y + windowSize.height
    }
    var inside = windows.contains(where: contains)
    if !inside {
        usleep(250_000)
        let retry = attribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        inside = retry.contains(where: contains)
    }
    guard inside else {
        if pressAncestors(element) { return }
        fail("target is outside the test app window; refusing to click")
    }
    guard windowOwner(at: target) == pid else {
        fail("another window is above the click target; refusing to click")
    }
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
    return list
}

func pressAncestors(_ element: AXUIElement) -> Bool {
    var current: AXUIElement? = element
    for _ in 0..<5 {
        guard let candidate = current else { return false }
        if actionNames(candidate).contains(kAXPressAction as String),
           AXUIElementPerformAction(candidate, kAXPressAction as CFString) == .success {
            return true
        }
        guard let parent = attribute(candidate, kAXParentAttribute as String) as! AXUIElement? else { return false }
        current = parent
    }
    return false
}

func press(_ element: AXUIElement, pid: pid_t) {
    let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
    if error != .success {
        click(element, pid: pid)
    }
}

func keyCode(_ key: String) -> CGKeyCode? {
    let map: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "return": 36,
        "escape": 53, "delete": 51, "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    return map[key.lowercased()]
}

func eventFlags(_ names: String?) -> CGEventFlags {
    var flags: CGEventFlags = []
    for name in (names ?? "").split(separator: ",") {
        switch name {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: break
        }
    }
    return flags
}

func sendKey(_ key: String, flags: CGEventFlags, pid: pid_t? = nil) {
    guard let code = keyCode(key) else { fail("unknown key: \(key)") }
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    down?.flags = flags
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
    if let pid {
        down?.postToPid(pid)
        up?.postToPid(pid)
    }
}

func typeText(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    let units = Array(text.utf16)
    guard !units.isEmpty else { return }
    var buffer = units
    let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
    down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
    up?.post(tap: .cghidEventTap)
}

func main() {
    let options = Options(CommandLine.arguments)
    if options.command == "trusted" {
        print(json(["trusted": AXIsProcessTrusted()]))
        return
    }
    guard options.command != "" else { fail("usage: AXDriver <command> --pid <pid> [options]", code: 2) }
    guard let app = appElement(options) else { fail("missing --pid", code: 2) }
    let pid = pid_t(options.int("pid")!)

    switch options.command {
    case "find", "wait":
        if options.command == "find", options.double("timeout") == nil {
            var mutating = options
            mutating.values["timeout"] = "0"
            guard let element = waitForElement(app, options: mutating) else {
                print(json(["found": false]))
                exit(3)
            }
            print(json(elementInfo(element)))
        } else {
            guard let element = waitForElement(app, options: options) else {
                print(json(["found": false]))
                exit(3)
            }
            print(json(elementInfo(element)))
        }
    case "find-all":
        let elements = findElements(app, options: options)
        print(json(elements.map(elementInfo)))
        if elements.isEmpty { exit(3) }
    case "press":
        guard let element = waitForElement(app, options: options) else { fail("element not found", code: 3) }
        activate(pid)
        press(element, pid: pid)
        print(json(["pressed": true]))
    case "click":
        guard let element = waitForElement(app, options: options) else { fail("element not found", code: 3) }
        activate(pid)
        click(element, pid: pid)
        print(json(["clicked": true]))
    case "set":
        guard let element = waitForElement(app, options: options) else { fail("element not found", code: 3) }
        guard let value = options.value("value") else { fail("missing --value", code: 2) }
        activate(pid)
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        if error != .success { fail("set value failed: \(error.rawValue)") }
        print(json(["set": true]))
    case "type":
        guard let element = waitForElement(app, options: options) else { fail("element not found", code: 3) }
        guard let text = options.value("text") else { fail("missing --text", code: 2) }
        activate(pid)
        click(element, pid: pid)
        usleep(100_000)
        if options.has("clear") { sendKey("a", flags: .maskCommand) }
        for character in text {
            let key = String(character)
            if keyCode(key) != nil {
                sendKey(key, flags: [])
            } else {
                typeText(key)
            }
            usleep(40_000)
        }
        print(json(["typed": true]))
    case "key":
        guard let key = options.value("key") else { fail("missing --key", code: 2) }
        activate(pid)
        raiseWindow(app)
        sendKey(key, flags: eventFlags(options.value("modifiers")), pid: pid)
        print(json(["key": key]))
    case "menu":
        guard let title = options.value("item") else { fail("missing --item", code: 2) }
        guard let menuBar = attribute(app, kAXMenuBarAttribute as String) as! AXUIElement? else {
            fail("no menu bar")
        }
        var target: AXUIElement?
        walk(menuBar) { element, _ in
            if stringAttribute(element, kAXRoleAttribute as String) == kAXMenuItemRole as String,
               stringAttribute(element, kAXTitleAttribute as String) == title {
                target = element
                return false
            }
            return true
        }
        guard let target else { fail("menu item not found: \(title)", code: 3) }
        activate(pid)
        press(target, pid: pid)
        print(json(["menu": title]))
    case "extras":
        guard let extras = attribute(app, "AXExtrasMenuBar") as! AXUIElement? else { fail("no extras menu bar") }
        print(json(children(extras).map(elementInfo)))
    case "menubar":
        guard let extras = attribute(app, "AXExtrasMenuBar") as! AXUIElement? else { fail("no extras menu bar") }
        let items = children(extras)
        guard !items.isEmpty else { fail("no status items") }
        let index = max(0, min(items.count - 1, options.int("index") ?? 0))
        activate(pid)
        press(items[index], pid: pid)
        print(json(elementInfo(items[index])))
    case "close-window":
        guard let windows = attribute(app, kAXWindowsAttribute as String) as? [AXUIElement], let window = windows.first else {
            fail("no window", code: 3)
        }
        guard let close = attribute(window, kAXCloseButtonAttribute as String) as! AXUIElement? else {
            fail("no close button", code: 3)
        }
        press(close, pid: pid)
        print(json(["closed": true]))
    case "windows":
        let windows = attribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        print(json(windows.map(elementInfo)))
    case "window-id":
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) }
            .compactMap { $0[kCGWindowNumber as String] as? Int }
        print(json(ids))
    case "dump":
        let root = options.value("id").flatMap { id in
            var query = options
            query.values["id"] = id
            return findElements(app, options: query).first
        } ?? app
        var tree: [String: Any] = elementInfo(root)
        var descendants: [[String: Any]] = []
        walk(root) { element, depth in
            guard depth > 0 else { return true }
            var info = elementInfo(element)
            info["depth"] = depth
            descendants.append(info)
            return true
        }
        tree["children"] = descendants
        let output = json(tree)
        if let path = options.value("out") {
            try? output.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            print(output)
        }
    case "activate":
        activate(pid)
        print(json(["active": true]))
    default:
        fail("unknown command: \(options.command)", code: 2)
    }
}

main()
