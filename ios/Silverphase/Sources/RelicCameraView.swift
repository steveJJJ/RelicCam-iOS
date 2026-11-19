import SwiftUI
import AVFoundation
import UIKit

// MARK: - Relic Cam T3 取景器（阶段 B2 · 完整视觉）
//
// 复用 Silverphase 的相机底座（MobileStillCamera / MobileCameraPreview），
// 但取景层锁定「系统取景」——AVCaptureVideoPreviewLayer 是光学直通，
// 不加任何胶片色 / 颗粒 / 暗角。胶片味只在阶段 C 冲洗后出现。
//
// 拍完不调 developPhoto：capture() 拿到的原片字节直接交给 RelicRollStore
// 存为「未冲洗底片」帧（status=shooting），屏幕只闪一下快门反馈，看不到成片。
// 这是 Relic Cam 的灵魂，不许"顺手优化"成拍完即显影。
//
// 视觉 1:1 参照 Android G:\FilmCam 的 ViewfinderFrameView / T3LcdView / ic_t3_logo.xml
// 与真机截图 play_ready/01_viewfinder_2160x1080.png。
// B2 几何（与 Android contentRectFor/gateRectFor 同源）：
//   · 预览内容：竖屏 3:4 满宽、上下留黑；横屏 4:3 满高、左右留黑。
//   · 片门（成片范围）：135 全画幅 3:2 → 竖持 2:3、横持 3:2，居中落在预览内容里。
//   · 取景亮框画在片门内、再内收一圈；框内即成片（所见即所得）。

struct RelicCameraView: View {
    @Environment(\.scenePhase) private var scenePhase

    let loadedStock: Stock?
    let shotsRemaining: Int
    let shoot: (Data, MobileCaptureFormat) async -> Bool
    let openFilmPicker: () -> Void
    let openDarkroom: () -> Void

    @State private var camera = MobileStillCamera()
    @State private var configuration: MobileCameraConfiguration?
    @State private var previewing = false
    @State private var portraitPreview = true
    @State private var capturing = false
    @State private var shutterFlash = false
    @State private var notice: String?
    @State private var focusLocked = false
    @State private var focusPulse = false      // 对焦成功时绿灯短暂点亮
    @State private var showingDenied = false
    @State private var isPortrait = true

    private let lens: MobileCameraLens = .wide

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let portrait = w <= h
            // 预览内容矩形（3:4 竖 / 4:3 横），与 Android contentRectFor 同源
            let content = RelicGate.contentRect(w: w, h: h)
            // 片门矩形（2:3 竖 / 3:2 横），与 Android gateRectFor 同源
            let gate = RelicGate.gateRect(w: w, h: h)

            ZStack {
                Color.black.ignoresSafeArea()

                // ---- ① 系统取景预览（光学直通，约束到 3:4 / 4:3 内容矩形）----
                if let device = configuration?.device {
                    MobileCameraPreview(camera: camera, device: device,
                                        portrait: $portraitPreview, previewing: $previewing,
                                        mirrored: false, hardwareShutterEnabled: false,
                                        shutter: {}, canAdjustExposure: false,
                                        exposureRotation: 0,
                                        focus: { _, _, lock in
                                            focusLocked = lock
                                            if lock {
                                                focusPulse = true
                                                Task {
                                                    try? await Task.sleep(for: .milliseconds(700))
                                                    focusPulse = false
                                                }
                                            }
                                        }, adjustExposure: { _ in })
                        .id(device.uniqueID)
                        .opacity(previewing ? 1 : 0)
                        .frame(width: content.width, height: content.height)
                        .position(x: content.midX, y: content.midY)
                }

                // ---- ② T3 取景标记层（双层角标 + AF 弧 + 绿灯 + 速度刻度 + 胶卷盒）----
                RelicViewfinderMarks(
                    content: content, gate: gate,
                    portrait: portrait,
                    shutterFlash: shutterFlash,
                    focusLit: focusLocked || focusPulse,
                    filmBrand: loadedStock?.brand ?? "FILM",
                    filmName: loadedStock?.name ?? ""
                )
                .allowsHitTesting(false)

                // ---- ③ 快门反馈白闪 ----
                if shutterFlash {
                    Color.white.opacity(0.28).ignoresSafeArea()
                        .transition(.opacity).allowsHitTesting(false)
                }

                // ---- ④ 顶栏：LCD 信息窗（左）+ DARKROOM 入口（右）----
                VStack {
                    HStack(alignment: .top) {
                        RelicLcdWindow(stockName: loadedStock?.name ?? "NO FILM",
                                       iso: loadedStock?.nominalSpeed,
                                       remaining: shotsRemaining,
                                       flashMode: "OFF", mode: "P")
                        Spacer()
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

                // ---- ⑤ 左侧三旋钮（闪电 / EV / 设置）——装饰性，与真机位一致 ----
                RelicSideKeys(portrait: portrait)
                    .allowsHitTesting(false)

                // ---- ⑥ CONTAX T3 铭牌（取景框下沿、底栏之上）----
                VStack {
                    Spacer()
                    RelicT3Logo(width: portrait ? 132 : 108)
                        .opacity(0.92)
                        .padding(.bottom, portrait ? 118 : 16)
                }
                .allowsHitTesting(false)

                // ---- ⑦ 底栏：胶卷盒 / 快门 / 张数 ----
                VStack {
                    Spacer()
                    if let notice {
                        Text(notice)
                            .font(.system(size: 13)).foregroundColor(.yellow)
                            .padding(.bottom, 6)
                    }
                    HStack(alignment: .center) {
                        Button(action: openFilmPicker) {
                            VStack(spacing: 2) {
                                RelicFilmBox(brand: loadedStock?.brand ?? "FILM",
                                             name: loadedStock?.name ?? "")
                                    .frame(width: 54, height: 54)
                                Text("换卷")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.yellow.opacity(0.85))
                            }
                            .frame(width: 70)
                        }
                        Spacer()
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
            .onAppear { isPortrait = portrait }
            .onChange(of: portrait) { _, v in isPortrait = v }
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

// MARK: - 几何：与 Android ViewfinderFrameView.contentRectFor / gateRectFor 同源
private enum RelicGate {
    // 竖屏预览内容 3:4、横屏 4:3（与 Android CONTENT_ASPECT_PORTRAIT/LANDSCAPE 一致）
    static func contentRect(w: CGFloat, h: CGFloat) -> CGRect {
        guard w > 0, h > 0 else { return .zero }
        let ca: CGFloat = w >= h ? (4.0 / 3.0) : (3.0 / 4.0)
        if w / h <= ca {
            let ch = w / ca
            return CGRect(x: 0, y: (h - ch) / 2, width: w, height: min(ch, h))
        } else {
            let cw = h * ca
            return CGRect(x: (w - cw) / 2, y: 0, width: min(cw, w), height: h)
        }
    }

    // 片门：135 全画幅 3:2 → 竖持 2:3、横持 3:2，居中落在预览内容里
    static func gateRect(w: CGFloat, h: CGFloat) -> CGRect {
        let content = contentRect(w: w, h: h)
        let ca: CGFloat = w >= h ? (3.0 / 2.0) : (2.0 / 3.0)
        let cw = content.width, ch = content.height
        let gw: CGFloat, gh: CGFloat
        if cw / ch >= ca {
            gh = ch; gw = ch * ca
        } else {
            gw = cw; gh = cw / ca
        }
        return CGRect(x: content.midX - gw / 2, y: content.midY - gh / 2, width: gw, height: gh)
    }
}

// MARK: - 取景标记层（双层角标 + AF 弧 + 绿灯 + 速度刻度 + 胶卷盒）
private struct RelicViewfinderMarks: View {
    let content: CGRect
    let gate: CGRect
    let portrait: Bool
    let shutterFlash: Bool
    let focusLit: Bool
    let filmBrand: String
    let filmName: String
    private let speeds = ["500", "125", "30", "LT"]

    var body: some View {
        ZStack {
            let gw = gate.width
            let cx = gate.midX, cy = gate.midY

            // ① 大亮框四角（从片门边缘内收 5.5%，臂长 7.5% 片门宽）
            relicCorners(inset: gw * 0.055, len: gw * 0.075,
                         opacity: 0.82, lineWidth: 2.4)

            // ② 内侧视差小角标（内收 13.5%，臂长 3.5%，略淡）
            relicCorners(inset: gw * 0.135, len: gw * 0.035,
                         opacity: 0.42, lineWidth: 1.6)

            // ③ 中央 AF 弧括号（左右两段弧，非整圆）
            relicAfArc(center: CGPoint(x: cx, y: cy), radius: min(gw, gate.height) * 0.075)

            // ④ 对焦绿色 LED：画面下方居中（与真机 T3 一致），带绿色光晕
            RelicLed(on: focusLit, color: Color(red: 0.47, green: 1.0, blue: 0.55))
                .frame(width: 14, height: 14)
                .position(x: cx, y: gate.maxY - 26)

            // ⑤ 右侧快门速度刻度 500/125/30/LT：按片门高度分布
            VStack(spacing: portrait ? 18 : 14) {
                ForEach(speeds, id: \.self) { s in
                    Text(s)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(s == "125" && shutterFlash
                                         ? Color(red: 0.59, green: 1, blue: 0.67)
                                         : Color.white.opacity(0.45))
                }
            }
            .position(x: content.maxX - (portrait ? 24 : 60), y: content.midY)

            // ⑥ 右下角胶卷盒（当前卷），与 Android tvFilmName 同位
            RelicFilmBox(brand: filmBrand, name: filmName)
                .frame(width: 50, height: 50)
                .position(x: content.maxX - (portrait ? 52 : 92),
                          y: content.maxY - (portrait ? 46 : 30))
        }
    }

    private func relicCorners(inset: CGFloat, len: CGFloat, opacity: CGFloat, lineWidth: CGFloat) -> some View {
        GeometryReader { _ in
            let gl = gate.minX + inset, gt = gate.minY + inset
            let gr = gate.maxX - inset, gb = gate.maxY - inset
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    let isLeft = i % 2 == 0
                    let isTop = i < 2
                    Path { p in
                        let x = isLeft ? gl : gr
                        let y = isTop ? gt : gb
                        let dx: CGFloat = isLeft ? len : -len
                        let dy: CGFloat = isTop ? len : -len
                        p.move(to: CGPoint(x: x + dx, y: y))
                        p.addLine(to: CGPoint(x: x, y: y))
                        p.addLine(to: CGPoint(x: x, y: y + dy))
                    }
                    .stroke(Color.white.opacity(opacity),
                            style: StrokeStyle(lineWidth: lineWidth,
                                               lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func relicAfArc(center: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            // 左弧 "(" 与右弧 ")"
            Path { p in
                p.addArc(center: center, radius: radius,
                         startAngle: .degrees(130), endAngle: .degrees(230), clockwise: false)
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 1.6)
            Path { p in
                p.addArc(center: center, radius: radius,
                         startAngle: .degrees(-50), endAngle: .degrees(50), clockwise: false)
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 1.6)
            Circle().fill(Color.white.opacity(0.75))
                .frame(width: 3, height: 3).position(x: center.x, y: center.y)
        }
    }
}

// MARK: - 绿色 LED（带光晕，常亮=合焦）
private struct RelicLed: View {
    let on: Bool
    let color: Color
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(on ? 0.28 : 0.05))
                .blur(radius: 5)
            Circle().fill(color.opacity(on ? 1.0 : 0.18))
                .overlay(Circle().stroke(Color.white.opacity(on ? 0.7 : 0.15), lineWidth: 1))
        }
        .animation(.easeInOut(duration: 0.15), value: on)
    }
}

// MARK: - LCD 信息窗（仿 Android T3LcdView，浅绿背光）
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

// MARK: - 左侧三旋钮（闪电 / EV / 设置）——装饰，与真机同位
private struct RelicSideKeys: View {
    let portrait: Bool
    var body: some View {
        VStack(spacing: 18) {
            RelicKey(symbol: "bolt.fill")
            RelicKey(text: "EV0")
            RelicKey(symbol: "slider.horizontal.3")
        }
        .position(x: portrait ? 44 : 110,
                  y: (UIScreen.main.bounds.height) * (portrait ? 0.46 : 0.5))
    }
}

private struct RelicKey: View {
    let symbol: String?
    let text: String?
    init(symbol: String) { self.symbol = symbol; self.text = nil }
    init(text: String) { self.symbol = nil; self.text = text }
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.06))
            Circle().stroke(Color.white.opacity(0.28), lineWidth: 1.5)
            if let symbol {
                Image(systemName: symbol).font(.system(size: 18)).foregroundColor(.white.opacity(0.8))
            } else if let text {
                Text(text).font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.8))
            }
        }
        .frame(width: 48, height: 48)
    }
}

// MARK: - 胶卷盒图标（当前卷，彩色盒身）
private struct RelicFilmBox: View {
    let brand: String
    let name: String
    private var tint: Color {
        let s = (brand + name).lowercased()
        if s.contains("gold") { return Color(red: 0.96, green: 0.72, blue: 0.18) }
        if s.contains("portra") { return Color(red: 0.93, green: 0.62, blue: 0.42) }
        if s.contains("tri") || s.contains("bw") || s.contains("negative") { return Color(red: 0.55, green: 0.57, blue: 0.6) }
        if s.contains("ektar") { return Color(red: 0.85, green: 0.42, blue: 0.32) }
        if s.contains("superia") { return Color(red: 0.35, green: 0.62, blue: 0.42) }
        return Color(red: 0.82, green: 0.28, blue: 0.26)
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Color.black)
            RoundedRectangle(cornerRadius: 3).fill(tint).padding(3)
            VStack(spacing: 1) {
                Text(brand.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(name.uppercased())
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(4)
        }
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.5), lineWidth: 1))
        .shadow(radius: 2)
    }
}
