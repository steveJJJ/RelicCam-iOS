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
        .sheet(isPresented: $showingDarkroom, onDismiss: {
            Task { await refreshAfterDarkroom() }
        }) {
            RelicDarkroomView { filmID in
                // C18：拍摄同款 —— 装同款新卷，关掉暗房 sheet 回相机。
                // 用 filmStockId 从目录取 Stock（含 targetPrint），走和装卷页相同的 loadFilm。
                Task { @MainActor in
                    if let stock = StockCatalog.shared.stock(filmID) {
                        await loadFilm(stock)
                    }
                    showingDarkroom = false
                }
            }
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
        // 用户选了胶卷就真正装上新卷 —— 旧卷（若已拍）保留为待冲洗，不覆盖、不丢失。
        // 之前的实现「有活动卷就复用」会让换卷永远不生效，是本次修复的核心。
        let printID = stock.targetPrint ?? StockCatalog.shared.papers.first?.id ?? ""
        let roll = await store.loadFilm(filmStockId: stock.id, printStockId: printID)
        await MainActor.run {
            self.activeRoll = roll
            self.loadedStock = stock
        }
    }

    /// 暗房关闭后重建活动卷。冲洗会把原卷 status 改成 developing/developed，
    /// 而 activeRoll() 只认 shooting —— 不自动装新卷的话，回到相机继续拍会
    /// 写进那卷已被取走的底片，appendFrame 拒绝后误报「底片已满或写入失败」。
    private func refreshAfterDarkroom() async {
        if let active = await store.activeRoll() {
            await MainActor.run { self.activeRoll = active }
            return
        }
        // 原卷已送暗房：用同款胶卷自动装上新卷，相机可立即继续拍。
        // loadFilm 会清掉「空且 shooting」的废卷，不会反复累积。
        let stock = await MainActor.run { self.loadedStock }
        if let stock { await loadFilm(stock) }
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
