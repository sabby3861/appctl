import Foundation

public struct OutputFormatter: Sendable {
    public let format: OutputFormat
    public let useColor: Bool

    public init(format: OutputFormat = .text, noColor: Bool = false) {
        self.format = format
        self.useColor = !noColor && isatty(STDOUT_FILENO) == 1
    }

    /// In JSON mode all stderr decoration is suppressed so piped consumers get clean
    /// output. Real errors still surface — they are thrown and printed by ArgumentParser.
    private var isQuiet: Bool { format == .json }

    public func success(_ msg: String) {
        guard !isQuiet else { return }
        printErr("\(useColor ? "\u{001B}[32m✓\u{001B}[0m" : "✓") \(msg)")
    }

    public func error(_ msg: String) {
        guard !isQuiet else { return }
        printErr("\(useColor ? "\u{001B}[31m✗\u{001B}[0m" : "✗") \(msg)")
    }

    public func warning(_ msg: String) {
        guard !isQuiet else { return }
        printErr("\(useColor ? "\u{001B}[33m⚠\u{001B}[0m" : "⚠") \(msg)")
    }

    public func info(_ msg: String) {
        guard !isQuiet else { return }
        printErr("\(useColor ? "\u{001B}[34m●\u{001B}[0m" : "●") \(msg)")
    }

    public func printList<T>(_ items: [T], columns: [Column<T>], emptyMessage: String = "No items found.") {
        guard !items.isEmpty else {
            printErr(emptyMessage)
            return
        }
        switch format {
        case .json: printJSON(items, columns: columns)
        case .csv: printCSV(items, columns: columns)
        case .text, .table: printTable(items, columns: columns)
        }
    }

    public func printDetail(fields: [(label: String, value: String)]) {
        if format == .json {
            var d: [String: String] = [:]
            for f in fields { d[f.label.lowercased().replacingOccurrences(of: " ", with: "_")] = f.value }
            if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]),
                let s = String(data: data, encoding: .utf8)
            {
                print(s)
            }
            return
        }
        let maxW = fields.map { $0.label.count }.max() ?? 0
        for f in fields {
            let label = f.label.padding(toLength: maxW + 1, withPad: " ", startingAt: 0)
            print(useColor ? "\u{001B}[1m\(label)\u{001B}[0m \(f.value)" : "\(label) \(f.value)")
        }
    }

    public func startSpinner(_ message: String) -> SpinnerHandle {
        let s = SpinnerHandle(message: message, useColor: useColor, silent: isQuiet)
        s.start()
        return s
    }

    private func printJSON<T>(_ items: [T], columns: [Column<T>]) {
        let arr = items.map { item in
            Dictionary(
                uniqueKeysWithValues: columns.map {
                    ($0.header.lowercased().replacingOccurrences(of: " ", with: "_"), $0.value(item))
                })
        }
        if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys]),
            let s = String(data: data, encoding: .utf8)
        {
            print(s)
        }
    }

    private func printCSV<T>(_ items: [T], columns: [Column<T>]) {
        print(columns.map { $0.header }.joined(separator: ","))
        for item in items { print(columns.map { $0.value(item) }.joined(separator: ",")) }
    }

    private func printTable<T>(_ items: [T], columns: [Column<T>]) {
        var widths = columns.map { $0.header.count }
        for item in items { for (i, col) in columns.enumerated() { widths[i] = max(widths[i], col.value(item).count) } }
        // Clamp to [1, 50] — the lower bound prevents `prefix(widths[i] - 1)` from
        // trapping if both header and every value happen to be empty strings.
        widths = widths.map { max(1, min($0, 50)) }
        let headerLine = columns.enumerated().map { i, c in
            c.header.padding(toLength: widths[i], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
        printErr(useColor ? "\u{001B}[1m\(headerLine)\u{001B}[0m" : headerLine)
        printErr(widths.map { String(repeating: "─", count: $0) }.joined(separator: "──"))
        for item in items {
            print(
                columns.enumerated().map { i, c in
                    let v = c.value(item)
                    let t = v.count > widths[i] ? String(v.prefix(widths[i] - 1)) + "…" : v
                    return t.padding(toLength: widths[i], withPad: " ", startingAt: 0)
                }.joined(separator: "  "))
        }
        printErr("\n\(items.count) item\(items.count == 1 ? "" : "s")")
    }

    private func printErr(_ msg: String) {
        var s = StandardError.shared
        Swift.print(msg, to: &s)
    }
}

public struct Column<T>: Sendable {
    public let header: String
    public let value: @Sendable (T) -> String
    public init(header: String, value: @escaping @Sendable (T) -> String) {
        self.header = header
        self.value = value
    }
}

// `@unchecked Sendable`: mutable state (`_isRunning`, `task`) is guarded by `lock`.
// An actor would force `stop()` to become async, which is awkward for the typical
// `defer { spinner.stop() }` call pattern in commands.
public final class SpinnerHandle: @unchecked Sendable {
    private let message: String
    private let useColor: Bool
    private let silent: Bool
    private let lock = NSLock()
    private var _isRunning = false
    private var task: Task<Void, Never>?

    private var isRunning: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isRunning
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _isRunning = newValue
        }
    }

    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    init(message: String, useColor: Bool, silent: Bool = false) {
        self.message = message
        self.useColor = useColor
        self.silent = silent
    }

    func start() {
        if silent { return }
        guard isatty(STDERR_FILENO) == 1 else {
            var s = StandardError.shared
            Swift.print("  \(message)...", to: &s)
            return
        }
        isRunning = true
        task = Task { [weak self] in
            var i = 0
            while let self = self, self.isRunning, !Task.isCancelled {
                var s = StandardError.shared
                Swift.print(
                    "\r  \(Self.frames[i % Self.frames.count]) \(self.message)",
                    terminator: "",
                    to: &s
                )
                i += 1
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    public func stop(success: Bool = true) {
        if silent { return }
        isRunning = false
        task?.cancel()
        task = nil
        guard isatty(STDERR_FILENO) == 1 else { return }
        var s = StandardError.shared
        let sym =
            useColor
            ? (success ? "\u{001B}[32m✓\u{001B}[0m" : "\u{001B}[31m✗\u{001B}[0m")
            : (success ? "✓" : "✗")
        Swift.print("\r  \(sym) \(message)", to: &s)
    }
}
