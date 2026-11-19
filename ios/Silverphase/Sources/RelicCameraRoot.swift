import SwiftUI

// MARK: - Relic Cam 根容器（阶段 B1）
//
// 管理「当前卷 / 剩余张数」状态，串联 T3 取景器 ↔ 装卷选择器 ↔ 暗房入口。
// 快门回调把原片字节落到 App 沙盒（未冲洗底片文件），再经 RelicRollStore
// 记一帧 status=shooting——绝不 develop，屏幕看不到成片。
//
// 阶段 B1 的暗房入口是占位；阶段 C 接真正的冲洗页。

struct RelicCameraRoot: View {
    @State private var activeRoll: RollRecord?
    @State private var loadedStock: Stock?
    @State private var showingFilmPicker = false
    @State private var showingDarkroom = false
    @State private var loaded = false

    private let store = RelicRollStore.shared

    var body: some View {
        ZStack {
            RelicCameraView(
                loadedStock: loadedStock,
                shotsRemaining: shotsRemaining,
                shoot: { data, format in
                    await storeUnprocessedFrame(data, format: format)
                },
                openFilmPicker: { showingFilmPicker = true },
                openDarkroom: { showingDarkroom = true }
            )

            // 未装卷：全屏引导
            if loaded && loadedStock == nil {
                VStack(spacing: 18) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 56))
                        .foregroundColor(.yellow.opacity(0.9))
                    Text("先装一卷胶卷")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                    Text("像真的 T3 一样，装卷之后才能拍摄。\n取景窗里看不到成片——冲洗之后才会知道拍到了什么。")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                    Button(action: { showingFilmPicker = true }) {
                        Text("装卷")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 40).padding(.vertical, 12)
                            .background(Color.yellow).cornerRadius(8)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.82))
            }
        }
        .sheet(isPresented: $showingFilmPicker) {
            RelicFilmPickerView(currentFilmID: activeRoll?.filmStockId) { stock in
                Task { await loadFilm(stock) }
            }
        }
        .sheet(isPresented: $showingDarkroom) {
            RelicDarkroomPlaceholder(roll: activeRoll)
        }
        .task { await bootstrap() }
    }

    private var shotsRemaining: Int {
        guard let roll = activeRoll else { return 0 }
        return max(0, RollContract.maxShots - roll.frames.count)
    }

    private func bootstrap() async {
        let rolls = await store.loadRolls()
        let active = await store.activeRoll()
        await MainActor.run {
            self.activeRoll = active
            self.loadedStock = active.flatMap { StockCatalog.shared.stock($0.filmStockId) }
            self.loaded = true
        }
        _ = rolls
    }

    private func loadFilm(_ stock: Stock) async {
        // 若有正在拍摄但未满的卷，先不覆盖（阶段 C 会提供"中途换卷"流程）；
        // B1 简化：存在活动卷时直接复用它，只更新显示。
        if let existing = await store.activeRoll() {
            await MainActor.run {
                self.activeRoll = existing
                self.loadedStock = StockCatalog.shared.stock(existing.filmStockId)
            }
            return
        }
        let printID = stock.targetPrint ?? StockCatalog.shared.papers.first?.id ?? ""
        let roll = await store.loadFilm(filmStockId: stock.id, printStockId: printID)
        await MainActor.run {
            self.activeRoll = roll
            self.loadedStock = stock
        }
    }

    /// 快门：把原片写到未冲洗底片文件，记一帧，返回是否成功。
    private func storeUnprocessedFrame(_ data: Data, format: MobileCaptureFormat) async -> Bool {
        guard let roll = activeRoll else { return false }
        let ext = format.fileExtension
        let name = "frame-\(roll.rollId)-\(roll.frames.count).\(ext)"
        let url = await RelicPaths.undevelopedDirectory().appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            let iso = loadedStock?.nominalSpeed
            let ok = await store.appendFrame(to: roll.rollId, handle: name, iso: iso, shot: "")
            if ok {
                let updated = await store.activeRoll()
                await MainActor.run { self.activeRoll = updated }
            }
            return ok
        } catch {
            return false
        }
    }
}

// MARK: - 沙盒路径
enum RelicPaths {
    static func undevelopedDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("RelicCam/Undeveloped", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - 暗房占位（阶段 C 接真正的冲洗页）
private struct RelicDarkroomPlaceholder: View {
    let roll: RollRecord?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.12, green: 0.06, blue: 0.07).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("暗房 DARKROOM")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.red)
                    if let roll {
                        Text("未冲洗胶卷")
                            .font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
                        Text(roll.filmStockId)
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("\(roll.frames.count) / \(RollContract.maxShots) 张")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.yellow)
                    } else {
                        Text("还没有胶卷")
                            .foregroundColor(.white.opacity(0.6))
                    }
                    Text("冲洗功能将在下一阶段接入。\n拍完的底片已经存好，看不到成片——这正是胶片的乐趣。")
                        .font(.system(size: 13)).foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.top, 20)
                }
                .padding()
            }
            .navigationTitle("暗房")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.foregroundColor(.yellow)
                }
            }
        }
    }
}
