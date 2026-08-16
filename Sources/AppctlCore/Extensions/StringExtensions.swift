import Foundation

extension String {
    public func formattedDate(style: DateFormatter.Style = .medium) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: self) { return d.relativeOrAbsolute() }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: self)?.relativeOrAbsolute() ?? self
    }
    public var isExpired: Bool {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: self) { return d < Date() }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: self).map { $0 < Date() } ?? false
    }
    public var daysUntil: Int? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: self)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime]
            date = iso.date(from: self)
        }
        return date.flatMap { Calendar.current.dateComponents([.day], from: Date(), to: $0).day }
    }
    public func truncated(to length: Int) -> String { count <= length ? self : String(prefix(length - 1)) + "…" }
    public func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
    public var processingStateDisplay: String {
        switch uppercased() {
        case "PROCESSING": return "⏳ Processing"
        case "FAILED": return "❌ Failed"
        case "INVALID": return "❌ Invalid"
        case "VALID": return "✅ Valid"
        default: return self
        }
    }
    public var versionStateDisplay: String {
        switch uppercased() {
        case "READY_FOR_SALE": return "🟢 Ready for Sale"
        case "IN_REVIEW": return "🔍 In Review"
        case "WAITING_FOR_REVIEW": return "⏳ Waiting for Review"
        case "PREPARE_FOR_SUBMISSION": return "📝 Prepare for Submission"
        case "REJECTED": return "❌ Rejected"
        case "DEVELOPER_REJECTED": return "🔄 Developer Rejected"
        case "PENDING_DEVELOPER_RELEASE": return "⏳ Pending Release"
        case "READY_FOR_REVIEW": return "📋 Ready for Review"
        case "PROCESSING_FOR_APP_STORE": return "⏳ Processing"
        case "WAITING_FOR_EXPORT_COMPLIANCE": return "⏳ Awaiting Compliance"
        default: return self
        }
    }
    public var certificateTypeDisplay: String {
        switch self {
        case "IOS_DISTRIBUTION": return "iOS Distribution"
        case "IOS_DEVELOPMENT": return "iOS Development"
        case "MAC_APP_DISTRIBUTION": return "Mac Distribution"
        case "MAC_APP_DEVELOPMENT": return "Mac Development"
        default: return replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    public var displayTypeLabel: String {
        switch self {
        case "APP_IPHONE_67": return "iPhone 6.7\"/6.9\""
        case "APP_IPHONE_65": return "iPhone 6.5\""
        case "APP_IPHONE_61": return "iPhone 6.1\"/6.3\""
        case "APP_IPHONE_58": return "iPhone 5.8\""
        case "APP_IPHONE_55": return "iPhone 5.5\""
        case "APP_IPHONE_47": return "iPhone 4.7\""
        case "APP_IPHONE_40": return "iPhone 4\""
        case "APP_IPHONE_35": return "iPhone 3.5\""
        case "APP_IPAD_PRO_3GEN_129": return "iPad Pro 12.9\"/13\""
        case "APP_IPAD_PRO_3GEN_11": return "iPad 11\""
        case "APP_IPAD_105": return "iPad 10.5\""
        case "APP_IPAD_97": return "iPad 9.7\""
        default: return replacingOccurrences(of: "_", with: " ")
        }
    }
}

extension Date {
    func relativeOrAbsolute() -> String {
        let interval = Date().timeIntervalSince(self)
        if abs(interval) < 60 { return "just now" }
        if abs(interval) < 3600 { return interval > 0 ? "\(Int(interval/60))m ago" : "in \(Int(abs(interval)/60))m" }
        if abs(interval) < 86400 {
            return interval > 0 ? "\(Int(interval/3600))h ago" : "in \(Int(abs(interval)/3600))h"
        }
        if abs(interval) < 604800 {
            return interval > 0 ? "\(Int(interval/86400))d ago" : "in \(Int(abs(interval)/86400))d"
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: self)
    }
}
