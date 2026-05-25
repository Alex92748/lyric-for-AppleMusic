import SwiftUI

// 行间距（行中心到行中心的 pt 数），所有行等距排列，用于计算 scroll offset
private let lineGap: CGFloat = 46

// 桌面悬浮歌词的主视图。渲染全部歌词行，通过 offset 滚动使当前行居中。
// 非当前行缩放 0.97 + 下移 6pt 形成视觉层次，当前行用逐字淡入 + 上浮动画。
struct LyricsDisplayView: View {
    @ObservedObject var viewModel: LyricsViewModel
    @Environment(\.colorScheme) private var colorScheme

    // 深色模式用白字，浅色模式用黑字
    private var highlightColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        ZStack {
            if viewModel.lines.isEmpty {
                idleView
            } else {
                GeometryReader { geo in
                    VStack(spacing: 8) {
                        ForEach(0..<viewModel.lines.count, id: \.self) { i in
                            let line = viewModel.lines[i]
                            let isCurrent = i == viewModel.currentLineIndex
                            lineView(line: line, isCurrent: isCurrent)
                            .scaleEffect(isCurrent ? 1.0 : 0.97)
                            .offset(y: isCurrent ? 0 : 6)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 4)
                        }
                    }
                    // scroll offset：把当前行推到面板中心，spring 动画驱动滚动
                    .offset(y: geo.size.height / 2 - lineGap / 2 - CGFloat(viewModel.currentLineIndex ?? 0) * lineGap)
                    .animation(.spring(duration: 0.55, bounce: 0.15), value: viewModel.currentLineIndex)
                }
                .frame(height: 152)
                .clipped()
            }
        }
        .frame(height: 152)
        .clipped()
        // 上下边缘渐变遮罩，让远离当前行的歌词淡出
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.3),
                    .init(color: .white, location: 0.7),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // 渲染单行歌词。当前行且有字级数据时拆成逐字 HStack，否则降级为单 Text。
    private func lineView(line: LyricsLine, isCurrent: Bool) -> some View {
        Text(line.text)
            .font(.system(size: 26, weight: .bold))
            .foregroundColor(highlightColor)
            .opacity(isCurrent && line.words.isEmpty ? 1.0 : 0.4)
            .overlay(
                Text(line.text)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(highlightColor)
                    .mask {
                        GeometryReader { g in
                            let fullW = g.size.width
                            if isCurrent, !line.words.isEmpty {
                                let stops = gradientStops(line: line, totalWidth: fullW)
                                LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
                            } else {
                                Color.clear
                            }
                        }
                    }
            )
    }

    // 按字级时间戳和字符数估算每个词的边界，生成渐变 stops
    private func gradientStops(line: LyricsLine, totalWidth: CGFloat) -> [Gradient.Stop] {
        let words = line.words
        let totalChars = words.reduce(0) { $0 + $1.text.count }
        guard totalChars > 0 else { return [] }

        let cwi = viewModel.currentWordIndex ?? -1
        let wp = CGFloat(viewModel.currentWordProgress)
        let t: CGFloat = 0.08

        var stops: [Gradient.Stop] = []
        var accumulated: CGFloat = 0

        for (i, word) in words.enumerated() {
            let frac = CGFloat(word.text.count) / CGFloat(totalChars)

            if i < cwi {
                // 已唱完的词：全白
                stops.append(.init(color: highlightColor, location: accumulated))
                stops.append(.init(color: highlightColor, location: accumulated + frac))
            } else if i == cwi {
                // 当前词：从 accumulated 到 sweep 白色，过渡带到 sweep + t
                let sweep = accumulated + frac * wp
                stops.append(.init(color: highlightColor, location: accumulated))
                stops.append(.init(color: highlightColor, location: max(accumulated, sweep)))
                stops.append(.init(color: .clear, location: min(1, sweep + t)))
                stops.append(.init(color: .clear, location: 1))
                return stops
            } else {
                // 未唱到的词：透明
                stops.append(.init(color: .clear, location: accumulated))
                stops.append(.init(color: .clear, location: accumulated + frac))
            }

            accumulated += frac
        }

        stops.append(.init(color: highlightColor, location: 1))
        return stops
    }

    // 无歌词时的占位视图
    private var idleView: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 18))
                .foregroundColor(highlightColor.opacity(0.3))
            Text(viewModel.idleText)
                .font(.system(size: 11))
                .foregroundColor(highlightColor.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
