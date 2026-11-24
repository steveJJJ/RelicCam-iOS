import SwiftUI
import UIKit
import CoreImage
import Photos
import Darwin

/// 一次冲洗的结果。失败原因必须能回到界面 —— C2 把错误吞进 checkpoint，
/// 用户只看到「空白成片页」，完全无法判断是内存不足还是底片损坏。
struct RelicDevelopResult {
    let ok: Bool
    let message: String?
}

/// 落盘诊断：即使 App 在冲洗中被系统杀掉，下次打开也能看到最后一步。
private enum RelicDarkroomLog {
    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
    private static var url: URL {
        RelicPaths.developedDirectory().deletingLastPathComponent()
            .appendingPathComponent("darkroom.log")
    }
    static func write(_ line: String) {
        let entry = "\(stamp()) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            handle.closeFile()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
        // 防止无限增长，超过 64KB 只留后半段。
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 64 * 1024,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let lines = text.split(separator: "\n").suffix(80).joined(separator: "\n") + "\n"
            try? (lines + "").write(to: url, atomically: true, encoding: .utf8)
        }
    }
    static func tail(_ count: Int = 5) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}

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
    @State private var diagnostic = ""
    // 成片墙：所有已冲洗卷里真实存在母片的帧，像系统相册一样铺成网格。
    @State private var printedPhotos: [RelicPrintedPhoto] = []
    // 未冲洗胶卷区（对齐安卓 GalleryActivity 的 rvUndeveloped）：只含 shooting/developing 卷。
    @State private var undevelopedRolls: [RollRecord] = []
    // 从成片墙点进大图时，定位到对应帧（在卷内排序后的位置）。
    @State private var galleryInitialIndex = 0

    private let store = RelicRollStore.shared

    enum Phase: Equatable {
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
                        RelicDevelopProgressView(roll: selected,
                                                 onCancel: { withAnimation { phase = .choose } }) { finished in
                            Task { @MainActor in
                                // C15：显影一结束立刻重建暗房数据。此前只有首次进暗房的
                                // .task 会 reload，卷状态 shooting→developed 和刚落盘的
                                // 母片都没进 @State —— 于是冲洗完进成片页是空的，返回
                                // 暗房主页仍显示「待冲洗」，必须退出暗房重进才有照片。
                                await self.reloadRolls()
                                if finished {
                                    // 按 id 取最新卷，不用 reloadRolls 的 shooting 筛选覆盖
                                    // selected（会把成片页的卷变成 nil）。
                                    self.selected = await store.roll(withId: selected.rollId) ?? selected
                                    // 冲洗后从第 0 张开始过片；成片墙点进来的定位只在 openPrint 里设。
                                    self.galleryInitialIndex = 0
                                    withAnimation { self.phase = .gallery }
                                } else {
                                    self.errorMessage = "冲洗失败：部分帧无法渲染。已完成的帧仍可在相册外查看。"
                                    withAnimation { self.phase = .gallery }
                                }
                            }
                        }
                    }
                case .gallery:
                    RelicDevelopedGalleryView(
                        photos: printedPhotos,
                        initialIndex: galleryInitialIndex,
                        store: store,
                        // 回暗房主页（成片墙），不是退出整个暗房。
                        onClose: { withAnimation { phase = .choose } },
                        // 删除后刷新成片墙数据；删空了回主页。
                        onDeleted: {
                            Task { @MainActor in
                                await reloadRolls()
                                if printedPhotos.isEmpty {
                                    withAnimation { phase = .choose }
                                }
                            }
                        }
                    )
                }
            }
            .navigationTitle(phase == .choose ? "暗房 DARKROOM" : (phase == .developing ? "显影中" : "成片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // 成片页「完成」回暗房主页；只有暗房主页的「关闭」才退出整个暗房。
                    Button(phase == .gallery ? "完成" : "关闭") {
                        if phase == .gallery {
                            withAnimation { phase = .choose }
                        } else {
                            dismiss()
                        }
                    }
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
        // C15：任何路径回到暗房主页都重建一次数据（成片页返回、冲洗页取消返回），
        // 避免 @State 残留进暗房时的旧快照。
        .onChange(of: phase) { _, newPhase in
            guard newPhase == .choose else { return }
            Task { @MainActor in await reloadRolls() }
        }
    }

    // MARK: 选卷

    private var chooseView: some View {
        Group {
            if undevelopedRolls.isEmpty && printedPhotos.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 52)).foregroundColor(.white.opacity(0.3))
                    Text("还没有胶卷").foregroundColor(.white.opacity(0.7))
                    Text("装卷、拍满或拍几张之后，来这里冲洗。")
                        .font(.system(size: 13)).foregroundColor(.white.opacity(0.45))
                }
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        // ① 未冲洗胶卷区 —— 对齐安卓 GalleryActivity 的 rvUndeveloped：
                        // 暗红底、横向卡片（胶卷名 + N/36 + 冲洗按钮），点按钮直接进显影。
                        if !undevelopedRolls.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("待冲洗胶卷")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.77))
                                Text("这里有底片还没冲洗，点「冲洗」送进暗房。")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.45))
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(undevelopedRolls) { roll in
                                            RelicUndevelopedCard(roll: roll) {
                                                selected = roll
                                                galleryInitialIndex = 0
                                                // shooting 首次冲洗；developing 续冲（checkpoint 跳过已完成帧）。
                                                withAnimation { phase = .developing }
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(red: 0.10, green: 0.0, blue: 0.0))
                            .cornerRadius(10)
                        }

                        // ② 成片相框：三档 + 日期戳（对齐安卓 EditActivity 的编辑页）。
                        // 母片不动，切换后重新生成带框版本，已有成片也立即生效。
                        RelicFrameSettingsCard {
                            Task { @MainActor in await reloadRolls() }
                        }

                        // ③ 成片墙：像系统相册一样铺开所有已冲洗照片。
                        if !printedPhotos.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 7) {
                                    Image(systemName: "photo.stack")
                                        .foregroundColor(.green.opacity(0.9))
                                    Text("成片 · \(printedPhotos.count) 张")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.85))
                                    Spacer()
                                }
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3),
                                    spacing: 3
                                ) {
                                    ForEach(printedPhotos) { photo in
                                        Button { openPrint(photo) } label: {
                                            RelicPrintCell(url: photo.url)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                Text("点任意一张看大图、翻页或存入相册。")
                                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                            }
                        }

                        if !diagnostic.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("上次显影诊断").font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.orange.opacity(0.9))
                                Text(diagnostic)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.5))
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
                        }
                    }
                    .padding()
                }
            }
        }
    }

    /// 从成片墙点一张：定位到被点的那张，大图页在整个成片墙里左右滑。
    private func openPrint(_ photo: RelicPrintedPhoto) {
        guard let idx = printedPhotos.firstIndex(where: { $0.id == photo.id }) else {
            RelicDarkroomLog.write("GRID tap photo missing \(photo.id)")
            return
        }
        // 成片齐全的卷转 editable（原来在大图页 .task 里做，现在挪到这里）。
        if let roll = rolls.first(where: { $0.rollId == photo.rollId }),
           roll.frames.allSatisfy({ RelicPaths.printURL(
               name: "relic-\(roll.rollId)-\($0.index).jpg") != nil }),
           !roll.frames.isEmpty {
            Task { @MainActor in await store.markEditable(rollId: roll.rollId) }
        } else {
            RelicDarkroomLog.write("NOT EDITABLE roll=\(photo.rollId) missing prints")
        }
        selected = nil
        galleryInitialIndex = idx
        withAnimation { phase = .gallery }
    }

    private func reloadRolls() async {
        let all = await store.loadRolls()
        // 有帧的卷都要能进暗房：未冲洗（shooting）可冲洗，已冲洗（developed/editable）
        // 可回看成片。否则冲洗完 dismiss 后成片就再也找不回来 —— 用户反馈的「看不到照片」。
        let withFrames = all.filter { !$0.frames.isEmpty }
            .sorted { $0.createdAtMs > $1.createdAtMs }

        // C16：母片 → 带框成片（白边/片边 + 日期戳 + CONTAX EXIF）。
        // 只补缺失的 Framed 文件；改档时 invalidateAll() 会清空后按新设置全部重生成。
        // 在后台线程跑，避免几十张图的解码/绘制卡住主线程。
        await RelicPrintRenderer.rebuild(rolls: withFrames)

        // 成片墙：把每个已冲洗卷里「母片真实存在」的帧收集起来，按卷时间倒序铺开。
        // 只认文件在的，避免覆盖安装后母片丢失却留下空白格子。
        var prints: [RelicPrintedPhoto] = []
        for roll in withFrames where roll.status != RollContract.statusShooting &&
                                      roll.status != RollContract.statusDeveloping {
            let sortedFrames = roll.frames.sorted { $0.index < $1.index }
            for (pos, frame) in sortedFrames.enumerated() {
                let name = "relic-\(roll.rollId)-\(frame.index).jpg"
                if let url = RelicPaths.printURL(name: name) {
                    prints.append(RelicPrintedPhoto(
                        // C16：带 revision，切档后 ForEach identity 变化 → 缩略图重新解码。
                        id: "\(roll.rollId)-\(frame.index)-\(RelicFrameSettings.revision)",
                        rollId: roll.rollId,
                        frameIndex: frame.index,
                        framePos: pos,
                        url: url
                    ))
                }
            }
        }
        // 未冲洗胶卷：只留 shooting（可冲洗）和 developing（上次中断，可续冲）。
        let undev = withFrames.filter {
            $0.status == RollContract.statusShooting ||
            $0.status == RollContract.statusDeveloping
        }
        await MainActor.run {
            self.rolls = withFrames
            self.printedPhotos = prints
            self.undevelopedRolls = undev
            self.diagnostic = RelicDarkroomLog.tail(4)
        }
    }
}

/// 未冲洗胶卷卡片 —— 对齐安卓 UndevelopedAdapter 的横向红底卡片：
/// 胶卷名 + N/36 + 冲洗按钮；正在冲洗的卷按钮变「继续冲洗」。
private struct RelicUndevelopedCard: View {
    let roll: RollRecord
    let action: () -> Void

    private var stockName: String {
        guard let s = StockCatalog.shared.stock(roll.filmStockId) else { return roll.filmStockId }
        return s.name
    }
    private var isInterrupted: Bool { roll.status == RollContract.statusDeveloping }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "film")
                .font(.system(size: 24))
                .foregroundColor(Color(red: 1.0, green: 0.60, blue: 0.51))
            Text(stockName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.77))
                .lineLimit(1)
                .frame(width: 116, alignment: .leading)
            Text("\(roll.frames.count)/\(RollContract.maxShots)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(red: 1.0, green: 0.60, blue: 0.51))
            Button(action: action) {
                Text(isInterrupted ? "继续冲洗" : "冲洗")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.545, green: 0.10, blue: 0.10))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 144)
        .background(Color(red: 0.165, green: 0.031, blue: 0.031))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(red: 1.0, green: 0.60, blue: 0.51).opacity(0.18), lineWidth: 0.5))
    }
}

/// 成片墙里的一张照片。framePos 是该帧在所属卷排序后数组里的位置，
/// 用于点开大图时直接定位（而不是永远从第 0 张开始）。
private struct RelicPrintedPhoto: Identifiable {
    let id: String
    let rollId: String
    let frameIndex: Int      // 引擎帧号，用来拼母片文件名 relic-<rollId>-<frameIndex>.jpg
    let framePos: Int        // 在所属卷排序后数组里的位置
    let url: URL
}

/// 成片墙网格单元：小尺寸缩略图（240px 边），避免几十张图同屏吃爆内存。
private struct RelicPrintCell: View {
    let url: URL
    @State private var cg: CGImage? = nil

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.06))
            if let cg {
                Image(uiImage: UIImage(cgImage: cg))
                    .resizable().scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.2))
            }
        }
        // 【对齐安卓 SquareImageView：宽度定高度 + CENTER_CROP】
        // 原来用 .aspectRatio(1, contentMode: .fill)：fill 会让视图撑满父容器，
        // 横拍图（3:2）把格子顶高、溢出到下一行，遮住竖拍缩略图。
        // 改成 .fit + frame(maxWidth: .infinity)：格子严格正方形（高=宽），
        // 图片 scaledToFill 居中裁切，clipped 保证不越界。
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .task(id: url) {
            // .task 闭包在 MainActor 上，gridThumb 也是 @MainActor，无需跨 actor。
            self.cg = RelicDeveloper.gridThumb(of: url)
        }
    }
}

// MARK: - 冲洗进度（逐帧，前台 + checkpoint 续冲）

private struct RelicDevelopProgressView: View {
    let roll: RollRecord
    let onCancel: () -> Void
    let finished: (Bool) -> Void

    @State private var done = 0
    @State private var total = 0
    @State private var currentIndex = 0
    @State private var phaseText = "准备显影液…"
    @State private var etaText = ""
    @State private var preview: CGImage? = nil
    @State private var failure: String? = nil
    @State private var retry = 0

    private let store = RelicRollStore.shared

    private var progressContent: some View {
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
        .task(id: retry) {
            UIApplication.shared.isIdleTimerDisabled = true
            let available = Int(os_proc_available_memory() / 1_000_000)
            RelicDarkroomLog.write("BEGIN roll=\(roll.rollId) frames=\(roll.frames.count) avail=\(available)MB")
            let result = await RelicDeveloper.develop(roll: roll, store: store,
                                                      onProgress: { d, t, idx, cg, eta in
                self.done = d; self.total = t; self.currentIndex = idx
                self.etaText = eta
                self.phaseText = d == 0 ? "首次显影，正在配药…" : "显影中 · 第 \(idx + 1) 张"
                if let cg { self.preview = cg }
            })
            UIApplication.shared.isIdleTimerDisabled = false
            RelicDarkroomLog.write("END ok=\(result.ok) msg=\(result.message ?? "-")")
            if result.ok {
                finished(true)
            } else {
                // 失败不再偷偷跳进空白成片页 —— 把引擎的真实错误摆到用户面前。
                self.failure = result.message ?? "未知错误，请查看暗房诊断。"
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    var body: some View {
        Group {
            if let failure {
                VStack(spacing: 18) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 46)).foregroundColor(.orange)
                    Text("显影失败").font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                    Text(failure)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                    Button("重试冲洗") {
                        self.failure = nil
                        self.retry += 1
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 30).padding(.vertical, 10)
                    .background(Color.yellow).cornerRadius(9)
                    Button("返回选卷") { onCancel() }
                        .foregroundColor(.white.opacity(0.65))
                    Spacer()
                }
                .padding()
            } else {
                progressContent
            }
        }
    }
}

// MARK: - 冲洗引擎封装

@MainActor
enum RelicDeveloper {
    /// 整卷冲洗。返回成功与否 + 可展示的真实错误（不再静默吞异常）。
    static func develop(roll: RollRecord, store: RelicRollStore,
                        onProgress: (Int, Int, Int, CGImage?, String) -> Void) async -> RelicDevelopResult {
        let frames = roll.frames.sorted { $0.index < $1.index }
        let total = frames.count
        guard total > 0 else { return RelicDevelopResult(ok: true, message: nil) }

        await store.beginDevelop(rollId: roll.rollId)
        let cp = await store.loadCheckpoint(rollId: roll.rollId)
        var completed = Set(cp?.completedFrameIndices ?? [])
        RelicDarkroomLog.write("RESUME done=\(completed.count)/\(total)")

        var emaMs: Double = 0
        var first = true
        var allOK = true
        var lastError: String? = nil
        let rawDir = RelicPaths.undevelopedDirectory()
        let developedDir = RelicPaths.developedDirectory()
        let backupDir = RelicPaths.printsBackupDirectory()

        for frame in frames {
            let stem = "relic-\(roll.rollId)-\(frame.index)"
            let finalURL = developedDir.appendingPathComponent("\(stem).jpg")
            // checkpoint 说完成，还得文件真在才算 —— 主目录被清但备份在也算完成，
            // 并把备份恢复到主目录，让后续 gallery/存相册都走主路径。
            if completed.contains(frame.index) {
                if FileManager.default.fileExists(atPath: finalURL.path) { continue }
                // C16：这里要恢复的是「无框母片」，不能用 printURL（它会优先返回
                // 带框成片，写回 Developed 会把白边/日期当成母片再冲一遍）。
                if let found = RelicPaths.masterPrintURL(name: "\(stem).jpg") {
                    try? FileManager.default.copyItem(at: found, to: finalURL)
                    RelicDarkroomLog.write("RESTORE frame=\(frame.index) from=\(found.lastPathComponent)")
                    continue
                }
            }
            let start = Date()
            onProgress(completed.count, total, frame.index, nil, eta(emaMs, total - completed.count))

            let rawURL = rawDir.appendingPathComponent(frame.handle)
            guard FileManager.default.fileExists(atPath: rawURL.path) else {
                let msg = "底片文件丢失：\(frame.handle)"
                RelicDarkroomLog.write("MISS frame=\(frame.index) \(msg)")
                lastError = msg; allOK = false
                await markFailed(frame.index, roll: roll, store: store)
                continue
            }

            let recipe = recipe(for: roll)
            var frameOK = false

            // 致命点：引擎默认导出配方上限 24MP，内存门槛约 2.3GB；
            // 13 mini 上必然被 os_proc_available_memory() 拒绝，C2 又把错误吞了。
            // 逐级降到 6/3/1.5MP —— 宁可成片小一点，也必须先把照片冲出来。
            for mp in [6.0, 3.0, 1.5] {
                let available = Int(os_proc_available_memory() / 1_000_000)
                RelicDarkroomLog.write("TRY frame=\(frame.index) mp=\(mp) avail=\(available)MB")
                do {
                    var options = MobileExportRecipe()
                    options.format = .jpeg
                    options.sizeMode = "megapixels"
                    options.maximumMegapixels = mp
                    options.quality = 0.92
                    options.metadata = false
                    options.location = false
                    let engine = MobileEngine()
                    let files = try await engine.exportFiles(url: rawURL, recipe: recipe,
                                                              geometry: MobileGeometry(),
                                                              options: options, stem: stem)
                    guard let out = files.first else {
                        throw NSError(domain: "RelicCam", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "引擎没有产出图片"])
                    }
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        try? FileManager.default.removeItem(at: finalURL)
                    }
                    try FileManager.default.copyItem(at: out, to: finalURL)
                    // 冗余备份到独立目录：覆盖安装/系统清理可能抹掉 Application Support
                    // 下的 Developed，备份目录在 Documents 下，通常一并保留。
                    let backupURL = backupDir.appendingPathComponent("\(stem).jpg")
                    try? FileManager.default.removeItem(at: backupURL)
                    try? FileManager.default.copyItem(at: finalURL, to: backupURL)
                    try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int) ?? 0
                    RelicDarkroomLog.write("OK frame=\(frame.index) mp=\(mp) bytes=\(bytes) backup=\(FileManager.default.fileExists(atPath: backupURL.path))")
                    frameOK = true
                    lastError = nil
                    break
                } catch {
                    let msg = describe(error)
                    lastError = msg
                    RelicDarkroomLog.write("FAIL frame=\(frame.index) mp=\(mp) err=\(msg)")
                }
            }

            guard frameOK else {
                allOK = false
                await markFailed(frame.index, roll: roll, store: store)
                continue
            }

            // 缩略图：直接从成片文件降采样，零额外引擎渲染
            let thumb = RelicDeveloper.thumbnail(of: developedDir.appendingPathComponent("\(stem).jpg"))
            completed.insert(frame.index)
            var nextCP = cp ?? DevelopCheckpoint(rollId: roll.rollId,
                                                  filmStockId: roll.filmStockId,
                                                  printStockId: roll.printStockId)
            nextCP.completedFrameIndices = completed.sorted()
            nextCP.updatedAt = Date()
            await store.saveCheckpoint(nextCP)

            let elapsed = Date().timeIntervalSince(start) * 1000
            emaMs = first ? elapsed : emaMs * 0.7 + elapsed * 0.3
            first = false
            onProgress(completed.count, total, frame.index, thumb, eta(emaMs, total - completed.count))
        }

        if allOK { await store.finishDevelop(rollId: roll.rollId) }
        return RelicDevelopResult(ok: allOK, message: allOK ? nil : (lastError ?? "部分帧冲洗失败"))
    }

    private static func markFailed(_ index: Int, roll: RollRecord, store: RelicRollStore) async {
        var cp = await store.loadCheckpoint(rollId: roll.rollId)
            ?? DevelopCheckpoint(rollId: roll.rollId, filmStockId: roll.filmStockId,
                                 printStockId: roll.printStockId)
        cp.failedFrameIndex = index
        cp.updatedAt = Date()
        await store.saveCheckpoint(cp)
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
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

    /// 从成片文件读一张展示图，零引擎开销。
    ///
    /// 关键修复：原实现用 kCGImageSourceCreateThumbnailFromImageAlways + transform，
    /// 引擎导出的 JPEG 带 P3 色彩配置 + EXIF orientation 时，这条路径在 iOS 上
    /// 会返回 nil —— 母片在磁盘上好好的、系统相册能显示，唯独暗房读不出来。
    /// 改成先用 UIImage(contentsOfFile:)（UIKit 会正确处理方向/色彩），
    /// 再退回 CGImageSource 原图解码，最后才用 ImageIO 缩略图。
    fileprivate static func thumbnail(of url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            RelicDarkroomLog.write("DECODE missing \(url.lastPathComponent)")
            return nil
        }
        // 【C8 核心修复】必须强制降采样，绝不能把全尺寸 CGImage 交给 SwiftUI。
        // UIImage(contentsOfFile:) 是懒解码：本函数返回时非 nil（日志会记 GALLERY ok），
        // 真正的像素解码发生在 Image(uiImage:) 渲染时 —— 6MP 全尺寸图在 13 mini 上
        // 因内存压力渲染失败，界面就是空白。系统相册自带 downsampling 所以能显示，
        // 这正是「相册有照片、暗房空白」的根因。
        // preparingThumbnail 在创建时就缩到目标像素，渲染时不再吃大内存。
        if let ui = UIImage(contentsOfFile: url.path) {
            let target = CGSize(width: 1200, height: 1800)
            if #available(iOS 15.0, *) {
                if let small = ui.preparingThumbnail(of: target), let cg = small.cgImage {
                    RelicDarkroomLog.write("DECODE thumb \(url.lastPathComponent) \(cg.width)x\(cg.height)")
                    return cg
                }
            }
            // 兜底：手动把全尺寸图画到目标尺寸（同样能强制像素解码 + 降采样）。
            let scale = min(1, 1800 / max(ui.size.width, ui.size.height))
            if scale < 1 {
                let sz = CGSize(width: ui.size.width * scale, height: ui.size.height * scale)
                let fmt = UIGraphicsImageRendererFormat()
                fmt.scale = 1
                let small = UIGraphicsImageRenderer(size: sz, format: fmt).image { _ in
                    ui.draw(in: CGRect(origin: .zero, size: sz))
                }
                if let cg = small.cgImage {
                    RelicDarkroomLog.write("DECODE render \(url.lastPathComponent) \(cg.width)x\(cg.height)")
                    return cg
                }
            }
            if let cg = ui.cgImage { return cg }
        }
        // ImageIO 缩略图（指定最大边，避免全尺寸）。
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                RelicDarkroomLog.write("DECODE io-thumb \(url.lastPathComponent)")
                return cg
            }
            if let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) { return cg }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        RelicDarkroomLog.write("DECODE fail \(url.lastPathComponent) size=\(size)")
        return nil
    }

    /// 成片墙网格专用：缩到 240px 边。几十张同屏时全尺寸解码会撑爆内存，
    /// 必须逐张降到缩略图尺寸再交给 SwiftUI（与 C8 的全尺寸空白同源）。
    static func gridThumb(of url: URL) -> CGImage? {
        guard let ui = UIImage(contentsOfFile: url.path) else { return nil }
        let target = CGSize(width: 240, height: 240)
        if #available(iOS 15.0, *) {
            if let small = ui.preparingThumbnail(of: target), let cg = small.cgImage {
                return cg
            }
        }
        let scale = min(1, 240 / max(ui.size.width, ui.size.height))
        let sz = CGSize(width: ui.size.width * scale, height: ui.size.height * scale)
        if sz.width < 1 || sz.height < 1 { return nil }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let small = UIGraphicsImageRenderer(size: sz, format: fmt).image { _ in
            ui.draw(in: CGRect(origin: .zero, size: sz))
        }
        return small.cgImage
    }
}

// MARK: - 「已存入相册」持久化
//
// 用户反馈：大图页每次打开都又提示「存入相册」，明明之前已经存过 ——
// 因为 saved 状态是 @State 内存态，从成片墙每次点开都是新实例，状态清零，
// 再点一次就会往系统图库重复写入同一张照片。改用 UserDefaults 按
// rollId-frameIndex 持久化，App 重启后仍然记得。

enum RelicSavedPrints {
    private static let key = "relic_saved_prints"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func isSaved(rollId: String, frameIndex: Int) -> Bool {
        load().contains("\(rollId)-\(frameIndex)")
    }

    static func markSaved(rollId: String, frameIndex: Int) {
        var all = load()
        all.insert("\(rollId)-\(frameIndex)")
        UserDefaults.standard.set(Array(all), forKey: key)
    }

    /// 删除成片时清掉标记，避免重冲后仍显示「已存入相册」。
    static func remove(rollId: String, frameIndex: Int) {
        var all = load()
        all.remove("\(rollId)-\(frameIndex)")
        UserDefaults.standard.set(Array(all), forKey: key)
    }
}

// MARK: - 成片过片浏览（系统相册式左右滑）

/// 单张大图页：左右滑切换整面成片墙；长按或点删除移除 APP 内成片。
/// 对齐安卓 PhotoViewerActivity 的 ViewPager2 体验。
private struct RelicDevelopedGalleryView: View {
    let photos: [RelicPrintedPhoto]
    let initialIndex: Int
    let store: RelicRollStore
    let onClose: () -> Void
    let onDeleted: () -> Void

    @State private var current = 0
    @State private var savedKeys: Set<String> = []
    @State private var saving = false
    @State private var notice: String? = nil
    @State private var pendingDelete: RelicPrintedPhoto? = nil

    private var photo: RelicPrintedPhoto? { photos.safe(current) }

    var body: some View {
        VStack(spacing: 10) {
            if photos.isEmpty {
                Spacer()
                Image(systemName: "photo.stack").font(.system(size: 44))
                    .foregroundColor(.white.opacity(0.3))
                Text("还没有成片").foregroundColor(.white.opacity(0.6))
                Button("返回暗房") { onClose() }.foregroundColor(.yellow).padding()
                Spacer()
            } else {
                TabView(selection: $current) {
                    ForEach(photos.indices, id: \.self) { idx in
                        RelicZoomPhotoCell(photo: photos[idx])
                            // 长按删除 —— 系统相册同款交互
                            .onLongPressGesture(minimumDuration: 0.6) {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                pendingDelete = photos[idx]
                            }
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

                // 页码 + 左右箭头（同时保留，兼顾无手势场景）
                HStack(spacing: 24) {
                    Button {
                        if current > 0 { withAnimation { current -= 1 } }
                    } label: {
                        Image(systemName: "chevron.left").font(.system(size: 20))
                    }
                    .disabled(current <= 0)
                    .foregroundColor(current > 0 ? .white : .white.opacity(0.2))

                    Text("\(current + 1) / \(photos.count)")
                        .font(.system(size: 14, design: .monospaced)).foregroundColor(.yellow)

                    Button {
                        if current < photos.count - 1 { withAnimation { current += 1 } }
                    } label: {
                        Image(systemName: "chevron.right").font(.system(size: 20))
                    }
                    .disabled(current >= photos.count - 1)
                    .foregroundColor(current < photos.count - 1 ? .white : .white.opacity(0.2))
                }
                .padding(.top, 4)

                if let photo {
                    HStack(spacing: 12) {
                        Button(action: { Task { await saveToPhotos(photo) } }) {
                            HStack(spacing: 7) {
                                if saving { ProgressView().tint(.black) }
                                Image(systemName: isSaved(photo) ? "checkmark.circle.fill" : "square.and.arrow.down")
                                Text(isSaved(photo) ? "已存入相册" : "存入相册")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(isSaved(photo) ? Color.green.opacity(0.85) : Color.yellow)
                            .cornerRadius(9)
                        }
                        .disabled(saving || isSaved(photo))

                        Button {
                            pendingDelete = photo
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                Text("删除")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(.red.opacity(0.95))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(9)
                        }
                    }
                }

                if let notice {
                    Text(notice).font(.system(size: 12)).foregroundColor(.red.opacity(0.9))
                }

                Text("左右滑动看下一张 · 长按照片删除 APP 内成片 · 存入相册会放进「Relic Cam」相簿")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .task {
            current = min(max(initialIndex, 0), max(photos.count - 1, 0))
            savedKeys = RelicSavedPrints.load()
            // 请求相簿写权限（读写的弹窗只会出现一次）
            _ = await RelicAlbumWriter.ensureAuthorization()
        }
        .confirmationDialog(
            "删除这张成片？",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = pendingDelete { Task { await deletePhoto(target) } }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("只删除 APP 内的成片，已存入系统相册的照片不受影响。")
        }
    }

    private func isSaved(_ photo: RelicPrintedPhoto) -> Bool {
        savedKeys.contains("\(photo.rollId)-\(photo.frameIndex)")
    }

    private func saveToPhotos(_ photo: RelicPrintedPhoto) async {
        saving = true
        guard let url = RelicPaths.printURL(name: "relic-\(photo.rollId)-\(photo.frameIndex).jpg") else {
            await MainActor.run {
                self.notice = "成片母片丢失，无法存入相册。"
                self.saving = false
            }
            return
        }
        do {
            try await RelicAlbumWriter.save(url)
            await MainActor.run {
                self.savedKeys.insert("\(photo.rollId)-\(photo.frameIndex)")
                RelicSavedPrints.markSaved(rollId: photo.rollId, frameIndex: photo.frameIndex)
                self.notice = nil
            }
        } catch {
            await MainActor.run { self.notice = "保存失败：\(error.localizedDescription)" }
        }
        await MainActor.run { self.saving = false }
    }

    private func deletePhoto(_ photo: RelicPrintedPhoto) async {
        let name = "relic-\(photo.rollId)-\(photo.frameIndex).jpg"
        // 主目录 + 备份目录都删，母片彻底移除；系统相册里的副本不动。
        let primary = RelicPaths.developedDirectory().appendingPathComponent(name)
        let backup = RelicPaths.printsBackupDirectory().appendingPathComponent(name)
        let framed = RelicPaths.framedDirectory().appendingPathComponent(name)
        try? FileManager.default.removeItem(at: primary)
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.removeItem(at: framed)
        // 清掉「已存入相册」标记，避免重冲后再显示错误状态
        RelicSavedPrints.remove(rollId: photo.rollId, frameIndex: photo.frameIndex)
        RelicDarkroomLog.write("DELETE \(name)")
        await MainActor.run {
            self.savedKeys.remove("\(photo.rollId)-\(photo.frameIndex)")
            self.pendingDelete = nil
            self.notice = nil
        }
        onDeleted()
    }
}

/// 大图单页：用缩略图解码（母片全尺寸 6MP 直接渲染会撑爆 13 mini 内存）。
private struct RelicZoomPhotoCell: View {
    let photo: RelicPrintedPhoto
    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .padding(.vertical, 4)
            } else {
                Image(systemName: "photo").font(.system(size: 36))
                    .foregroundColor(.white.opacity(0.25))
            }
        }
        .task(id: photo.id) {
            guard let cg = RelicDeveloper.thumbnail(of: photo.url) else { return }
            await MainActor.run { self.image = UIImage(cgImage: cg) }
        }
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

    /// 成片冗余备份目录（Documents 下，覆盖安装时比 Application Support 更可能被保留）。
    static func printsBackupDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = docs.appendingPathComponent("RelicCam/PrintsBackup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 带框成片目录（C16）：母片保持引擎导出的无框原样，展示/存相册都走这里。
    static func framedDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("RelicCam/Framed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 只找无框母片：主目录 → 备份目录。供 RelicPrintRenderer 重新生成带框版本。
    static func masterPrintURL(name: String) -> URL? {
        let fm = FileManager.default
        let primary = developedDirectory().appendingPathComponent(name)
        if fm.fileExists(atPath: primary.path) { return primary }
        let backup = printsBackupDirectory().appendingPathComponent(name)
        if fm.fileExists(atPath: backup.path) { return backup }
        return nil
    }

    /// 按文件名找成片：优先带框版本（相框/日期戳/EXIF），缺失才回退母片。
    static func printURL(name: String) -> URL? {
        let fm = FileManager.default
        let framed = framedDirectory().appendingPathComponent(name)
        if fm.fileExists(atPath: framed.path) { return framed }
        return masterPrintURL(name: name)
    }
}

// MARK: - 小工具

private extension Array {
    func safe(_ i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
