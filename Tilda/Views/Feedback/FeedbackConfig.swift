import Foundation
import UIKit

/// Single home for the feedback flow's repo slug, URLs and report builder.
/// No tokens or secrets: reports go out as a prefilled public GitHub "new issue" page.
enum FeedbackConfig {
    static let repoSlug = "augie15/lidar-app"
    static let issuesNewURL = "https://github.com/\(repoSlug)/issues/new"
    static let supportPageURL = URL(string: "https://augie15.github.io/lidar-app/support.html")!

    static let supportEmail: String? = "brett@augiesrentals.ca"

    /// Keep the whole URL comfortably below GitHub's practical limit.
    static let maxURLLength = 7_000

    static let scanModes = ["Room", "Whole floor", "Object Photoreal", "Object LiDAR quick",
                            "Mesh", "Point cloud", "Surfaces"]
}

enum FeedbackKind: String, CaseIterable, Identifiable {
    case problem, feature
    var id: String { rawValue }

    var title: String { self == .problem ? "Report a problem" : "Request a feature" }
    var template: String { self == .problem ? "bug_report.yml" : "feature_request.yml" }
    var label: String { self == .problem ? "bug" : "enhancement" }
    var titlePrompt: String { self == .problem ? "What went wrong?" : "What would you like?" }
    var detailsPrompt: String {
        self == .problem ? "What happened, and what did you expect?" : "Describe the idea and what it would help you do."
    }
}

/// Non-personal diagnostics included with a report.
struct FeedbackDiagnostics: Equatable {
    var appVersion: String
    var build: String
    var iOSVersion: String
    var deviceModel: String

    var appVersionAndBuild: String { "\(appVersion) (\(build))" }

    static var current: FeedbackDiagnostics {
        let info = Bundle.main.infoDictionary
        var sys = utsname()
        uname(&sys)
        let model = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        return FeedbackDiagnostics(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info?["CFBundleVersion"] as? String ?? "unknown",
            iOSVersion: "iOS \(UIDevice.current.systemVersion)",
            deviceModel: model)
    }
}

enum FeedbackURLBuilder {
    /// Strict percent-encoding: only RFC 3986 unreserved characters pass through.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static let truncationNote = "\n\n[Details truncated to fit in a link.]"

    static func url(kind: FeedbackKind, title: String, details: String, steps: String? = nil,
                    scanMode: String?, diagnostics d: FeedbackDiagnostics,
                    maxLength: Int = FeedbackConfig.maxURLLength) -> URL? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = details.trimmingCharacters(in: .whitespacesAndNewlines)

        func make(_ text: String) -> String {
            var q: [(String, String)] = [("template", kind.template), ("title", trimmedTitle),
                                         ("labels", kind.label), ("description", text)]
            if let steps, !steps.isEmpty { q.append(("steps", steps)) }
            if let scanMode, !scanMode.isEmpty { q.append(("scan_mode", scanMode)) }
            q.append(("app_version", d.appVersionAndBuild))
            q.append(("ios_version", d.iOSVersion))
            q.append(("device", d.deviceModel))
            return FeedbackConfig.issuesNewURL + "?" + q.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        }

        var s = make(body)
        if s.count > maxLength {
            // Binary search the longest prefix that fits with the note appended.
            var lo = 0, hi = body.count
            let chars = Array(body)
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if make(String(chars[..<mid]) + truncationNote).count <= maxLength { lo = mid } else { hi = mid - 1 }
            }
            body = String(chars[..<lo]) + truncationNote
            s = make(body)
        }
        return URL(string: s)
    }

    static func emailSubject(kind: FeedbackKind, title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[Tilda] \(kind == .problem ? "Problem" : "Feature"): \(t)"
    }

    static func emailBody(details: String, scanMode: String?, diagnostics d: FeedbackDiagnostics) -> String {
        var lines = [details.trimmingCharacters(in: .whitespacesAndNewlines), "", "---"]
        if let scanMode, !scanMode.isEmpty { lines.append("Scan mode: \(scanMode)") }
        lines.append("App version: \(d.appVersionAndBuild)")
        lines.append("iOS version: \(d.iOSVersion)")
        lines.append("Device: \(d.deviceModel)")
        return lines.joined(separator: "\n")
    }

    static func mailto(email: String, kind: FeedbackKind, title: String, details: String,
                       scanMode: String?, diagnostics d: FeedbackDiagnostics) -> URL? {
        URL(string: "mailto:\(email)?subject=\(encode(emailSubject(kind: kind, title: title)))&body=\(encode(emailBody(details: details, scanMode: scanMode, diagnostics: d)))")
    }
}
