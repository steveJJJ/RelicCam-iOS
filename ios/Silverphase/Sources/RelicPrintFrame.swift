import Foundation
import UIKit
import SwiftUI
import ImageIO

// MARK: - 成片表现层（阶段 C16 / C19）
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
//
// C19（对齐安卓 EditExportService 的失败帧计数 + ExportVerifier 导出验真）：
//   - 逐帧渲染失败不再静默跳过：记录原因、UI 可单帧重试 / 删除；
//   - 落盘后回读校验（非空 / 可解码 / 尺寸），坏文件立即删除，展示回退无框母片；
//   - 母片纯净自检：母片一旦被写入 frame_style/date_imprint（安卓 vc114 的坑），
//     拒绝生成带框版并显式报错，绝不把档位烤回母片。

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

// MARK: - 失败帧记录（C19）

/// 一帧带框失败的持久化记录。key = `<rollId>-<frameIndex>`，与成片文件名同源。
struct RelicFrameFailure: Codable, Sendable, Equatable, Identifiable {
    let key: String
    let rollId: String
    let frameIndex: Int
    let reason: String
    let revision: Int

    var id: String { key }

    init(rollId: String, frameIndex: Int, reason: String) {
        self.key = "\(rollId)-\(frameIndex)"
        self.rollId = rollId
        self.frameIndex = frameIndex
        self.reason = reason
        self.revision = RelicFrameSettings.revision
    }
}

enum RelicFrameFailures {
    private static let key = "relic_frame_failures"

    static func load() -> [RelicFrameFailure] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RelicFrameFailure].self, from: data) else { return [] }
        return list
    }

    static func replace(_ list: [RelicFrameFailure]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clearAll() { UserDefaults.standard.removeObject(forKey: key) }

    static func remove(rollId: String, frameIndex: Int) {
        let key = "\(rollId)-\(frameIndex)"
        replace(load().filter { $0.key != key })
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

/// 一次 rebuild 的产物：待渲染任务 + 母片已被污染（不能生成带框版）的帧。
private struct RelicRenderPlan: Sendable {
    let jobs: [RelicRenderJob]
    let dirty: [RelicFrameFailure]
}

enum RelicPrintRenderer {

    /// 为所有已冲洗成片补齐带框版本，并全量校验已有带框版；返回本次失败帧。
    /// 失败帧的带框文件会被删除，`RelicPaths.printURL` 自动回退无框母片——
    /// 用户看到的是原始成片而不是空白格，暗房主页同时给出「重试 / 删除」入口。
    /// 放后台线程跑，避免几十张 1.5MP 图的解码/绘制卡住主线程。
    @discardableResult
    static func rebuild(rolls: [RollRecord]) async -> [RelicFrameFailure] {
        let plan = jobs(for: rolls)
        let style = RelicFrameSettings.style
        let dateOn = RelicFrameSettings.dateOn

        // 已存在的带框版做元数据级验真（不解码整图，几十张也在毫秒级）。
        // 坏文件直接删掉，让它进入本轮重渲。
        var failures = plan.dirty
        var toRetry: [RelicRenderJob] = []
        for job in plan.jobs {
            let url = URL(fileURLWithPath: job.outPath)
            if FileManager.default.fileExists(atPath: job.outPath),
               let reason = verifyFramed(at: url, decoding: false) {
                try? FileManager.default.removeItem(at: url)
                RelicDarkroomLog.write("FRAME INVALID \(job.name): \(reason)")
                if RelicFrameSettings.style == style && RelicFrameSettings.dateOn == dateOn {
                    failures.append(RelicFrameFailure(rollId: job.meta.rollId,
                                                      frameIndex: job.meta.frameIndex,
                                                      reason: "导出校验失败：\(reason)"))
                }
            }
            if !FileManager.default.fileExists(atPath: job.outPath) { toRetry.append(job) }
        }
        let jobs = toRetry

        if !jobs.isEmpty {
            let fresh = await Task.detached(priority: .utility) { () -> [RelicFrameFailure] in
                var out: [RelicFrameFailure] = []
                for job in jobs {
                    if let reason = autoreleasepool(invoking: { render(job: job) }) {
                        out.append(RelicFrameFailure(rollId: job.meta.rollId,
                                                     frameIndex: job.meta.frameIndex,
                                                     reason: reason))
                    }
                }
                return out
            }.value
            failures += fresh
        }

        // 仅保留当前 revision 的失败：切档后旧失败已随 invalidateAll 清空。
        let current = RelicFrameSettings.revision
        let result = failures.filter { $0.revision == current }
        RelicFrameFailures.replace(result)
        return result
    }

    /// 清掉所有带框成片与失败记录；下次 rebuild 会按当前设置全部重生成。
    static func invalidateAll() {
        try? FileManager.default.removeItem(at: RelicPaths.framedDirectory())
        RelicFrameFailures.clearAll()
    }

    /// 单帧重试（对齐安卓 EditActivity 的失败帧重试）：强制重渲一帧。
    /// 主线程构造 job（StockCatalog 不是 Sendable），后台渲染，返回失败原因（nil=成功）。
    @discardableResult
    static func retryOne(roll: RollRecord, frameIndex: Int) async -> String? {
        guard let job = job(roll: roll, frameIndex: frameIndex) else {
            return "找不到该帧的母片"
        }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: job.outPath))
        let reason = await Task.detached(priority: .utility) {
            autoreleasepool { render(job: job) }
        }.value
        if reason == nil {
            RelicFrameFailures.remove(rollId: roll.rollId, frameIndex: frameIndex)
        } else if let reason {
            RelicFrameFailures.replace(RelicFrameFailures.load().filter {
                $0.key != "\(roll.rollId)-\(frameIndex)"
            } + [RelicFrameFailure(rollId: roll.rollId, frameIndex: frameIndex, reason: reason)])
        }
        return reason
    }

    /// 单帧删除：母片 / 备份 / 带框版三处一起删，清掉「已存入相册」与失败标记。
    /// 系统相册里已存的那份保持不动（和看图页长按删除口径一致）。
    static func discard(rollId: String, frameIndex: Int) {
        let name = "relic-\(rollId)-\(frameIndex).jpg"
        for dir in [RelicPaths.framedDirectory(), RelicPaths.developedDirectory(),
                    RelicPaths.printsBackupDirectory()] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        RelicSavedPrints.remove(rollId: rollId, frameIndex: frameIndex)
        RelicFrameFailures.remove(rollId: rollId, frameIndex: frameIndex)
        RelicDarkroomLog.write("DISCARD \(name)")
    }

    // MARK: 任务构造（主线程：StockCatalog 不是 Sendable，不能进 detached 闭包）

    private static func jobs(for rolls: [RollRecord]) -> RelicRenderPlan {
        let fm = FileManager.default
        let style = RelicFrameSettings.style
        let dateOn = RelicFrameSettings.dateOn
        var jobs: [RelicRenderJob] = []
        var dirty: [RelicFrameFailure] = []
        for roll in rolls where roll.status != RollContract.statusShooting &&
                                roll.status != RollContract.statusDeveloping {
            let display = StockCatalog.shared.stock(roll.filmStockId)?.name ?? roll.filmStockId
            for frame in roll.frames {
                let name = "relic-\(roll.rollId)-\(frame.index).jpg"
                guard let master = RelicPaths.masterPrintURL(name: name) else { continue }
                // 母片纯净契约（C19 / 安卓 vc114 MotherPurityContractTest）：
                // 母片一旦带 frame_style / date_imprint，说明档位被烤进母片——
                // 拒绝生成带框版，避免二次套框，并把原因报给用户。
                if let impurity = auditMother(path: master.path) {
                    dirty.append(RelicFrameFailure(rollId: roll.rollId,
                                                   frameIndex: frame.index,
                                                   reason: impurity))
                    continue
                }
                let out = RelicPaths.framedDirectory().appendingPathComponent(name)
                if fm.fileExists(atPath: out.path) {
                    // 已有带框版也要加入计划：rebuild 里会做元数据验真。
                    guard let meta = meta(roll: roll, frame: frame, display: display) else { continue }
                    jobs.append(RelicRenderJob(name: name, masterPath: master.path,
                                               outPath: out.path, meta: meta,
                                               style: style, dateOn: dateOn))
                    continue
                }
                guard let meta = meta(roll: roll, frame: frame, display: display) else { continue }
                jobs.append(RelicRenderJob(name: name, masterPath: master.path,
                                           outPath: out.path, meta: meta,
                                           style: style, dateOn: dateOn))
            }
        }
        return RelicRenderPlan(jobs: jobs, dirty: dirty)
    }

    private static func job(roll: RollRecord, frameIndex: Int) -> RelicRenderJob? {
        guard let frame = roll.frames.first(where: { $0.index == frameIndex }) else { return nil }
        let name = "relic-\(roll.rollId)-\(frame.index).jpg"
        guard let master = RelicPaths.masterPrintURL(name: name) else { return nil }
        let display = StockCatalog.shared.stock(roll.filmStockId)?.name ?? roll.filmStockId
        guard let meta = meta(roll: roll, frame: frame, display: display) else { return nil }
        return RelicRenderJob(name: name, masterPath: master.path,
                              outPath: RelicPaths.framedDirectory()
                                  .appendingPathComponent(name).path,
                              meta: meta, style: RelicFrameSettings.style,
                              dateOn: RelicFrameSettings.dateOn)
    }

    private static func meta(roll: RollRecord, frame: FrameRecord,
                             display: String) -> RelicPrintMeta? {
        RelicPrintMeta(rollId: roll.rollId, frameIndex: frame.index,
                       takenAtMs: frame.takenAtMs, iso: frame.iso,
                       filmDisplayName: display, filmStockId: roll.filmStockId,
                       printStockId: roll.printStockId)
    }

    /// 母片纯净自检：只查元数据，不解码像素。返回 nil=干净；非 nil=污染原因。
    static func auditMother(path: String) -> String? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil // 读不了由 render 阶段报错，这里不误判
        }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let comment = exif?[kCGImagePropertyExifUserComment as String] as? String ?? ""
        let desc = tiff?["ImageDescription"] as? String ?? ""
        if comment.contains("frame_style") || comment.contains("date_imprint") ||
           desc.contains("frame_style") {
            return "母片被相框档位污染，拒绝二次套框"
        }
        return nil
    }

    // MARK: 渲染（后台线程）

    /// 返回 nil=成功；非 nil=失败原因（会进失败列表、UI 可重试/删除）。
    private static func render(job: RelicRenderJob) -> String? {
        // 连续切档时旧任务可能还在跑：开头就放弃，省掉无用的解码/绘制。
        guard RelicFrameSettings.style == job.style,
              RelicFrameSettings.dateOn == job.dateOn else { return nil }
        guard let src = UIImage(contentsOfFile: job.masterPath) else { return "母片无法解码" }
        if let impurity = auditMother(path: job.masterPath) { return impurity }

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

        guard let jpeg = rendered.jpegData(compressionQuality: 0.95) else { return "JPEG 编码失败" }
        // 写盘前再查一次：防止慢一步的旧档位任务覆盖新档位的结果。
        guard RelicFrameSettings.style == job.style,
              RelicFrameSettings.dateOn == job.dateOn else { return nil }
        let url = URL(fileURLWithPath: job.outPath)
        guard writeWithExif(jpeg: jpeg, to: url, meta: job.meta,
                            size: outSize, style: job.style, dateOn: job.dateOn) else {
            return "带框成片写盘失败"
        }
        // C19 导出验真：落盘后立即回读，解码失败 / 空文件 / 尺寸异常一律视为失败，
        // 删掉半成品 → 展示层回退无框母片，不会留空白格。
        if let reason = verifyFramed(at: url, decoding: true) {
            try? FileManager.default.removeItem(at: url)
            return "导出校验失败：\(reason)"
        }
        return nil
    }

    /// 导出验真：对齐安卓 ExportVerifier 的「可解码 / 尺寸 / 非空」三项。
    /// decoding=false 用于 rebuild 时已有文件的元数据级快检（不解码整图）。
    private static func verifyFramed(at url: URL, decoding: Bool) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return "文件不存在" }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 4096 else { return "文件为空" }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "无法打开" }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int, w > 0,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int, h > 0 else {
            return "尺寸异常"
        }
        if decoding, CGImageSourceCreateImageAtIndex(source, 0, nil) == nil {
            return "无法解码"
        }
        return nil
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

        // ImageDescription 在 ImageIO 里没有独立的顶层常量；放 TIFF 字典里。
        // 用字面量键：ImageIO 对未知 key 直接忽略，不会因 SDK 差异编译失败。
        let tiff: [String: Any] = [
            kCGImagePropertyTIFFMake as String: "CONTAX",
            kCGImagePropertyTIFFModel as String: "T3",
            kCGImagePropertyTIFFSoftware as String: "Relic Cam + SpektraLab Engine",
            "ImageDescription": "film=\(meta.filmStockId) print=\(meta.printStockId)",
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
        ]

        CGImageDestinationAddImageFromSource(dest, source, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return false }
        return buffer.write(to: url, atomically: true)
    }
}

// MARK: - 暗房里的成片相框设置卡

struct RelicFrameSettingsCard: View {
    /// 同步闭包：父视图自己起 Task 重建数据并直接进成片大图页，避免把非 Sendable
    /// 的 async 闭包捕获进 @Sendable 的 Task 初始化器（Swift 6 strict concurrency）。
    let onChange: () -> Void

    @State private var style: RelicFrameStyle = RelicFrameSettings.style
    @State private var dateOn: Bool = RelicFrameSettings.dateOn

    // T3 机身的黄铜/暖白色，和暗房配色统一；不用系统 Picker/Toggle 的蓝绿控件。
    private let brass = Color(red: 0.95, green: 0.84, blue: 0.45)

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Text("相框")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                ForEach(RelicFrameStyle.allCases, id: \.rawValue) { s in
                    Button {
                        guard style != s else { return }
                        style = s
                        apply(style: s, date: dateOn)
                    } label: {
                        Text(s.label)
                            .font(.system(size: 12, weight: style == s ? .bold : .regular))
                            .foregroundColor(style == s
                                ? Color(red: 0.12, green: 0.07, blue: 0.06)
                                : .white.opacity(0.65))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(style == s ? brass : Color.white.opacity(0.07))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                Button {
                    dateOn.toggle()
                    apply(style: style, date: dateOn)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: dateOn ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                        Text("日期戳")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(dateOn ? brass : .white.opacity(0.55))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private func apply(style s: RelicFrameStyle, date d: Bool) {
        RelicFrameSettings.style = s
        RelicFrameSettings.dateOn = d
        RelicFrameSettings.bumpRevision()
        RelicPrintRenderer.invalidateAll() // 同时清掉旧失败记录，切档后全部重新验真
        // 不再原地转进度圈：父视图重建完数据后直接进成片大图页看新效果。
        onChange()
    }
}

// MARK: - 失败帧卡片（C19，对齐安卓 EditActivity 的失败帧计数 + 重试/删除）

/// 只在有失败帧时出现。紧凑暗红底 + 黄铜按钮，与暗房 T3 风格统一；
/// 不堆说明文字、不用系统 Segmented/Toggle（C17 用户反馈）。
struct RelicFrameFailureCard: View {
    let failures: [RelicFrameFailure]
    let rolls: [RollRecord]
    let onRetry: (RelicFrameFailure) -> Void
    let onDelete: (RelicFrameFailure) -> Void
    let onRetryAll: () -> Void

    private let brass = Color(red: 0.95, green: 0.84, blue: 0.45)

    private func name(of rollId: String) -> String {
        guard let roll = rolls.first(where: { $0.rollId == rollId }) else { return rollId }
        return StockCatalog.shared.stock(roll.filmStockId)?.name ?? roll.filmStockId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 1.0, green: 0.62, blue: 0.45))
                Text("成片异常 · \(failures.count) 张")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.77))
                Spacer()
                Button("全部重试") { onRetryAll() }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(brass)
                    .buttonStyle(.plain)
            }
            ForEach(failures) { f in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("第 \(f.frameIndex + 1) 张 · \(name(of: f.rollId))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Text(f.reason)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 5) {
                        Button("重试") { onRetry(f) }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(brass)
                            .buttonStyle(.plain)
                        Button("删除") { onDelete(f) }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.red.opacity(0.85))
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(red: 0.16, green: 0.055, blue: 0.055))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(Color(red: 1.0, green: 0.62, blue: 0.45).opacity(0.2), lineWidth: 0.5))
        )
    }
}
