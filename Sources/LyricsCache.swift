import Foundation
import SQLite3

// 从 Apple Music 本地 SQLite 缓存读取歌词。
// 缓存位置: ~/Library/Caches/com.apple.Music/Cache.db
// 数据链路: cfurl_cache_response × cfurl_cache_receiver_data → JSON → TTML / 静态文本
final class LyricsCache {
    private let cachePath: String
    private var db: OpaquePointer?

    init() {
        self.cachePath = (("~/Library/Caches/com.apple.Music/Cache.db" as NSString)
            .expandingTildeInPath)
    }

    func open() -> Bool {
        sqlite3_open(cachePath, &db) == SQLITE_OK
    }

    func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    deinit { close() }

    // 按优先级查找歌词：
    // 1. 歌曲 ID 精确匹配 → TTML
    // 2. 名称+歌手模糊匹配 → TTML 或静态歌词
    // 3. 无过滤的全文搜索 → 静态歌词
    func fetchLyrics(storeId: String, name: String, artist: String, songDuration: Double = 0) -> [LyricsLine]? {
        guard let db else { return nil }

        if !storeId.isEmpty, let ttml = fetchRawTTML(songId: storeId) {
            return parseTTML(ttml)
        }

        if let lines = searchByNameArtist(name: name, artist: artist, db: db) {
            return lines
        }

        return searchStaticLyrics(name: name, artist: artist, songDuration: songDuration, db: db)
    }

    // MARK: - Cache Query

    // 按 include=syllable-lyrics 查询，命中带逐字时间戳的 TTML 响应
    private func searchByNameArtist(name: String, artist: String, db: OpaquePointer) -> [LyricsLine]? {
        let query = """
            SELECT r.request_key, d.isDataOnFS, d.receiver_data
            FROM cfurl_cache_response r
            JOIN cfurl_cache_receiver_data d ON r.entry_ID = d.entry_ID
            WHERE r.request_key LIKE '%amp-api.music.apple.com/v1/catalog/%/songs%'
              AND r.request_key LIKE '%include=syllable-lyrics%'
            ORDER BY r.time_stamp DESC
            LIMIT 100
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let searchName = normalize(name)
        let searchArtist = normalize(artist)

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard sqlite3_column_text(stmt, 0) != nil else { continue }
            let isDataOnFS = sqlite3_column_int(stmt, 1) == 1

            guard let data = readData(from: stmt, column: 2, isDataOnFS: isDataOnFS)
            else { continue }

            if let song = parseSongJSON(data) {
                let songName = normalize(song.name)
                let songArtist = normalize(song.artist)

                // 双向包含匹配（处理括号、feat. 等变体）
                if (songName.contains(searchName) || searchName.contains(songName))
                    && (songArtist.contains(searchArtist) || searchArtist.contains(searchArtist))
                {
                    if let ttml = song.ttml {
                        return parseTTML(ttml)
                    }
                    if let staticText = song.staticLyrics {
                        return parseStaticLyrics(text: staticText, songDuration: 0)
                    }
                }
            }
        }
        return nil
    }

    // 不做 include 过滤，兜底搜索静态歌词（纯文本，无时间戳）
    private func searchStaticLyrics(name: String, artist: String, songDuration: Double, db: OpaquePointer) -> [LyricsLine]? {
        let query = """
            SELECT r.request_key, d.isDataOnFS, d.receiver_data
            FROM cfurl_cache_response r
            JOIN cfurl_cache_receiver_data d ON r.entry_ID = d.entry_ID
            WHERE r.request_key LIKE '%amp-api.music.apple.com/v1/catalog/%/songs%'
            ORDER BY r.time_stamp DESC
            LIMIT 200
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let searchName = normalize(name)
        let searchArtist = normalize(artist)

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard sqlite3_column_text(stmt, 0) != nil else { continue }
            let isDataOnFS = sqlite3_column_int(stmt, 1) == 1

            guard let data = readData(from: stmt, column: 2, isDataOnFS: isDataOnFS)
            else { continue }

            if let song = parseSongJSON(data) {
                let songName = normalize(song.name)
                let songArtist = normalize(song.artist)

                if (songName.contains(searchName) || searchName.contains(songName))
                    && (songArtist.contains(searchArtist) || searchArtist.contains(searchArtist))
                {
                    if let text = song.staticLyrics {
                        return parseStaticLyrics(text: text, songDuration: songDuration)
                    }
                }
            }
        }
        return nil
    }

    // 通过歌曲 ID 精确查询 TTML（URL 模式匹配 /songs/{songId}）
    private func fetchRawTTML(songId: String) -> String? {
        guard let db else { return nil }

        let pattern = "%/songs/\(songId)?%"

        let query = """
            SELECT r.request_key, d.isDataOnFS, d.receiver_data
            FROM cfurl_cache_response r
            JOIN cfurl_cache_receiver_data d ON r.entry_ID = d.entry_ID
            WHERE r.request_key LIKE ?
            ORDER BY r.time_stamp DESC
            LIMIT 1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let data = readData(from: stmt, column: 2,
                                  isDataOnFS: sqlite3_column_int(stmt, 1) == 1)
        else { return nil }

        // 从 JSON 嵌套结构中提取 ttmlLocalizations 字段
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let firstSong = dataArray.first,
              let relationships = firstSong["relationships"] as? [String: Any],
              let syllableLyrics = relationships["syllable-lyrics"] as? [String: Any],
              let lyricsData = syllableLyrics["data"] as? [[String: Any]],
              let firstLyric = lyricsData.first,
              let attrs = firstLyric["attributes"] as? [String: Any],
              let ttml = attrs["ttmlLocalizations"] as? String
        else { return nil }

        return ttml
    }

    // MARK: - Data Helpers

    // 读取缓存数据：isDataOnFS=1 时数据在 fsCachedData/{UUID} 文件里
    private func readData(from stmt: OpaquePointer?, column: Int32, isDataOnFS: Bool) -> Data? {
        if isDataOnFS {
            guard let text = sqlite3_column_text(stmt, column) else { return nil }
            let uuid = String(cString: text)
            let dir = (cachePath as NSString).deletingLastPathComponent
            return FileManager.default.contents(atPath: dir + "/fsCachedData/" + uuid)
        } else {
            guard let blob = sqlite3_column_blob(stmt, column) else { return nil }
            return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, column)))
        }
    }

    // 解析 Song JSON，提取名称、歌手、TTML、静态歌词
    private func parseSongJSON(_ data: Data) -> (name: String, artist: String, ttml: String?, staticLyrics: String?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let first = dataArray.first,
              let attrs = first["attributes"] as? [String: Any]
        else { return nil }

        let name = attrs["name"] as? String ?? ""
        let artist = attrs["artistName"] as? String ?? ""

        var ttml: String?
        if let rels = first["relationships"] as? [String: Any],
           let sl = rels["syllable-lyrics"] as? [String: Any],
           let ld = sl["data"] as? [[String: Any]],
           let fl = ld.first,
           let la = fl["attributes"] as? [String: Any] {
            ttml = la["ttmlLocalizations"] as? String
        }

        var staticLyrics: String?
        if let standard = attrs["lyrics"] as? String, !standard.isEmpty {
            staticLyrics = standard
        } else if let rels = first["relationships"] as? [String: Any],
                  let standardLyrics = rels["lyrics"] as? [String: Any],
                  let ld = standardLyrics["data"] as? [[String: Any]],
                  let fl = ld.first,
                  let la = fl["attributes"] as? [String: Any],
                  let text = la["text"] as? String, !text.isEmpty {
            staticLyrics = text
        }

        return (name, artist, ttml, staticLyrics)
    }

    // MARK: - Static Lyrics Parsing

    // 将纯文本按行分割，按歌曲时长均匀分配每行的起止时间
    private func parseStaticLyrics(text: String, songDuration: Double) -> [LyricsLine] {
        var lines: [LyricsLine] = []
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let lineCount = rawLines.count
        guard lineCount > 0 else { return [] }
        let duration = songDuration > 0 ? songDuration / Double(lineCount) : 4.0

        for (i, lineText) in rawLines.enumerated() {
            let start = Double(i) * duration
            let end = start + duration
            lines.append(LyricsLine(
                startTime: start, endTime: end,
                text: lineText, words: []))
        }

        return lines
    }

    // MARK: - TTML Parsing

    // 解析 TTML XML，提取 <p> 标签的行级数据和 <span> 字级数据
    private func parseTTML(_ ttml: String) -> [LyricsLine] {
        var lines: [LyricsLine] = []

        let pattern = #"<p\s+[^>]*begin="([^"]+)"\s+end="([^"]+)"[^>]*>(.+?)</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                    options: [.dotMatchesLineSeparators])
        else { return lines }

        let nsRange = NSRange(ttml.startIndex..., in: ttml)
        let matches = regex.matches(in: ttml, options: [], range: nsRange)

        for match in matches where match.numberOfRanges == 4 {
            let begin = String(ttml[Range(match.range(at: 1), in: ttml)!])
            let end = String(ttml[Range(match.range(at: 2), in: ttml)!])
            let content = String(ttml[Range(match.range(at: 3), in: ttml)!])
            guard let startTime = parseTime(begin),
                  let endTime = parseTime(end) else { continue }

            let text = extractText(from: content)
            let words = extractWords(from: content)
            if !text.isEmpty {
                lines.append(LyricsLine(
                    startTime: startTime, endTime: endTime,
                    text: text, words: words))
            }
        }

        return lines
    }

    // 从 <p> 标签内容中提取 <span> 级别的字级时间戳
    private func extractWords(from content: String) -> [LyricWord] {
        var words: [LyricWord] = []
        let pattern = #"<span\s+[^>]*begin="([^"]+)"\s+end="([^"]+)"[^>]*>(.*?)</span>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                    options: [.dotMatchesLineSeparators])
        else { return words }

        let nsRange = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: nsRange)

        for match in matches where match.numberOfRanges == 4 {
            let begin = String(content[Range(match.range(at: 1), in: content)!])
            let end = String(content[Range(match.range(at: 2), in: content)!])
            let wordText = String(content[Range(match.range(at: 3), in: content)!])
            guard let ws = parseTime(begin), let we = parseTime(end) else { continue }
            let cleaned = wordText
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty {
                words.append(LyricWord(startTime: ws, endTime: we, text: cleaned))
            }
        }
        return words
    }

    // 解析 TTML 时间格式（支持秒数、mm:ss、hh:mm:ss 三种格式）
    private func parseTime(_ s: String) -> TimeInterval? {
        if let sec = TimeInterval(s) { return sec }
        let parts = s.split(separator: ":")
        if parts.count == 3,
           let h = Double(parts[0]),
           let m = Double(parts[1]),
           let sec = Double(parts[2]) {
            return h * 3600 + m * 60 + sec
        }
        if parts.count == 2,
           let m = Double(parts[0]),
           let sec = Double(parts[1]) {
            return m * 60 + sec
        }
        return nil
    }

    // 从 TTML 片段中提取纯文本（去掉所有 XML 标签）
    private func extractText(from content: String) -> String {
        var text = content
        text = text.replacingOccurrences(of: "<span[^>]*>", with: "",
                                          options: .regularExpression)
        text = text.replacingOccurrences(of: "</span>", with: "")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "",
                                          options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\\s+", with: " ",
                                          options: .regularExpression)
        return text
    }

    // MARK: - Helpers

    // 标准化歌名/歌手：小写、去括号内容、去空格
    private func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\(.*?\)"#, with: "",
                                   options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
