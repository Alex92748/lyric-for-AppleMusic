import Foundation
import QuartzCore

// 桌面歌词的核心状态管理器，负责：
// 1. 通过 AppleScript 获取当前播放曲目和位置
// 2. 从 Apple Music 缓存读取歌词（TTML / 静态）
// 3. 用硬件时钟（CACurrentMediaTime）在两次桥接校准之间平滑推进进度
// 4. 计算行级和字级的播放进度
@MainActor
final class LyricsViewModel: ObservableObject {
    @Published var lines: [LyricsLine] = []           // 当前曲目的所有歌词行
    @Published var currentLineIndex: Int?              // 当前唱到第几行
    @Published var currentLineProgress: Double = 0     // 当前行内的均匀时间进度 0→1
    @Published var currentWordIndex: Int?              // 当前唱到行内的第几个词（span）
    @Published var currentWordProgress: Double = 0     // 当前词内的进度 0→1
    @Published var trackName = ""
    @Published var trackArtist = ""
    @Published var isPlaying = false
    @Published var idleText = "Open Apple Music and play a song"

    nonisolated(unsafe) private let bridge = MusicBridge()!

    private var previousTrackId = ""
    private weak var trackTimer: Timer?
    private weak var progressTimer: Timer?      // 60fps 硬件时钟插值

    // 校准状态：每次桥接读数记录时间戳，用于 60fps 插值
    private var calibrationTime: CFTimeInterval = 0
    private var pausedPosition: Double = -1
    private var syncPosition: Double = -1       // 上次桥接获取的播放位置

    func startMonitoring() {
        idleText = "Open Apple Music and play a song"
        pollTrack()
        trackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollTrack() }
        }
        calibrate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1/60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickProgress() }
        }
    }

    func stopMonitoring() {
        trackTimer?.invalidate()
        progressTimer?.invalidate()
    }

    // MARK: - Track detection

    private func pollTrack() {
        if let track = bridge.getCurrentTrack() {
            if !isPlaying {
                isPlaying = true
                calibrate()
            }
            if track.id != previousTrackId {
                previousTrackId = track.id
                trackName = track.name
                trackArtist = track.artist
                loadLyrics(for: track)
            }
        } else {
            isPlaying = false
            if previousTrackId != "" {
                previousTrackId = ""
                lines = []; currentLineIndex = nil; currentLineProgress = 0; currentWordIndex = nil; currentWordProgress = 0
                trackName = ""; trackArtist = ""
            }
        }
    }

    private func loadLyrics(for track: TrackInfo) {
        Task { @MainActor in
            let result = await Self.fetchLyricsFromCache(track: track)
            lines = result
            currentLineIndex = nil
            currentLineProgress = 0
            currentWordIndex = nil
            currentWordProgress = 0
            calibrationTime = 0
            syncPosition = -1
        }
    }

    private nonisolated static func fetchLyricsFromCache(track: TrackInfo) async -> [LyricsLine] {
        let cache = LyricsCache()
        guard cache.open() else { return [] }
        defer { cache.close() }

        if let parsed = cache.fetchLyrics(
            storeId: track.id, name: track.name, artist: track.artist, songDuration: track.duration
        ) {
            return parsed
        }

        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let parsed = cache.fetchLyrics(
                storeId: track.id, name: track.name, artist: track.artist, songDuration: track.duration
            ) {
                return parsed
            }
        }
        return []
    }

    // MARK: - Bridge calibration

    private func calibrate() {
        guard isPlaying else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pos = self?.bridge.getPlayerPosition() ?? -1
            DispatchQueue.main.async { [weak self] in
                if pos >= 0 {
                    self?.onCalibration(position: pos)
                } else {
                    self?.scheduleNextCalibrate()
                }
            }
        }
    }

    // 自调度校准：每次 onCalibration 完成后等 100ms 再执行下一次
    private func scheduleNextCalibrate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.calibrate()
        }
    }
    private func onCalibration(position: Double) {
        if position == pausedPosition { scheduleNextCalibrate(); return }
        pausedPosition = position

        guard !lines.isEmpty else { scheduleNextCalibrate(); return }

        var idx: Int?
        for i in 0..<lines.count {
            if lines[i].startTime <= position && position < lines[i].endTime {
                idx = i
            }
        }

        guard let idx else { scheduleNextCalibrate(); return }

        if currentLineIndex != idx {
            currentLineIndex = idx
            currentWordIndex = nil
            currentWordProgress = 0
        }
        let line = lines[idx]

        if line.words.isEmpty {
            currentLineProgress = 1.0
            currentWordIndex = nil
            currentWordProgress = 0
        } else {
            syncPosition = position
            calibrationTime = CACurrentMediaTime()
            let dur = line.endTime - line.startTime
            currentLineProgress = dur > 0 ? min(max((position - line.startTime) / dur, 0), 1) : 0
            updateWord(position: position, line: line)
        }
        scheduleNextCalibrate()
    }

    // 根据播放位置计算当前词索引和词内进度
    private func updateWord(position: Double, line: LyricsLine) {
        let words = line.words
        var wi = 0
        for i in 0..<words.count {
            guard words[i].startTime <= position else { break }
            wi = i
        }

        if wi < words.count, position >= words[wi].startTime {
            let w = words[wi]
            let wDur = w.endTime - w.startTime
            currentWordProgress = wDur > 0 ? min(max((position - w.startTime) / wDur, 0), 1) : 1
            if currentWordIndex != wi {
                currentWordIndex = wi
            }
        } else {
            currentWordIndex = nil
            currentWordProgress = 0
        }
    }

    // MARK: - Hardware clock progress (60fps)

    // 60fps 硬件时钟插值：在上次校准位置基础上加上系统时间流逝
    private func tickProgress() {
        guard isPlaying, let idx = currentLineIndex, idx < lines.count, syncPosition >= 0 else { return }
        let line = lines[idx]
        guard !line.words.isEmpty else { return }

        let elapsed = CACurrentMediaTime() - calibrationTime
        let pos = syncPosition + elapsed
        let dur = line.endTime - line.startTime
        currentLineProgress = dur > 0 ? min(max((pos - line.startTime) / dur, 0), 1) : 0
        updateWord(position: pos, line: line)
    }
}
