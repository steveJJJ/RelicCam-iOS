import Foundation
import UIKit
import SwiftUI
import ImageIO

// MARK: - 成片表现层（阶段 C16）
//
// 对齐安卓 develop 包：
//   WhiteBorderRenderer.kt       四边绝对等宽 = 短边 × 6%，暖白 #F7F5F0，无描边/阴影
//   EditActivity.drawFilmEdgePreview  片边回落：深片基 + 上下齿孔条 + 画幅内母片
//   ContaxExif.kt                CONTAX T3 模拟 EXIF + 胶卷/冲洗元数据
//
// 与安卓的差别（刻意的）：安卓的片边/日期由引擎 overscan_*/date_imprint_* 在渲染期
// 合成，切档要重渲一次（1~4s/帧）。iOS 这边统一收敛到「母片 → 带框成片」的 2D
// 后处理层：母片永远保持引擎导出的无框原样，切档/开关日期只需重跑本文件，
// 不碰引擎、不重渲、不增加冲洗内存压力（13 mini 上是硬约束）；已有成片也能立刻改。
// 预览与存相册读的是同一份 Framed 文件，天然一致，不会出现安卓早期「预览和成片
// 对不上」的问题。

/// 三档，数值对齐安卓 EditsCodec：0=无框 / 1=片边 / 2=白边（默认白边）。
enum RelicFrameStyle: Int, CaseIterable, Sendable {
    case none = 0
    case film = 1
    case white = 2

    var label: String {
        switch self {
        case .none: return "无框"
        case .film: return "片边"
        case .white: return "白边"
        }
    }
}

/// 全局成片设置（UserDefaults 持久化，对齐安卓 EditsStore 的整卷同款）。
enum RelicFrameSettings {
    private static let styleKey = "relic_frame_style"
    private static let dateKey = "relic_date_on"
    private static let revKey = "relic_frame_revision"

    static var style: RelicFrameStyle {
        get { RelicFrameStyle(rawValue: UserDefaults.standard.integer(forKey: styleKey)) ?? .white }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
    }

    /// 默认关，对齐安卓 FrameEdit 的 dateOn=false。
    static var dateOn: Bool {
        get { UserDefaults.standard.bool(forKey: dateKey) }
        set { UserDefaults.standard.set(newValue, forKey: dateKey) }
    }

    /// 每次改设置 +1：让成片墙 ForEach 的 identity 变化，强制缩略图重新解码。
    static var revision: Int { UserDefaults.standard.integer(forKey: revKey) }
    static func bumpRevision() {
        UserDefaults.standard.set(revision + 1, forKey: revKey)
    }
}

struct RelicPrintMeta: Sendable {
    let rollId: String
    let frameIndex: Int
    let takenAtMs: Int64
    let iso: Int?
    let filmDisplayName: String
    let filmStockId: String
    let printStockId: String
}

private struct RelicRenderJob: Sendable {
    let name: String
    let masterPath: String
    let outPath: String
    let meta: RelicPrintMeta
    let style: RelicFrameStyle
    let dateOn: Bool
}

enum RelicPrintRenderer {

    /// 为所有已冲洗成片补齐带框版本。只处理缺失文件；改档时先 invalidateAll()。
    /// 放后台线程跑，避免几十张 1.5MP 图的解码/绘制卡住主线程。
    static func rebuild(rolls: [RollRecord]) async {
        let jobs = jobs(for: rolls)
        guard !jobs.isEmpty else { return }
        let task = Task.detached(priority: .utility) {
            for job in jobs {
                autoreleasepool { _ = render(job: job) }
            }
        }
        await task.value
    }

    /// 清掉所有带框成片；下次 rebuild 会按当前设置全部重生成。
    static func invalidateAll() {
        try? FileManager.default.removeItem(at: RelicPaths.framedDirectory())
    }

    // MARK: 任务构造（主线程：StockCatalog 不是 Sendable，不能进 detached 闭包）

    private static func jobs(for rolls: [RollRecord]) -> [RelicRenderJob] {
        let fm = FileManager.default
        let style = RelicFrameSettings.style
        let dateOn = RelicFrameSettings.dateOn
        var jobs: [RelicRenderJob] = []
        for roll in rolls where roll.status != RollContract.statusShooting &&
                                roll.status != RollContract.statusDeveloping {
            let display = StockCatalog.shared.stock(roll.filmStockId)?.name ?? roll.filmStockId
            for frame in roll.frames {
                let name = "relic-\(roll.rollId)-\(frame.index).jpg"
                guard let master = RelicPaths.masterPrintURL(name: name) else { continue }
                let out = RelicPaths.framedDirectory().appendingPathComponent(name)
                if fm.fileExists(atPath: out.path) { continue }
                let meta = RelicPrintMeta(
                    rollId: roll.rollId,
                    frameIndex: frame.index,
                    takenAtMs: frame.takenAtMs,
                    iso: frame.iso,
                    filmDisplayName: display,
                    filmStockId: roll.filmStockId,
                    printStockId: roll.printStockId
                )
                jobs.append(RelicRenderJob(name: name,
                                           masterPath: master.path,
                                           outPath: out.path,
                                           meta: meta,
                                           style: style,
                                           dateOn: dateOn))
            }
        }
        return jobs
    }

    // MARK: 渲染（后台线程）

    private static func render(job: RelicRenderJob) -> Bool {
        // 连续切档时旧任务可能还在跑：开头就放弃，省掉无用的解码/绘制。
        guard RelicFrameSettings.style == job.style,
              RelicFrameSettings.dateOn == job.dateOn else { return false }
        guard let src = UIImage(contentsOfFile: job.masterPath) else { return false }

        // 老卷可能是 6MP 母片；先降到 2400 长边再画，避免外扩画布后内存翻倍。
        var image = src
        let maxSide = max(src.size.width, src.size.height)
        if maxSide > 2400 {
            let scale = 2400 / maxSide
            let sz = CGSize(width: src.size.width * scale, height: src.size.height * scale)
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
            image = UIGraphicsImageRenderer(size: sz, format: f).image { _ in
                src.draw(in: CGRect(origin: .zero, size: sz))
            }
        }

        let w = image.size.width, h = image.size.height
        let margin: CGFloat
        switch job.style {
        case .none:  margin = 0
        case .white: margin = max(1, (min(w, h) * 0.06).rounded())
        case .film:  margin = max(6, (w * 0.055).rounded())
        }
        let outSize = CGSize(width: w + margin * 2, height: h + margin * 2)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true

        let rendered = UIGraphicsImageRenderer(size: outSize, format: format).image { _ in
            switch job.style {
            case .none:
                UIColor.black.setFill()
                UIRectFill(CGRect(origin: .zero, size: outSize))
            case .white:
                // #F7F5F0 暖白相纸，绝对等宽，不描边、不投影、日期不写到白边。
                UIColor(red: 0.969, green: 0.961, blue: 0.941, alpha: 1).setFill()
                UIRectFill(CGRect(origin: .zero, size: outSize))
            case .film:
                // 深片基 #12100E + 上下米白齿孔条（安卓 drawFilmEdgePreview 口径）。
                UIColor(red: 0.071, green: 0.063, blue: 0.055, alpha: 1).setFill()
                UIRectFill(CGRect(origin: .zero, size: outSize))
                let holeW = max(4, (w * 0.032).rounded())
                let holeH = max(2, (margin * 0.5).rounded())
                UIColor(red: 0.894, green: 0.875, blue: 0.831, alpha: 1).setFill()
                var x = margin
                while x < outSize.width - holeW {
                    UIRectFill(CGRect(x: x, y: (margin - holeH) / 2,
                                      width: holeW, height: holeH))
                    UIRectFill(CGRect(x: x, y: outSize.height - (margin + holeH) / 2,
                                      width: holeW, height: holeH))
                    x += holeW * 2.4
                }
            }

            let picture = CGRect(x: margin, y: margin, width: w, height: h)
            image.draw(in: picture)
            if job.dateOn { drawDate(meta: job.meta, in: picture) }
        }

        guard let jpeg = rendered.jpegData(compressionQuality: 0.95) else { return false }
        // 写盘前再查一次：防止慢一步的旧档位任务覆盖新档位的结果。
        guard RelicFrameSettings.style == job.style,
              RelicFrameSettings.dateOn == job.dateOn else { return false }
        return writeWithExif(jpeg: jpeg,
                             to: URL(fileURLWithPath: job.outPath),
                             meta: job.meta,
                             size: outSize,
                             style: job.style,
                             dateOn: job.dateOn)
    }

    /// CONTAX T3 风格日期戳：画面内右下角、橙黄点阵感、按该帧真实拍摄时刻。
    /// 不写到白边/片边上（安卓明确口径：日期属于画面层）。
    private static func drawDate(meta: RelicPrintMeta, in rect: CGRect) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yy.MM.dd"
        let taken = Date(timeIntervalSince1970: Double(meta.takenAtMs) / 1000.0)
        let text = f.string(from: taken)

        let shortSide = min(rect.width, rect.height)
        let size = max(11, shortSide * 0.034)
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(red: 1.0, green: 0.55, blue: 0.12, alpha: 0.96),
            .kern: 1.4,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        let point = CGPoint(x: rect.maxX - sz.width - shortSide * 0.045,
                            y: rect.maxY - sz.height - shortSide * 0.035)

        // 极淡的橙色光晕，模拟机身 LED 在底片上的轻微扩散。
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.orange.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = size * 0.4
        shadow.shadowOffset = .zero
        attrs[.shadow] = shadow
        NSAttributedString(string: text, attributes: attrs).draw(at: point)
        s.draw(at: point)
    }

    // MARK: EXIF（对齐 ContaxExif.kt，全部为模拟值，无真实机型信息）

    private static func writeWithExif(jpeg: Data, to url: URL, meta: RelicPrintMeta,
                                      size: CGSize, style: RelicFrameStyle,
                                      dateOn: Bool) -> Bool {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return false }
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer, "public.jpeg" as CFString, 1, nil) else { return false }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        // 文件时间用冲洗/生成时刻，避免系统相册按拍摄时间把成片排到历史位置。
        let fileDate = f.string(from: Date())
        let taken = Date(timeIntervalSince1970: Double(meta.takenAtMs) / 1000.0)
        let takenDate = f.string(from: taken)

        let comment: [String: Any] = [
            "film": meta.filmStockId,
            "print": meta.printStockId,
            "roll": meta.rollId,
            "frame": meta.frameIndex,
            "film_name": meta.filmDisplayName,
            "orig_taken_at": meta.takenAtMs,
            "orig_taken_at_text": takenDate,
            "frame_style": style.rawValue,
            "date_imprint": dateOn,
            "engine": "Relic Cam + SpektraLab Engine",
        ]
        let commentJSON = (try? JSONSerialization.data(withJSONObject: comment, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let tiff: [String: Any] = [
            kCGImagePropertyTIFFMake as String: "CONTAX",
            kCGImagePropertyTIFFModel as String: "T3",
            kCGImagePropertyTIFFSoftware as String: "Relic Cam + SpektraLab Engine",
        ]
        var exif: [String: Any] = [
            kCGImagePropertyExifDateTimeOriginal as String: fileDate,
            kCGImagePropertyExifDateTimeDigitized as String: fileDate,
            kCGImagePropertyExifFNumber as String: 2.8,
            kCGImagePropertyExifFocalLength as String: 35.0,
            kCGImagePropertyExifUserComment as String: commentJSON,
            "LensModel": meta.filmDisplayName,
            "BodySerialNumber": meta.rollId,
        ]
        if let iso = meta.iso, iso > 0 {
            exif[kCGImagePropertyExifISOSpeedRatings as String] = [iso]
        }
        let props: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: tiff,
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyImageDescription as String:
                "film=\(meta.filmStockId) print=\(meta.printStockId)",
        ]

        CGImageDestinationAddImageFromSource(dest, source, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return false }
        return buffer.write(to: url, atomically: true)
    }
}

// MARK: - 暗房里的成片相框设置卡

struct RelicFrameSettingsCard: View {
    /// 同步闭包：父视图自己起 Task 重建数据，避免把非 Sendable 的 async 闭包
    /// 捕获进 @Sendable 的 Task 初始化器（Swift 6 strict concurrency 会报错）。
    let onChange: () -> Void

    @State private var style: RelicFrameStyle = RelicFrameSettings.style
    @State private var dateOn: Bool = RelicFrameSettings.dateOn
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "square.on.square")
                    .foregroundColor(.yellow.opacity(0.9))
                Text("成片相框")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if busy { ProgressView().tint(.yellow).scaleEffect(0.8) }
            }

            Picker("相框", selection: $style) {
                ForEach(RelicFrameStyle.allCases, id: \.rawValue) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $dateOn) {
                Text("日期戳（CONTAX T3 风格）")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.8))
            }
            .tint(.yellow)

            Text("切换后暗房内所有成片按新样式重新生成，可立即看到效果；已存入系统相册的副本不变。")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
        .onChange(of: style) { _, v in apply(style: v, date: dateOn) }
        .onChange(of: dateOn) { _, v in apply(style: style, date: v) }
    }

    private func apply(style s: RelicFrameStyle, date d: Bool) {
        RelicFrameSettings.style = s
        RelicFrameSettings.dateOn = d
        RelicFrameSettings.bumpRevision()
        RelicPrintRenderer.invalidateAll()
        busy = true
        onChange()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            busy = false
        }
    }
}
