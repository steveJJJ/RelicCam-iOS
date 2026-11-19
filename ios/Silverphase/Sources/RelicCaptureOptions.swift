import Foundation

// MARK: - Pro / 工程师模式能力位（阶段 A）
//
// 1:1 对齐 Android vc74 的工程师控制台（MainActivity.kt + Camera2Controller.kt +
// dialog_slow_shutter.xml + ProManager.kt 取证，2026-11-20）。
//
// 注意：Android 的 "Pro" 不是手动拍照档位，而是「工程师模式」：
//   - 慢门曝光模型（关 / 自然 / 偏慢）+ 触发机制（概率 / 真实 / 真实+轻随机）
//   - RAW 负片：快门同时收 16bit Bayer DNG 作底片，冲洗走 RAW 会话
//   - 镜头柔焦（Sonnar 在底片上的柔度，机身属性）
//   - 输出风格、冲洗参数（颗粒/曝光/曝光补偿/银盐，按胶卷分别存）
//   - 调试：跳过冲洗立即出片、模拟失焦概率
//
// 阶段 A 只冻结数据契约 + 落盘，不接相机/冲洗。阶段 B 接拍摄链路、
// 阶段 C 接冲洗链路时直接消费这些字段。全部 Sendable（严格并发）。

/// 慢门档位（胶片曝光模型）：决定暗光下"糊一下"的基准概率。
public enum RelicSlowShutterMode: String, Codable, Sendable, CaseIterable {
    case off = "off"          /// 关
    case natural = "natural"  /// 自然
    case slow = "slow"        /// 偏慢
}

/// 慢门触发机制。
public enum RelicSlowShutterTrigger: String, Codable, Sendable, CaseIterable {
    case probability = "prob"  /// 纯概率
    case real = "real"         /// 纯真实长曝光
    case mixed = "mixed"       /// 真实 + 轻随机
}

/// 输出风格（工程师控制台：放大机 / 相纸 / Frontier 扫描）。
public enum RelicOutputStyle: String, Codable, Sendable, CaseIterable {
    case enlarger = "enlarger"
    case paper = "paper"
    case frontierScan = "frontier_scan"
}

/// 冲洗参数，按胶卷分别存（Android 口径：颗粒/曝光/曝光补偿/银盐）。
public struct RelicDevelopParams: Codable, Equatable, Sendable {
    public var grain: Double = 0.0
    public var exposure: Double = 0.0
    public var exposureCompensation: Double = 0.0
    public var silver: Double = 0.0

    public init(grain: Double = 0.0, exposure: Double = 0.0,
                exposureCompensation: Double = 0.0, silver: Double = 0.0) {
        self.grain = grain
        self.exposure = exposure
        self.exposureCompensation = exposureCompensation
        self.silver = silver
    }
}

/// 工程师模式的完整可持久化状态。默认值 = 普通用户的出厂口径。
public struct RelicCaptureOptions: Codable, Equatable, Sendable {
    public var slowShutterMode: RelicSlowShutterMode = .natural
    public var slowShutterTrigger: RelicSlowShutterTrigger = .mixed
    public var rawNegativeEnabled: Bool = false
    public var softFocusMicrons: Int = 12
    /// 0 = 关闭（Android vc89+ 新装缺省 2%，工程师滑杆 0–100）
    public var softFocusProb: Int = 2
    public var outputStyle: RelicOutputStyle = .frontierScan
    /// 调试开关：跳过冲洗立即出片。普通用户不碰。
    public var skipDevelopForDebug: Bool = false
    /// 按胶卷 id 分别存的冲洗参数。
    public var developParamsByFilm: [String: RelicDevelopParams] = [:]

    public init() {}

    public func developParams(for filmStockId: String) -> RelicDevelopParams {
        developParamsByFilm[filmStockId] ?? RelicDevelopParams()
    }
}
