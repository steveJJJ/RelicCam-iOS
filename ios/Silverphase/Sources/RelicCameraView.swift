import SwiftUI
import AVFoundation
import UIKit

// MARK: - Relic Cam T3 取景器（阶段 B1）
//
// 复用 Silverphase 的相机底座（MobileStillCamera / MobileCameraPreview），
// 但取景层锁定「系统取景」——AVCaptureVideoPreviewLayer 是光学直通，
// 不加任何胶片色 / 颗粒 / 暗角。胶片味只在阶段 C 冲洗后出现。
//
// 拍完不调 developPhoto：capture() 拿到的原片字节直接交给 RelicRollStore
// 存为「未冲洗底片」帧（status=shooting），屏幕只闪一下快门反馈，看不到成片。
// 这是 Relic Cam 的灵魂，不许"顺手优化"成拍完即显影。
//
// 视觉 1:1 参照 Android G:\FilmCam 的 T3LcdView / ViewfinderFrameView 与真机截图。

struct RelicCameraView: View {
    @Environment(\.scenePhase) private var scenePhase

    /// 当前装着的胶卷（filmStockId 字符串，胶卷目录复用 Silverphase StockCatalog）
    let loadedStock: Stock?
    /// 当前卷剩余张数（0...36）
    let shotsRemaining: Int
    /// 快门按下：把原片交给存储层存为未冲洗底片。返回是否写入成功。
    let shoot: (Data, MobileCaptureFormat) async -> Bool
    /// 打开装卷选择器
    let openFilmPicker: () -> Void
    /// 进入暗房
    let openDarkroom: () -> Void

    @State private var camera = MobileStillCamera()
    @State private var configuration: MobileCameraConfiguration?
    @State private var previewing = false
    @State private var portraitPreview = true
    @State private var capturing = false
    @State private var shutterFlash = false
    @State private var notice: String?
    @State private var focusPoint: CGPoint?
    @State private var focusLocked = false
    @State private var showingDenied = false

    private let lens: MobileCameraLens = .wide

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // ---- 系统取景预览（光学直通，不上色）----
                if let device = configuration?.device {
                    MobileCameraPreview(camera: camera, device: device,
                                        portrait: $portraitPreview, previewing: $previewing,
                                        mirrored: false, hardwareShutterEnabled: false,
                                        shutter: {}, canAdjustExposure: false,
                                        exposureRotation: 0,
                                        focus: { point, _, lock in
                                            focusPoint = point
                                            focusLocked = lock
                                            camera.focus(at: point, lens: lens, lock: lock)
                                        }, adjustExposure: { _ in })
                        .id(device.uniqueID)
                        .opacity(previewing ? 1 : 0)
                        .ignoresSafeArea()
                }

                // ---- T3 取景框标记（四角 + 对焦环 + 速度刻度）----
                RelicViewfinderMarks(shutterFlash: shutterFlash)
                    .allowsHitTesting(false)

                // ---- 快门反馈白闪 ----
                if shutterFlash {
                    Color.white.opacity(0.28).ignoresSafeArea()
                        .transition(.opacity).allowsHitTesting(false)
                }

                // ---- LCD 信息窗（左上）----
                VStack {
                    HStack {
                        RelicLcdWindow(stockName: loadedStock?.name ?? "NO FILM",
                                       iso: loadedStock?.nominalSpeed,
                                       remaining: shotsRemaining,
                                       flashMode: "OFF",
                                       mode: "P")
                        Spacer()
                        // DARKROOM 入口（右上）
                        Button(action: openDarkroom) {
                            Text("DARKROOM")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.red.opacity(0.9))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.black.opacity(0.35))
                                .cornerRadius(4)
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 10)
                    Spacer()
                }
                .allowsHitTesting(true)

                // ---- 底部：胶片按钮 / 快门 / 装卷提示 ----
                VStack {
                    Spacer()
                    if let notice {
                        Text(notice)
                            .font(.system(size: 13)).foregroundColor(.yellow)
                            .padding(.bottom, 6)
                    }
                    HStack(alignment: .center) {
                        // 胶卷图标（点开装卷）
                        Button(action: openFilmPicker) {
                            VStack(spacing: 2) {
                                Image(systemName: "film")
                                    .font(.system(size: 26))
                                    .foregroundColor(.yellow)
                                Text(loadedStock?.brand ?? "FILM")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.yellow.opacity(0.85))
                            }
                            .frame(width: 70)
                        }
                        Spacer()
                        // 圆形快门
                        Button(action: { Task { await takePhoto() } }) {
                            ZStack {
                                Circle().fill(Color.black.opacity(0.35))
                                    .frame(width: 84, height: 84)
                                Circle().stroke(Color.white.opacity(0.85), lineWidth: 4)
                                    .frame(width: 76, height: 76)
                                Circle().fill(Color.white.opacity(capturing ? 0.35 : 0.9))
                                    .frame(width: 62, height: 62)
                            }
                        }
                        .disabled(capturing || loadedStock == nil || shotsRemaining <= 0)
                        .opacity(loadedStock == nil || shotsRemaining <= 0 ? 0.4 : 1)
                        Spacer()
                        // 剩余张数
                        VStack(spacing: 2) {
                            Text("\(shotsRemaining)")
                                .font(.system(size: 26, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Text("/ 36")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .frame(width: 70)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 26)
                }
                .allowsHitTesting(true)
            }
        }
        .task { await startCamera() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await startCamera() } }
            else if phase == .background { camera.stop() }
        }
        .onDisappear { camera.stop() }
        .alert("相机权限未开启", isPresented: $showingDenied) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("需要在系统设置里允许使用相机。")
        }
    }

    private func takePhoto() async {
        guard !capturing, let stock = loadedStock, shotsRemaining > 0 else { return }
        capturing = true
        defer { capturing = false }
        do {
            let result = try await camera.capture(lens: lens, flash: .off, portrait: false, mirrored: false)
            let ok = await shoot(result.data, result.format)
            withAnimation(.easeOut(duration: 0.12)) { shutterFlash = true }
            Task {
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(.easeIn(duration: 0.22)) { shutterFlash = false }
            }
            notice = ok ? "已装入未冲洗底片 · \(stock.brand)" : "底片已满或写入失败"
        } catch {
            notice = "拍摄失败：\(error.localizedDescription)"
        }
    }

    private func startCamera() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                showingDenied = true; return
            }
        case .denied, .restricted:
            showingDenied = true; return
        default: break
        }
        guard configuration == nil else { return }
        do {
            let pref = RelicCaptureOptions()
            configuration = try await camera.start(lens: lens, portrait: false,
                                                   prefersRAW: pref.rawNegativeEnabled,
                                                   prefers12MP: true)
        } catch {
            notice = "相机启动失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 取景框标记（仿 Android ViewfinderFrameView）
private struct RelicViewfinderMarks: View {
    let shutterFlash: Bool
    private let speeds = ["500", "125", "30", "LT"]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let boxW = min(w * 0.78, h * 0.58)
            let boxH = boxW * 0.67
            let cx = w / 2, cy = h * 0.46
            ZStack {
                // 四角 L 形亮框
                ForEach(0..<4, id: \.self) { i in
                    let isLeft = i % 2 == 0
                    let isTop = i < 2
                    Path { p in
                        let x = cx + (isLeft ? -boxW/2 : boxW/2)
                        let y = cy + (isTop ? -boxH/2 : boxH/2)
                        let len: CGFloat = 22
                        let dx: CGFloat = isLeft ? len : -len
                        let dy: CGFloat = isTop ? len : -len
                        p.move(to: CGPoint(x: x + dx, y: y))
                        p.addLine(to: CGPoint(x: x, y: y))
                        p.addLine(to: CGPoint(x: x, y: y + dy))
                    }
                    .stroke(Color.white.opacity(0.82), lineWidth: 2)
                }
                // 中央对焦环
                Circle().stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                    .frame(width: 46, height: 46).position(x: cx, y: cy)
                Circle().fill(Color.white.opacity(0.75))
                    .frame(width: 3, height: 3).position(x: cx, y: cy)
                // 右侧快门速度刻度 500/125/30/LT
                VStack(spacing: 14) {
                    ForEach(speeds, id: \.self) { s in
                        Text(s)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(s == "125" && shutterFlash
                                             ? Color(red: 0.59, green: 1, blue: 0.67)
                                             : Color.white.opacity(0.45))
                    }
                }
                .position(x: w - 26, y: cy)
            }
        }
    }
}

// MARK: - LCD 信息窗（仿 Android T3LcdView）
private struct RelicLcdWindow: View {
    let stockName: String
    let iso: Int?
    let remaining: Int
    let flashMode: String
    let mode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.slash.fill")
                    .font(.system(size: 11)).foregroundColor(Color.black.opacity(0.75))
                Text(flashMode)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Image(systemName: "battery.100")
                    .font(.system(size: 12)).foregroundColor(Color.black.opacity(0.7))
            }
            Text(stockName.uppercased())
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .lineLimit(1)
            HStack(spacing: 8) {
                Text("ISO \(iso.map(String.init) ?? "—")")
                Text("R \(remaining)")
                Spacer()
                Text(mode).fontWeight(.bold)
            }
            .font(.system(size: 10, design: .monospaced))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(width: 168)
        .background(
            LinearGradient(colors: [Color(red: 0.757, green: 0.784, blue: 0.721),
                                    Color(red: 0.627, green: 0.663, blue: 0.596)],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color(red: 0.29, green: 0.30, blue: 0.33), lineWidth: 1)
        )
        .foregroundColor(Color.black.opacity(0.82))
        .cornerRadius(3)
        .shadow(radius: 2)
    }
}
