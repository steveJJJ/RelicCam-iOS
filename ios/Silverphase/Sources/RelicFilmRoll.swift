import Foundation

// MARK: - Relic Cam 胶卷状态机（阶段 A）
//
// 从 Android vc74 的 RollRegistry.kt / UndevelopedFilmStore.kt 1:1 移植。
// 这是 FROZEN 契约：字段名、枚举值、RollInfo 的字段顺序都与 Kotlin 快照一致，
// 冲洗管线按下标/字段名读取。移植期不要"优化"。
//
// 与旧骨架 FilmRoll.swift 的两处必要修正：
//   1. 修掉注释行首误留的 diff 标记 '+'（旧文件 line 91，会导致 Swift 编译失败）。
//   2. 全部类型标注 Sendable —— fork 工程开启 SWIFT_STRICT_CONCURRENCY=complete。
// 字段名与语义零改动。

public enum RollContract {
    public static let maxShots = 36

    public static let statusShooting = "shooting"
    public static let statusDeveloping = "developing"
    public static let statusDeveloped = "developed"
    public static let statusEditable = "editable"

    public static func isUndeveloped(_ status: String) -> Bool {
        status == statusShooting || status == statusDeveloping
    }

    public static func isEditable(_ status: String) -> Bool {
        status == statusEditable
    }
}

/// 单帧记录。`shot` 是拍摄参数 JSON；空串对旧记录合法。
/// `orientation == 0` 表示拍摄链已经物理旋转过这一帧。
public struct FrameRecord: Codable, Equatable, Identifiable, Sendable {
    public let index: Int
    public let handle: String
    public let takenAtMs: Int64
    public let iso: Int?
    public let orientation: Int
    public let shot: String

    public var id: Int { index }

    public init(index: Int, handle: String, takenAtMs: Int64, iso: Int?,
                orientation: Int = 0, shot: String = "") {
        self.index = index
        self.handle = handle
        self.takenAtMs = takenAtMs
        self.iso = iso
        self.orientation = orientation
        self.shot = shot
    }
}

/// 整卷内部记录（对应 Kotlin 的 RollRec）。
public struct RollRecord: Codable, Equatable, Identifiable, Sendable {
    public let rollId: String
    public let filmStockId: String
    public let printStockId: String
    public let createdAtMs: Int64
    public var status: String
    public var frames: [FrameRecord]

    public var id: String { rollId }

    /// FROZEN 公共快照 `RollInfo`。字段顺序是契约的一部分，编码时不要改。
    public var info: RollInfo {
        RollInfo(rollId: rollId,
                 filmStockId: filmStockId,
                 printStockId: printStockId,
                 createdAtMs: createdAtMs,
                 status: status,
                 shotCount: frames.count,
                 frames: frames.map(\.index))
    }

    public init(rollId: String, filmStockId: String, printStockId: String,
                createdAtMs: Int64, status: String = RollContract.statusShooting,
                frames: [FrameRecord] = []) {
        self.rollId = rollId
        self.filmStockId = filmStockId
        self.printStockId = printStockId
        self.createdAtMs = createdAtMs
        self.status = status
        self.frames = frames
    }
}

/// FROZEN 快照：`RollInfo(rollId, filmStockId, printStockId, createdAtMs,
/// status, shotCount, frames)`。字段顺序与 Kotlin 一致，便于机械 diff。
public struct RollInfo: Codable, Equatable, Sendable {
    public let rollId: String
    public let filmStockId: String
    public let printStockId: String
    public let createdAtMs: Int64
    public let status: String
    public let shotCount: Int
    public let frames: [Int]
}

/// 每帧冲洗进度，每完成一帧即落盘。
///
/// iOS 没有 Android `FOREGROUND_SERVICE(dataSync)` 的等价物；后台
/// `BGProcessingTask` 时长不足以跑完 36 张全分辨率渲染。产品口径 =
/// 前台冲洗 + `isIdleTimerDisabled` + 每帧 checkpoint。本类型即 checkpoint，
/// 使 App 被杀后能续冲而不必重渲已完成的帧。
public struct DevelopCheckpoint: Codable, Equatable, Sendable {
    public let rollId: String
    public let filmStockId: String
    public let printStockId: String
    public var completedFrameIndices: [Int]
    public var failedFrameIndex: Int?
    public var lastTier: String?
    public var updatedAt: Date

    public init(rollId: String, filmStockId: String, printStockId: String,
                completedFrameIndices: [Int] = [], failedFrameIndex: Int? = nil,
                lastTier: String? = nil, updatedAt: Date = Date()) {
        self.rollId = rollId
        self.filmStockId = filmStockId
        self.printStockId = printStockId
        self.completedFrameIndices = completedFrameIndices
        self.failedFrameIndex = failedFrameIndex
        self.lastTier = lastTier
        self.updatedAt = updatedAt
    }
}
