import Foundation

// 通过 Apple Music 的 AppleScript 接口获取当前曲目信息
struct TrackInfo: Equatable, Sendable {
    let id: String         // 本地数据库 id（用来检测曲目切换）
    let name: String
    let artist: String
    let duration: Double

    static let empty = TrackInfo(id: "", name: "", artist: "", duration: 0)
}

// TTML <span> 标签对应的单个词，包含独立的起止时间戳
struct LyricWord: Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

// 一行歌词，包含文本、行级起止时间和字级数据
struct LyricsLine: Identifiable, Equatable {
    let id = UUID()
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let words: [LyricWord]   // 按时间戳排序的词列表，可能为空（静态歌词）

    static func == (lhs: LyricsLine, rhs: LyricsLine) -> Bool {
        lhs.id == rhs.id
    }
}

// 通过 NSAppleScript 与 Apple Music 进程通信，获取当前播放状态
final class MusicBridge {
    private let trackScript: NSAppleScript
    private let positionScript: NSAppleScript

    init?() {
        guard let ts = NSAppleScript(source: """
            tell application "System Events"
                if exists (process "Music") then
                    tell application "Music"
                        set t to current track
                        return (name of t) & "\\n" & (artist of t) & "\\n" & (id of t) & "\\n" & (duration of t)
                    end tell
                end if
                return "NOT_PLAYING"
            end tell
            """),
              let ps = NSAppleScript(source: """
            tell application "System Events"
                if exists (process "Music") then
                    tell application "Music"
                        return player position as string
                    end tell
                end if
                return "-1"
            end tell
            """)
        else { return nil }

        self.trackScript = ts
        self.positionScript = ps
    }

    func getCurrentTrack() -> TrackInfo? {
        var error: NSDictionary?
        let result = trackScript.executeAndReturnError(&error)
        guard error == nil else { return nil }

        let raw = result.stringValue ?? ""
        if raw == "NOT_PLAYING" { return nil }

        let parts = raw.components(separatedBy: "\n")
        guard parts.count >= 4 else { return nil }

        return TrackInfo(
            id: parts[2],
            name: parts[0],
            artist: parts[1],
            duration: Double(parts[3]) ?? 0
        )
    }

    // 获取当前播放位置（秒），返回 -1 表示未播放
    func getPlayerPosition() -> Double {
        var error: NSDictionary?
        let result = positionScript.executeAndReturnError(&error)
        guard error == nil else { return -1 }
        return Double(result.stringValue ?? "-1") ?? -1
    }
}
