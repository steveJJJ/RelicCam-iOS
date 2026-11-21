import SwiftUI
import UIKit
import CoreImage
import Photos

// MARK: - Relic Cam 暗房（阶段 C）
//
// 灵魂闭环的最后一环：把「未冲洗底片」交给 Silverphase 引擎真正渲染成成片。
//
// 流程（对齐安卓 DarkroomV2 / DevelopmentService）：
//   1. 列出未冲洗的卷（status = shooting），显示胶卷名 / 张数。
//   2. 点「冲洗」→ 前台逐帧渲染，展示真实进度（首帧预热提示 + EMA 预估剩余）。
//      每完成一帧写一次 checkpoint，App 被杀可续冲、不重渲。
//   3. 冲洗只出「母片」存私有目录 RelicCam/Developed —— 屏幕先看到的是未入相册的成片。
//   4. 逐张过片浏览（上一张 / 下一张），用户点「存入相册」才写系统图库。
//   5. 全部完成：shooting → developing → developed → editable。
//
// 引擎复用现成 API，不自己写渲染：
//   MobileEngine.render/canvasImage（缩略图）、MobileEngine.export（成片落盘）、
//   PhotoLibraryWriter.save（入相册）、StockCatalog.shared.stock（配方 id）。

// MARK: - 暗房对外入口

struct RelicDarkroomView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rolls: [RollRecord] = []
    @State private var selected: RollRecord? = nil
    @State private var phase: Phase = .choose
    @State private var errorMessage: String? = nil

    private let store = RelicRollStore.shared

    enum Phase {
        case choose        // 选卷
        case developing    // 冲洗中（逐帧）
        case gallery       // 逐张过片浏览
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.11, green: 0.055, blue: 0.065).ignoresSafeArea()
                switch phase {
                case .choose:
                    chooseView
                case .developing:
                    if let selected {
                        RelicDevelopProgressView(roll: selected) { finished in
                            Task { @MainActor in
                    if finished {
                        // 冲洗完成后卷状态已变成 developed/editable，不在 reloadRolls() 的
                        // shooting 筛选里 —— 绝不能用它覆盖 selected（会把成片页的卷变成 nil）。
                        // 按 id 直接取最新卷，frames 完整保留，成片才能显示。
                        self.selected = await store.roll(withId: selected.rollId) ?? selected
                        withAnimation { self.phase = .gallery }
                    } else {
                                    self.errorMessage = "冲洗失败：部分帧无法渲染。已完成的帧仍可在相册外查看。"
                                    withAnimation { self.phase = .gallery }
                                }
                            }
                        }
                    }
                case .gallery:
                    if let selected {
                        RelicDevelopedGalleryView(roll: selected, store: store,
                                                  onClose: { dismiss() })
                    }
                }
            }
            .navigationTitle(phase == .choose ? "暗房 DARKROOM" : (phase == .developing ? "显影中" : "成片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(phase == .gallery ? "完成" : "关闭") { dismiss() }
                        .foregroundColor(.yellow)
                }
            }
            .alert("冲洗出错", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task { await reloadRolls() }
    }

    // MARK: 选卷

    private var chooseView: some View {
        Group {
            if rolls.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 52)).foregroundColor(.white.opacity(0.3))
                    Text("还没有胶卷").foregroundColor(.white.opacity(0.7))
                    Text("装卷、拍满或拍几张之后，来这里冲洗。")
                        .font(.system(size: 13)).foregroundColor(.white.opacity(0.45))
                }
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        Text("选择要冲洗的胶卷")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                        ForEach(rolls) { roll in
                            RelicRollRow(roll: roll) {
                                selected = roll
                                // 未冲洗 → 进冲洗流程；已冲洗 → 直接回看成片。
                                withAnimation {
                                    phase = roll.status == RollContract.statusShooting
                                        ? .developing : .gallery
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private func reloadRolls() async {
        let all = await store.loadRolls()
        // 有帧的卷都要能进暗房：未冲洗（shooting）可冲洗，已冲洗（developed/editable）
        // 可回看成片。否则冲洗完 dismiss 后成片就再也找不回来 —— 用户反馈的「看不到照片」。
        let withFrames = all.filter { !$0.frames.isEmpty }
            .sorted { $0.createdAtMs > $1.createdAtMs }
        await MainActor.run { self.rolls = withFrames }
    }
}

// MARK: - 待冲洗卷行

private struct RelicRollRow: View {
    let roll: RollRecord
    let action: () -> Void

    private var stockName: String {
        guard let s = StockCatalog.shared.stock(roll.filmStockId) else { return roll.filmStockId }
        return s.name
    }

    private var isDeveloped: Bool { roll.status != RollContract.statusShooting }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5))
                    Image(systemName: isDeveloped ? "photo.stack" : "film")
                        .font(.system(size: 26))
                        .foregroundColor(isDeveloped ? Color.green.opacity(0.9) : Color.yellow.opacity(0.85))
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(stockName).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    Text(isDeveloped
                         ? "\(roll.frames.count) 张成片 · 点击查看"
                         : "\(roll.frames.count) 张待冲洗 · \(RollContract.maxShots) 张装量")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(isDeveloped ? Color.green.opacity(0.85) : Color.yellow.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.white.opacity(0.35))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.09), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 冲洗进度（逐帧，前台 + checkpoint 续冲）

private struct RelicDevelopProgressView: View {
    let roll: RollRecord
    let finished: (Bool) -> Void

    @State private var done = 0
    @State private var total = 0
    @State private var currentIndex = 0
    @State private var phaseText = "准备显影液…"
    @State private var etaText = ""
    @State private var preview: CGImage? = nil
    @State private var errorCount = 0

    private let store = RelicRollStore.shared

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            // 显影中的母片预览（每帧完成后刷新一张）
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black)
                if let preview {
                    Image(uiImage: UIImage(cgImage: preview))
                        .resizable().scaledToFit().padding(10)
                } else {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 46)).foregroundColor(.green.opacity(0.5))
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxHeight: 380)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))

            VStack(spacing: 10) {
                Text(phaseText)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.green)
                Text("\(done) / \(total) 张")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                if !etaText.isEmpty {
                    Text(etaText).font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                }
                ProgressView(value: total > 0 ? Float(done) / Float(total) : 0)
                    .tint(.green)
            }

            Text("显影中请勿锁屏或切走 App。\n每冲好一张都会立即保存，回来可接着冲。")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            let ok = await RelicDeveloper.develop(roll: roll, store: store,
                                                  onProgress: { d, t, idx, cg, eta in
                self.done = d; self.total = t; self.currentIndex = idx
                self.etaText = eta
                self.phaseText = d == 0 ? "首次显影，正在配药…" : "显影中 · 第 \(idx + 1) 张"
                if let cg { self.preview = cg }
            })
            UIApplication.shared.isIdleTimerDisabled = false
            self.errorCount = ok ? 0 : 1
            finished(ok)
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

// MARK: - 冲洗引擎封装

@MainActor
enum RelicDeveloper {
    /// 整卷冲洗。返回是否全部帧成功。进度回调在主线程直接调用。
    static func develop(roll: RollRecord, store: RelicRollStore,
                        onProgress: (Int, Int, Int, CGImage?, String) -> Void) async -> Bool {
        let frames = roll.frames.sorted { $0.index < $1.index }
        let total = frames.count
        guard total > 0 else { return true }

        await store.beginDevelop(rollId: roll.rollId)
        let cp = await store.loadCheckpoint(rollId: roll.rollId)
        var completed = Set(cp?.completedFrameIndices ?? [])

        var emaMs: Double = 0
        var first = true
        var allOK = true

        // 一个引擎实例贯穿整卷 —— render 不 close 会话；只有 export 内部 close。
        // 因此每帧用「export 出成片 + render 出缩略图」两次调用，兼顾稳定与预览。
        for frame in frames {
            if completed.contains(frame.index) { continue }
            let start = Date()
            onProgress(completed.count, total, frame.index, nil, eta(emaMs, total - completed.count))

            let rawURL = RelicPaths.undevelopedDirectory().appendingPathComponent(frame.handle)
            guard FileManager.default.fileExists(atPath: rawURL.path) else {
                allOK = false; continue
            }

            let recipe = recipe(for: roll)
            let engine = MobileEngine()
            do {
                // 1. 成片：引擎真正渲染，落盘到临时目录（内部处理色彩/元数据）
                let stem = "relic-\(roll.rollId)-\(frame.index)"
                let out = try await engine.export(url: rawURL, recipe: recipe,
                                                  geometry: MobileGeometry(), format: .jpeg)

                // 2. 搬到 Developed 私有目录（成片母片，未入相册）
                let developedDir = RelicPaths.developedDirectory()
                let finalURL = developedDir.appendingPathComponent("\(stem).jpg")
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try? FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.copyItem(at: out, to: finalURL)
                try? FileManager.default.removeItem(at: out.deletingLastPathComponent())

                // 3. 缩略图：直接从成片文件降采样，零额外渲染
                let thumb = RelicDeveloper.thumbnail(of: finalURL)

                completed.insert(frame.index)
                var cp = cp ?? DevelopCheckpoint(rollId: roll.rollId,
                                                  filmStockId: roll.filmStockId,
                                                  printStockId: roll.printStockId)
                cp.completedFrameIndices = completed.sorted()
                cp.updatedAt = Date()
                await store.saveCheckpoint(cp)

                let elapsed = Date().timeIntervalSince(start) * 1000
                emaMs = first ? elapsed : emaMs * 0.7 + elapsed * 0.3
                first = false
                onProgress(completed.count, total, frame.index, thumb, eta(emaMs, total - completed.count))
            } catch {
                allOK = false
                var cp = await store.loadCheckpoint(rollId: roll.rollId)
                    ?? DevelopCheckpoint(rollId: roll.rollId, filmStockId: roll.filmStockId,
                                         printStockId: roll.printStockId)
                cp.failedFrameIndex = frame.index
                cp.updatedAt = Date()
                await store.saveCheckpoint(cp)
            }
        }

        if allOK {
            await store.finishDevelop(rollId: roll.rollId)
        }
        return allOK
    }

    /// 字符串 id → 引擎 recipe（照搬 MobileDocument.applyFilm / setPaper 的键名）
    private static func recipe(for roll: RollRecord) -> [String: WireValue] {
        var r: [String: WireValue] = [:]
        if let film = StockCatalog.shared.stock(roll.filmStockId) {
            r["film_stock"] = .string(film.id)
            r["scan_film"] = .bool(film.isPositive)
            r["digital_intermediate"] = .bool(false)
            if let p = film.targetPrint { r["print_stock"] = .string(p) }
        } else {
            r["film_stock"] = .string(roll.filmStockId)
        }
        if let paper = StockCatalog.shared.stock(roll.printStockId) {
            r["print_stock"] = .string(paper.id)   // 用户选纸优先，覆盖 targetPrint
        }
        return r
    }

    private static func eta(_ emaMs: Double, _ remaining: Int) -> String {
        guard emaMs > 0, remaining > 0 else { return "" }
        let sec = Int(emaMs * Double(remaining) / 1000)
        return "预计还需约 \(max(1, sec)) 秒"
    }

    /// 从成片文件读一张小缩略图，零引擎开销。进度页与成片页共用 —— 避免全尺寸
    /// 解码（36MP≈144MB）在 13 mini 等机型上翻页被系统回收导致「照片消失」。
    fileprivate static func thumbnail(of url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// MARK: - 成片过片浏览

private struct RelicDevelopedGalleryView: View {
    let roll: RollRecord
    let store: RelicRollStore
    let onClose: () -> Void

    @State private var index = 0
    @State private var image: CGImage? = nil
    @State private var saved: Set<Int> = []
    @State private var saving = false
    @State private var notice: String? = nil

    private var frame: FrameRecord? { roll.frames.sorted { $0.index < $1.index }.safe(index) }
    private var total: Int { roll.frames.count }

    var body: some View {
        VStack(spacing: 16) {
            if let frame {
                ZStack {
                    Color.black
                    if let image {
                        Image(uiImage: UIImage(cgImage: image))
                            .resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo").font(.system(size: 40)).foregroundColor(.white.opacity(0.3))
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.12), lineWidth: 1))
                .task(id: frame.index) { await load(frame) }

                HStack(spacing: 30) {
                    Button {
                        if index > 0 { index -= 1 }
                    } label: {
                        Image(systemName: "chevron.left").font(.system(size: 22))
                    }
                    .disabled(index <= 0).foregroundColor(index > 0 ? .white : .white.opacity(0.2))

                    Text("\(index + 1) / \(total)")
                        .font(.system(size: 15, design: .monospaced)).foregroundColor(.yellow)

                    Button {
                        if index < total - 1 { index += 1 }
                    } label: {
                        Image(systemName: "chevron.right").font(.system(size: 22))
                    }
                    .disabled(index >= total - 1).foregroundColor(index < total - 1 ? .white : .white.opacity(0.2))
                }

                Button(action: { Task { await saveToPhotos(frame) } }) {
                    HStack(spacing: 8) {
                        if saving { ProgressView().tint(.black) }
                        Image(systemName: saved.contains(frame.index) ? "checkmark.circle.fill" : "square.and.arrow.down")
                        Text(saved.contains(frame.index) ? "已存入相册" : "存入相册")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 34).padding(.vertical, 11)
                    .background(saved.contains(frame.index) ? Color.green.opacity(0.85) : Color.yellow)
                    .cornerRadius(9)
                }
                .disabled(saving || saved.contains(frame.index))
            } else {
                Text("这一卷还没有成片").foregroundColor(.white.opacity(0.6))
            }

            if let notice {
                Text(notice).font(.system(size: 12)).foregroundColor(.red.opacity(0.9))
            }

            Text("这是冲洗出来的母片。只有点「存入相册」才会写进系统图库。")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .padding()
        .task {
            // 全部浏览（或至少看过）后转 editable
            await store.markEditable(rollId: roll.rollId)
        }
    }

    private func load(_ frame: FrameRecord) async {
        let name = "relic-\(roll.rollId)-\(frame.index).jpg"
        let url = RelicPaths.developedDirectory().appendingPathComponent(name)
        // 用缩略图解码而非全尺寸，避免大图在真机上因内存被回收而变空白。
        guard let cg = RelicDeveloper.thumbnail(of: url) else {
            await MainActor.run { self.image = nil }
            return
        }
        await MainActor.run { self.image = cg }
    }

    private func saveToPhotos(_ frame: FrameRecord) async {
        saving = true
        let name = "relic-\(roll.rollId)-\(frame.index).jpg"
        let url = RelicPaths.developedDirectory().appendingPathComponent(name)
        do {
            try await PhotoLibraryWriter.save(url)
            await MainActor.run {
                self.saved.insert(frame.index)
                self.notice = nil
            }
        } catch {
            await MainActor.run { self.notice = "保存失败：\(error.localizedDescription)" }
        }
        await MainActor.run { self.saving = false }
    }
}

// MARK: - 路径扩展

extension RelicPaths {
    static func developedDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("RelicCam/Developed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - 小工具

private extension Array {
    func safe(_ i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
