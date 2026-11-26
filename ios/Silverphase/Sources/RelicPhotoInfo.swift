import Foundation
import SwiftUI
import UIKit
import ImageIO

// MARK: - 成片信息面板（阶段 C18）
//
// 对齐安卓 PhotoViewerActivity 的信息入口：点大图看胶卷 / 拍摄参数 / 冲洗参数，
// 并可分享原片、用同款胶卷再拍一卷。
//
// 数据来源优先级：
//   1) 带框成片里的 EXIF（C16 写入 UserComment JSON / ISO / LensModel）；
//   2) 卷记录 RollRecord / FrameRecord（覆盖安装后的旧成片没有 EXIF 的情况）。
// 只读 metadata、不解码全尺寸图，13 mini 上不会因看信息而吃爆内存。

struct RelicPhotoInfo {
    let filmName: String
    let filmID: String
    let printName: String
    let iso: String
    let taken: String
    let frame: String
    let frameStyle: String
    let dateImprint: String
    let aperture: String
    let focalLength: String

    static func load(url: URL, roll: RollRecord?, frameIndex: Int) -> RelicPhotoInfo {
        var user: [String: Any] = [:]
        var tiff: [String: Any] = [:]
        var exif: [String: Any] = [:]
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            if let comment = exif[kCGImagePropertyExifUserComment as String] as? String,
               let data = comment.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                user = json
            }
        }

        let frame = roll?.frames.first { $0.index == frameIndex }

        // 胶卷名：EXIF UserComment.film_name → LensModel → 卷记录 id → 目录名
        let filmID = user["film"] as? String ?? roll?.filmStockId ?? ""
        let filmName = user["film_name"] as? String
            ?? exif["LensModel"] as? String
            ?? StockCatalog.shared.stock(filmID)?.name
            ?? filmID
        let printID = user["print"] as? String ?? roll?.printStockId ?? ""
        let printName = StockCatalog.shared.stock(printID)?.name ?? printID

        let isoValue = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
            ?? frame?.iso
        let isoText: String
        if let isoValue, isoValue > 0 {
            isoText = "ISO \(isoValue)"
        } else {
            isoText = "自动"
        }

        // 拍摄时刻：EXIF 里 DateTimeOriginal 存的是成片生成时刻（系统相册排序用），
        // 真正按快门的时刻在 UserComment.orig_taken_at_text / orig_taken_at。
        let takenText = user["orig_taken_at_text"] as? String
            ?? formatTime(frame?.takenAtMs)
            ?? "—"

        let frameNo: String
        if let f = frame {
            frameNo = "第 \(f.index + 1) 张"
        } else {
            frameNo = "第 \(frameIndex + 1) 张"
        }

        let styleValue = user["frame_style"] as? Int ?? RelicFrameSettings.style.rawValue
        let styleText = RelicFrameStyle(rawValue: styleValue)?.label ?? "白边"
        let dateText = (user["date_imprint"] as? Bool ?? RelicFrameSettings.dateOn) ? "开" : "关"

        // EXIF 里的光圈/焦距是 T3 模拟值（C16 writeWithExif 固定写入）。
        let aperture = (exif[kCGImagePropertyExifFNumber as String] as? Double)
            .flatMap { "f/\(formatNumber($0))" } ?? "f/2.8"
        let focal = (exif[kCGImagePropertyExifFocalLength as String] as? Double)
            .flatMap { "\(formatNumber($0)) mm" } ?? "35 mm"

        return RelicPhotoInfo(filmName: filmName, filmID: filmID,
                              printName: printName, iso: isoText, taken: takenText,
                              frame: frameNo, frameStyle: styleText, dateImprint: dateText,
                              aperture: aperture, focalLength: focal)
    }

    private static func formatTime(_ ms: Int64?) -> String? {
        guard let ms else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }

    private static func formatNumber(_ v: Double) -> String {
        if v.rounded() == v { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }
}

/// 成片信息面板。三段：胶卷 / 拍摄 / 成片处理，底部分享与拍摄同款。
@MainActor
struct RelicPhotoInfoSheet: View {
    let info: RelicPhotoInfo
    let onShare: () -> Void
    let onShootSame: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("胶卷") {
                    LabeledContent("胶卷", value: info.filmName)
                    LabeledContent("感光度", value: info.iso)
                    LabeledContent("相纸", value: info.printName)
                }
                Section("拍摄") {
                    LabeledContent("拍摄于", value: info.taken)
                    LabeledContent("帧号", value: info.frame)
                    LabeledContent("光圈", value: info.aperture)
                    LabeledContent("焦距", value: info.focalLength)
                }
                Section("成片处理") {
                    LabeledContent("相框", value: info.frameStyle)
                    LabeledContent("日期戳", value: info.dateImprint)
                }
                Section {
                    Button {
                        onShare()
                    } label: {
                        Label("分享成片", systemImage: "square.and.arrow.up")
                    }
                    .foregroundColor(.yellow)
                    Button {
                        onDone()
                        onShootSame()
                    } label: {
                        Label("用同款胶卷拍摄", systemImage: "camera")
                    }
                    .foregroundColor(.yellow)
                } footer: {
                    Text("分享的是带相框的原始成片；拍摄同款会装上新的一卷并回到相机。")
                        .font(.system(size: 11))
                }
            }
            .navigationTitle("照片信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onDone).foregroundColor(.yellow)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 系统分享表：分享带框成片原图。
@MainActor
struct RelicShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
