import Foundation

/// AppleScript calls into Finder. Not actor-isolated: callers run these on one serial queue.
enum FinderScript {
    enum Failure: Error {
        case notAuthorized
        case failed(String)
    }

    /// Finder positions of every Desktop item, keyed by item name. Points, origin at the
    /// top-left of the main display, measured to the icon's center.
    static func desktopPositions() -> Result<[String: CGPoint], Failure> {
        let source = """
        tell application "Finder"
            set names to name of every item of desktop
            set positions to desktop position of every item of desktop
        end tell
        set out to ""
        repeat with i from 1 to count of names
            set p to item i of positions
            set out to out & (item i of names) & tab & (item 1 of p) & tab & (item 2 of p) & linefeed
        end repeat
        return out
        """
        return run(source).map { descriptor in
            var positions: [String: CGPoint] = [:]
            for line in (descriptor.stringValue ?? "").split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) else { continue }
                positions[String(parts[0])] = CGPoint(x: x, y: y)
            }
            return positions
        }
    }

    @discardableResult
    static func setPositions(_ moves: [String: CGPoint]) -> Failure? {
        guard !moves.isEmpty else { return nil }
        let lines = moves.map { name, point in
            """
                try
                    set desktop position of item \(quoted(name)) of desktop to {\(Int(point.x.rounded())), \(Int(point.y.rounded()))}
                end try
            """
        }
        let source = "tell application \"Finder\"\n" + lines.joined(separator: "\n") + "\nend tell"
        if case .failure(let failure) = run(source) { return failure }
        return nil
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(_ source: String) -> Result<NSAppleEventDescriptor, Failure> {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(.failed("Could not compile script")) }
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { return .failure(.notAuthorized) }
            return .failure(.failed(error[NSAppleScript.errorMessage] as? String ?? "\(error)"))
        }
        return .success(result)
    }
}
