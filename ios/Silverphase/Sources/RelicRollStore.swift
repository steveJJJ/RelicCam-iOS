import Foundation

// MARK: - 胶卷持久化存储（阶段 A）
//
// 整卷状态机的落盘层，对应 Android 的 UndevelopedFilmStore.kt / RollRegistry.kt。
// 用 actor 隔离以满足 SWIFT_STRICT_CONCURRENCY=complete；所有读写 await。
// 数据全部存在 App 的 Application Support 目录，不出设备（离线不变量）。
//
// 阶段 A 只提供存储原语 + 编译验证。阶段 B 的相机拍完调用 appendFrame，
// 阶段 C 的暗房调用 beginDevelop / markFrame / finishDevelop。

public actor RelicRollStore {
    public static let shared = RelicRollStore()

    private let fileManager: FileManager
    private let directory: URL
    private let rollsURL: URL
    private let optionsURL: URL

    private var cachedRolls: [RollRecord]? = nil

    private init() {
        self.fileManager = .default
        let support = fileManager.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("RelicCam", isDirectory: true)
        self.directory = dir
        self.rollsURL = dir.appendingPathComponent("rolls.json")
        self.optionsURL = dir.appendingPathComponent("capture_options.json")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - 胶卷

    /// 读取所有胶卷（含未冲洗 / 已冲洗），首次访问从磁盘加载。
    public func loadRolls() -> [RollRecord] {
        if let cachedRolls { return cachedRolls }
        let rolls = (try? Data(contentsOf: rollsURL))
            .flatMap { try? JSONDecoder().decode([RollRecord].self, from: $0) } ?? []
        cachedRolls = rolls
        return rolls
    }

    /// 当前正在拍摄的卷（status = shooting）。最新装入的优先 —— 换卷后必须指向新卷。
    /// 用 last 而非 first：新卷 append 在数组末尾，旧卷（拍过、待冲洗）仍留在前面。
    public func activeRoll() -> RollRecord? {
        loadRolls().last { $0.status == RollContract.statusShooting }
    }

    /// 按 id 取任意状态的卷（暗房冲洗完成后刷新用：此时卷已不是 shooting）。
    public func roll(withId id: String) -> RollRecord? {
        loadRolls().first { $0.rollId == id }
    }

    /// 装卷：创建新卷并设为当前。36 张上限在 appendFrame 处强制。
    /// 顺带清掉「未拍任何一张就换掉」的空卷，避免反复换卷累积废卷。
    public func loadFilm(filmStockId: String, printStockId: String) -> RollRecord {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let roll = RollRecord(rollId: "roll-\(now)-\(UUID().uuidString.prefix(8))",
                              filmStockId: filmStockId,
                              printStockId: printStockId,
                              createdAtMs: now)
        var rolls = loadRolls()
        rolls.removeAll { $0.status == RollContract.statusShooting && $0.frames.isEmpty }
        rolls.append(roll)
        persist(rolls)
        return roll
    }

    /// 拍一张：写入未冲洗底片帧。满 36 张返回 false，不写入。
    @discardableResult
    public func appendFrame(to rollId: String, handle: String, iso: Int?,
                            orientation: Int = 0, shot: String = "") -> Bool {
        var rolls = loadRolls()
        guard let idx = rolls.firstIndex(where: { $0.rollId == rollId }),
              rolls[idx].status == RollContract.statusShooting,
              rolls[idx].frames.count < RollContract.maxShots else { return false }
        let frame = FrameRecord(index: rolls[idx].frames.count,
                                handle: handle,
                                takenAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                iso: iso,
                                orientation: orientation,
                                shot: shot)
        rolls[idx].frames.append(frame)
        persist(rolls)
        return true
    }

    /// 开始冲洗：shooting → developing。
    public func beginDevelop(rollId: String) {
        setStatus(rollId: rollId, status: RollContract.statusDeveloping)
    }

    /// 冲洗完成：developing → developed（出片后可再转 editable）。
    public func finishDevelop(rollId: String) {
        setStatus(rollId: rollId, status: RollContract.statusDeveloped)
    }

    public func markEditable(rollId: String) {
        setStatus(rollId: rollId, status: RollContract.statusEditable)
    }

    private func setStatus(rollId: String, status: String) {
        var rolls = loadRolls()
        guard let idx = rolls.firstIndex(where: { $0.rollId == rollId }) else { return }
        rolls[idx].status = status
        persist(rolls)
    }

    private func persist(_ rolls: [RollRecord]) {
        cachedRolls = rolls
        guard let data = try? JSONEncoder().encode(rolls) else { return }
        try? data.write(to: rollsURL, options: .atomic)
    }

    // MARK: - 冲洗断点

    /// checkpoint 每帧完成写一次，App 被杀后续冲不重渲。
    public func loadCheckpoint(rollId: String) -> DevelopCheckpoint? {
        let url = checkpointURL(rollId: rollId)
        return (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(DevelopCheckpoint.self, from: $0) }
    }

    public func saveCheckpoint(_ cp: DevelopCheckpoint) {
        guard let data = try? JSONEncoder().encode(cp) else { return }
        try? data.write(to: checkpointURL(rollId: cp.rollId), options: .atomic)
    }

    private func checkpointURL(rollId: String) -> URL {
        // rollId 由本类型生成，含 '-' 与十六进制，无路径分隔符，可直接作文件名。
        directory.appendingPathComponent("checkpoint-\(rollId).json")
    }

    // MARK: - 工程师模式选项

    public func loadOptions() -> RelicCaptureOptions {
        (try? Data(contentsOf: optionsURL))
            .flatMap { try? JSONDecoder().decode(RelicCaptureOptions.self, from: $0) }
            ?? RelicCaptureOptions()
    }

    public func saveOptions(_ options: RelicCaptureOptions) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        try? data.write(to: optionsURL, options: .atomic)
    }
}
