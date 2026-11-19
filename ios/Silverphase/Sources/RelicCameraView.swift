import SwiftUI
import AVFoundation
import UIKit

// MARK: - Relic Cam T3 取景器（阶段 B3 · 按安卓真机逐项对齐）
//
// 复用 Silverphase 相机底座，取景层锁定「系统取景」——AVCaptureVideoPreviewLayer
// 光学直通，不加任何胶片色。拍完 capture() 原片直接存未冲洗底片，绝不 develop。
//
// B3 修正（对照 G:\FilmCam 的 activity_main.xml / layout-land / ViewfinderFrameView /
// T3LcdView / defaults_01_home.png / 01_viewfinder_2160x1080.png）：
//   ① 三功能键：竖屏右上横排（与 LCD 同行）；横屏左侧竖排。
//   ② 暗房：竖屏底栏右（金属蚀刻字牌）；横屏右侧栏顶。
//   ③ 绿灯：内容底边 cb-5.5%ch、片门水平居中、常亮/4Hz/1Hz 三态 + 8s 熄灭。
//   ④ 快门档：内容右缘内收 7.5%cw、从 30%h 起每档 12%h、2Hz/4Hz 闪。
//   ⑤ 动画：指示灯 8s 淡出、LED/快门闪烁、LCD EL 背光淡出、过卷动画。
//   ⑥ LCD：反射式 TN + 右侧七段计数 + 闪电 + AF 眼 + ISO/EV/模式/电池。

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
    @State private var noticeUntil = Date.distantPast
    @State private var showingDenied = false

    // 取景器交互状态（驱动指示灯闪烁 / 自动熄灭）
    @State private var lastActivityAt = Date()
    @State private var focusLocked = false
    @State private var focusMode = 0          // 0=OFF 1=ON(合焦) 2=FAST(失焦) 3=SLOW(AFL)
    @State private var backlightUntil = Date.distantPast
    @State private var advancing = false      // 过卷动画

    private let lens: MobileCameraLens = .wide
    private let maxShots = 36

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let portrait = w <= h
            let content = RelicGate.contentRect(w: w, h: h)
            let gate = RelicGate.gateRect(w: w, h: h)
            let shotsTaken = max(0, maxShots - shotsRemaining)

            ZStack {
                Color.black.ignoresSafeArea()

                // ---- ① 系统取景预览（光学直通，3:4 竖 / 4:3 横内容矩形）----
                if let device = configuration?.device {
                    MobileCameraPreview(camera: camera, device: device,
                                        portrait: $portraitPreview, previewing: $previewing,
                                        mirrored: false, hardwareShutterEnabled: false,
                                        shutter: {}, canAdjustExposure: false,
                                        exposureRotation: 0,
                                        focus: { _, _, lock in
                                            lastActivityAt = Date()
                                            focusLocked = lock
                                            if lock {
                                                focusMode = 1
                                                Task {
                                                    try? await Task.sleep(for: .milliseconds(900))
                                                    focusMode = 3
                                                }
                                            } else {
                                                focusMode = 2
                                                Task {
                                                    try? await Task.sleep(for: .milliseconds(400))
                                                    if !focusLocked { focusMode = 0 }
                                                }
                                            }
                                        }, adjustExposure: { _ in })
                        .id(device.uniqueID)
                        .opacity(previewing ? 1 : 0)
                        .frame(width: content.width, height: content.height)
                        .position(x: content.midX, y: content.midY)
                }

                // ---- ② 取景标记层（由 TimelineView 驱动闪烁/熄灭，纯变换不建 UIKit）----
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    RelicViewfinderMarks(
                        content: content, gate: gate, portrait: portrait,
                        now: timeline.date, lastActivityAt: lastActivityAt,
                        focusMode: focusMode, shutterFlash: shutterFlash,
                        filmBrand: loadedStock?.brand ?? "FILM",
                        filmName: loadedStock?.name ?? ""
                    )
                    .allowsHitTesting(false)
                }

                // ---- ③ 快门反馈白闪 ----
                if shutterFlash {
                    Color.white.opacity(0.22).ignoresSafeArea()
                        .transition(.opacity).allowsHitTesting(false)
                }

                // ---- ④ 机身控制层 ----
                if portrait {
                    // 竖屏：顶栏 LCD(左) + 三键(右横排)；底栏 胶卷/快门/暗房
                    VStack {
                        HStack(alignment: .center, spacing: 0) {
                            RelicLcdPanel(
                                count: shotsTaken, isoLabel: isoLabel,
                                evSteps: 0, flashLabel: "OFF", mode: "P",
                                battery: 3,
                                backlightUntil: backlightUntil,
                                message: notice, messageUntil: noticeUntil
                            )
                            .frame(width: 172, height: 64)
                            Spacer(minLength: 0)
                            RelicFunctionKeys(axis: .horizontal, onPress: pressKey)
                        }
                        .padding(.horizontal, 14).padding(.top, 16)
                        Spacer()
                    }
                    .allowsHitTesting(true)

                    // CONTAX T3 铭牌：取景框下沿与底栏之间（安卓 marginBottom 150dp）
                    VStack {
                        Spacer()
                        RelicT3Logo(width: 128)
                            .opacity(0.92)
                            .padding(.bottom, 134)
                    }
                    .allowsHitTesting(false)

                    VStack {
                        Spacer()
                        RelicBottomBar(
                            filmBrand: loadedStock?.brand ?? "FILM",
                            filmName: loadedStock?.name ?? "",
                            capturing: capturing,
                            enabled: loadedStock != nil && shotsRemaining > 0,
                            notice: activeMessage,
                            onFilm: { lastActivityAt = Date(); openFilmPicker() },
                            onShutter: { Task { await takePhoto() } },
                            onDarkroom: { lastActivityAt = Date(); openDarkroom() }
                        )
                    }
                    .allowsHitTesting(true)
                } else {
                    // 横屏：左侧栏 LCD + 三键竖排 + 铭牌；右侧栏 暗房/快门/胶卷
                    HStack(spacing: 0) {
                        VStack(alignment: .center, spacing: 0) {
                            RelicLcdPanel(
                                count: shotsTaken, isoLabel: isoLabel,
                                evSteps: 0, flashLabel: "OFF", mode: "P",
                                battery: 3,
                                backlightUntil: backlightUntil,
                                message: notice, messageUntil: noticeUntil
                            )
                            .frame(width: 148, height: 56)
                            RelicFunctionKeys(axis: .vertical, onPress: pressKey)
                                .padding(.top, 14)
                            RelicT3Logo(width: 118)
                                .opacity(0.92)
                                .padding(.top, 14)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 16)
                        .allowsHitTesting(true)
                        Spacer(minLength: 0)
                        VStack(alignment: .center, spacing: 0) {
                            Spacer(minLength: 0)
                            RelicDarkroomPlate {
                                lastActivityAt = Date(); openDarkroom()
                            }
                            RelicShutterButton(capturing: capturing,
                                               enabled: loadedStock != nil && shotsRemaining > 0) {
                                Task { await takePhoto() }
                            }
                            .padding(.vertical, 56)
                            RelicFilmBox(brand: loadedStock?.brand ?? "FILM",
                                         name: loadedStock?.name ?? "")
                                .frame(width: 56, height: 56)
                                .onTapGesture { lastActivityAt = Date(); openFilmPicker() }
                            Spacer(minLength: 0)
                        }
                        .padding(.trailing, 40)
                        .allowsHitTesting(true)
                    }
                }

                // ---- ⑤ 过卷动画（拍完黑底胶卷前进，看不到成片）----
                if advancing {
                    RelicFilmAdvanceOverlay()
                        .transition(.opacity).allowsHitTesting(false)
                }
            }
        }
        .task { await startCamera() }
        .onAppear { backlightUntil = Date().addingTimeInterval(1.2) }
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

    // MARK: - 状态派生
    private var isoLabel: String {
        loadedStock?.nominalSpeed.map(String.init) ?? "A"
    }

    private var activeMessage: String? {
        Date() < noticeUntil ? notice : nil
    }

    private func pressKey() {
        lastActivityAt = Date()
        backlightUntil = Date().addingTimeInterval(4.0)
    }

    private func setNotice(_ text: String) {
        notice = text
        noticeUntil = Date().addingTimeInterval(3.2)
        backlightUntil = Date().addingTimeInterval(3.2)
    }

    // MARK: - 拍照：存未冲洗底片，绝不显影
    private func takePhoto() async {
        guard !capturing, let stock = loadedStock, shotsRemaining > 0 else { return }
        capturing = true
        lastActivityAt = Date()
        defer { capturing = false }
        do {
            let result = try await camera.capture(lens: lens, flash: .off, portrait: false, mirrored: false)
            let ok = await shoot(result.data, result.format)
            withAnimation(.easeOut(duration: 0.12)) { shutterFlash = true }
            withAnimation(.easeIn(duration: 0.25)) { advancing = true }
            Task {
                try? await Task.sleep(for: .milliseconds(170))
                withAnimation(.easeIn(duration: 0.22)) { shutterFlash = false }
                try? await Task.sleep(for: .milliseconds(750))
                withAnimation(.easeOut(duration: 0.35)) { advancing = false }
            }
            setNotice(ok ? "已装入未冲洗底片 · \(stock.brand)" : "底片已满或写入失败")
        } catch {
            setNotice("拍摄失败：\(error.localizedDescription)")
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
            setNotice("相机启动失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 几何：与 Android ViewfinderFrameView.contentRectFor / gateRectFor 同源
private enum RelicGate {
    static func contentRect(w: CGFloat, h: CGFloat) -> CGRect {
        guard w > 0, h > 0 else { return .zero }
        let ca: CGFloat = w >= h ? (4.0 / 3.0) : (3.0 / 4.0)
        if w / h <= ca {
            let ch = w / ca
            let cy = h / 2 + (-0.06) * ch     // Android PREVIEW_OFFSET_Y
            return CGRect(x: 0, y: max(0, cy - ch / 2), width: w, height: min(ch, h))
        } else {
            let cw = h * ca
            return CGRect(x: (w - cw) / 2, y: 0, width: min(cw, w), height: h)
        }
    }

    static func gateRect(w: CGFloat, h: CGFloat) -> CGRect {
        let content = contentRect(w: w, h: h)
        let ca: CGFloat = w >= h ? (3.0 / 2.0) : (2.0 / 3.0)
        let cw = content.width, ch = content.height
        let gw: CGFloat, gh: CGFloat
        if cw / ch >= ca { gh = ch; gw = ch * ca }
        else { gw = cw; gh = cw / ca }
        return CGRect(x: content.midX - gw / 2, y: content.midY - gh / 2, width: gw, height: gh)
    }
}

// MARK: - 取景标记层
private struct RelicViewfinderMarks: View {
    let content: CGRect
    let gate: CGRect
    let portrait: Bool
    let now: Date
    let lastActivityAt: Date
    let focusMode: Int
    let shutterFlash: Bool
    let filmBrand: String
    let filmName: String
    private let speeds = ["500", "125", "30", "LT"]

    var body: some View {
        ZStack {
            let gw = gate.width
            let cx = gate.midX, cy = gate.midY

            // ① 大亮框角标（片门内收 5.5%，臂长 7.5%）
            relicCorners(inset: gw * 0.055, len: gw * 0.075, opacity: 0.82, lineWidth: 2.4)
            // ② 视差小角标（内收 13.5%，臂长 3.5%）
            relicCorners(inset: gw * 0.135, len: gw * 0.035, opacity: 0.42, lineWidth: 1.6)
            // ③ 中央 AF 弧（半径 min(gw,gh)*5.5%，左右各 140°，上下留 40° 缺口）
            relicAfArc(center: CGPoint(x: cx, y: cy), radius: min(gw, gate.height) * 0.055)

            // 条件显示：8 秒无操作后 1.2 秒淡出（与 Android indicatorsAlpha 一致）
            let idle = now.timeIntervalSince(lastActivityAt)
            let alpha: CGFloat = idle < 8 ? 1
                : (idle < 9.2 ? CGFloat(1 - (idle - 8) / 1.2) : 0)

            if alpha > 0 {
                // ⑥ 绿灯：内容底边 cb-5.5%ch、片门水平居中
                RelicLed(on: relicLedOn(focusMode, now: now), alpha: alpha,
                         radius: min(content.width, content.height) * 0.032)
                    .position(x: cx, y: content.maxY - content.height * 0.055)

                // ⑧ 快门速度档：右缘内收 7.5%cw，从 30%h 起每档 12%h
                let scaleX = content.maxX - content.width * 0.075
                let size = min(content.height * 0.036, 13)
                let t = now.timeIntervalSinceReferenceDate
                let blinking = Int(t / 0.125) % 2 == 0     // 4Hz
                ForEach(Array(speeds.enumerated()), id: \.offset) { idx, s in
                    let lit = s == "125" || s == "30"
                    let on = lit && (shutterFlash || blinking || s == "125")
                    Text(s)
                        .font(.system(size: size, weight: .bold, design: .monospaced))
                        .foregroundColor(lit
                            ? Color(red: 0.59, green: 1, blue: 0.67).opacity(alpha * (on ? 0.92 : 0.28))
                            : Color.white.opacity(alpha * 0.19))
                        .frame(width: 42, alignment: .trailing)
                        .position(x: scaleX - 21,
                                  y: content.minY + content.height * (0.30 + 0.12 * CGFloat(idx)))
                }
            }

            // 胶卷盒厂商字标（取景窗右下角，安卓 tvFilmName 在底栏——此处仅保留轻微提示）
            // 底栏已有胶卷盒，取景窗内不再重复，避免与安卓观感分叉。
            let _ = filmBrand
            let _ = filmName
        }
    }

    private func relicLedOn(_ mode: Int, now: Date) -> Bool {
        let t = now.timeIntervalSinceReferenceDate
        switch mode {
        case 1: return true                          // 常亮 = 合焦
        case 2: return Int(t / 0.125) % 2 == 0       // 4Hz = 失焦
        case 3: return Int(t / 0.5) % 2 == 0         // 1Hz = AFL 锁定
        default: return false
        }
    }

    private func relicCorners(inset: CGFloat, len: CGFloat, opacity: CGFloat, lineWidth: CGFloat) -> some View {
        let gl = gate.minX + inset, gt = gate.minY + inset
        let gr = gate.maxX - inset, gb = gate.maxY - inset
        return ZStack {
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
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func relicAfArc(center: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            Path { p in
                p.addArc(center: center, radius: radius,
                         startAngle: .degrees(110), endAngle: .degrees(250), clockwise: false)
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 1.6)
            Path { p in
                p.addArc(center: center, radius: radius,
                         startAngle: .degrees(-70), endAngle: .degrees(70), clockwise: false)
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 1.6)
        }
    }
}

// MARK: - 绿色对焦 LED（光晕 + 白核，三态闪烁）
private struct RelicLed: View {
    let on: Bool
    let alpha: CGFloat
    let radius: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.47, green: 1.0, blue: 0.55).opacity((on ? 0.38 : 0) * alpha))
                .frame(width: radius * 5.6, height: radius * 5.6)
                .blur(radius: radius * 1.6)
            Circle().fill(Color(red: 0.47, green: 1.0, blue: 0.55).opacity((on ? 0.94 : 0.14) * alpha))
                .frame(width: radius * 0.8, height: radius * 0.8)
            Circle().fill(Color.white.opacity((on ? 0.9 : 0) * alpha))
                .frame(width: radius * 0.34, height: radius * 0.34)
        }
    }
}

// MARK: - 顶栏三功能键（闪光灯 / EV / 设置）
private enum RelicKeyAxis { case horizontal, vertical }

private struct RelicFunctionKeys: View {
    let axis: RelicKeyAxis
    let onPress: () -> Void

    var body: some View {
        Group {
            if axis == .horizontal {
                HStack(spacing: 24) { keys }
            } else {
                VStack(spacing: 14) { keys }
            }
        }
    }

    private var keys: some View {
        ForEach(0..<3, id: \.self) { i in
            Button(action: onPress) { RelicKey(kind: i) }
                .buttonStyle(.plain)
                .frame(width: 48, height: 48)
        }
    }
}

private struct RelicKey: View {
    let kind: Int
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: 0x74787F), Color(hex: 0x2C3036),
                                                  Color(hex: 0x565A61)],
                                         startPoint: .top, endPoint: .bottom))
            Circle().fill(Color(hex: 0x24262A)).padding(3)
            Circle().stroke(Color(hex: 0x0E1013), lineWidth: 0.5).padding(3)
            switch kind {
            case 0:   // 闪电
                Path { p in
                    p.move(to: CGPoint(x: 13.6, y: 2)); p.addLine(to: CGPoint(x: 5.8, y: 13.6))
                    p.addLine(to: CGPoint(x: 10.5, y: 13.6)); p.addLine(to: CGPoint(x: 8.9, y: 22))
                    p.addLine(to: CGPoint(x: 18.2, y: 9.4)); p.addLine(to: CGPoint(x: 13.3, y: 9.4))
                    p.addLine(to: CGPoint(x: 13.6, y: 2)); p.closeSubpath()
                }
                .scaleEffect(0.62).frame(width: 24, height: 24)
                .foregroundColor(Color(hex: 0xDCDCE0))
            case 1:   // EV
                Text("EV0").font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: 0xDCDCE0))
            default:  // 设置（三条滑杆）
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        ZStack {
                            Capsule().fill(Color(hex: 0xDCDCE0)).frame(width: 18, height: 1.5)
                            Circle().fill(Color(hex: 0xDCDCE0)).frame(width: 4, height: 4)
                                .offset(x: 4)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 底栏：胶卷盒 / 快门 / 暗房（竖屏，安卓 bottomBar）
private struct RelicBottomBar: View {
    let filmBrand: String
    let filmName: String
    let capturing: Bool
    let enabled: Bool
    let notice: String?
    let onFilm: () -> Void
    let onShutter: () -> Void
    let onDarkroom: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if let notice {
                Text(notice)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(red: 0.82, green: 0.86, blue: 0.62))
                    .lineLimit(1)
            }
            HStack(alignment: .center, spacing: 0) {
                RelicFilmBox(brand: filmBrand, name: filmName)
                    .frame(width: 56, height: 56)
                    .onTapGesture(perform: onFilm)
                Spacer().frame(width: 56)
                RelicShutterButton(capturing: capturing, enabled: enabled, action: onShutter)
                Spacer().frame(width: 56)
                RelicDarkroomPlate(action: onDarkroom)
            }
        }
        .padding(.bottom, 48)
    }
}

// MARK: - 快门钮（哑光黑盘 + 金属倒角外圈，仿 bg_shutter）
private struct RelicShutterButton: View {
    let capturing: Bool
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(hex: 0x74787F), Color(hex: 0x2C3036),
                                                      Color(hex: 0x565A61)],
                                             startPoint: .top, endPoint: .bottom))
                Circle().fill(Color(hex: 0x24262A)).padding(4.5)
                Circle().stroke(Color(hex: 0x0E1013), lineWidth: 0.6).padding(4.5)
                if capturing { Circle().fill(Color.white.opacity(0.10)).padding(10) }
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .disabled(capturing || !enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - 暗房金属蚀刻字牌（仿 bg_darkroom，安卓 btnGallery）
private struct RelicDarkroomPlate: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [Color(hex: 0x666A72), Color(hex: 0x262A30),
                                                  Color(hex: 0x4A4E56)],
                                         startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 11.5).fill(Color(hex: 0x212327)).padding(2.5)
                RoundedRectangle(cornerRadius: 11.5).stroke(Color(hex: 0x0E1013), lineWidth: 0.5)
                    .padding(2.5)
                Text("DARKROOM")
                    .font(.system(size: 8, weight: .medium, design: .monospace))
                    .kerning(0.9)
                    .foregroundColor(Color(hex: 0xC9C5BC))
            }
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 胶卷盒图标（彩色盒身）
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
            RoundedRectangle(cornerRadius: 3).fill(tint).padding(2)
            VStack(spacing: 0) {
                Text(brand.uppercased())
                    .font(.system(size: 6.5, weight: .bold)).foregroundColor(.white).lineLimit(1)
                Text(name.uppercased())
                    .font(.system(size: 9, weight: .heavy)).foregroundColor(.white).lineLimit(1)
            }
            .padding(2)
        }
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.5), lineWidth: 1))
        .shadow(radius: 2)
    }
}

// MARK: - 反射式 TN 液晶屏（仿 T3LcdView：七段计数 + 闪电 + AF 眼 + ISO/EV/电池）
private struct RelicLcdPanel: View {
    let count: Int
    let isoLabel: String
    let evSteps: Float
    let flashLabel: String
    let mode: String
    let battery: Int
    let backlightUntil: Date
    let message: String?
    let messageUntil: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { g in
            let now = timeline.date
            let w = g.size.width, h = g.size.height
            let padX = w * 0.052, padY = h * 0.078
            let ch = h - padY * 2
            let left = padX, right = w - padX
            let top = padY

            // EL 背光：亮 4s，再淡出 600ms（与 Android BACKLIGHT_FADE 一致）
            let bl: CGFloat = {
                let t = now.timeIntervalSince(backlightUntil)
                if t < 0 { return 1 }
                if t < 0.6 { return CGFloat(1 - t / 0.6) }
                return 0
            }()
            let onColor = Color(red: 0.13 - 0.05 * bl, green: 0.15 - 0.05 * bl, blue: 0.12 - 0.03 * bl)
            let ghost = Color.black.opacity(0.13)

            ZStack(alignment: .topLeading) {
                // 液晶底：反射式银灰黄绿，背光叠加 EL 黄绿
                LinearGradient(colors: [Color(red: 0.757, green: 0.784, blue: 0.721),
                                        Color(red: 0.627, green: 0.663, blue: 0.596)],
                               startPoint: .top, endPoint: .bottom)
                Color(red: 0.796, green: 0.839, blue: 0.463).opacity(bl * 0.75)

                // 像素栅格（3pt 极淡线）
                RelicPixelGrid(step: 3).opacity(0.05)

                if let msg = message, now < messageUntil {
                    // 机身提示：1.4Hz 闪烁，点阵化视觉（等宽 + 字距）
                    let blink = Int(now.timeIntervalSinceReferenceDate / 0.35) % 2 == 0
                    if blink {
                        Text(msg)
                            .font(.system(size: min(11, ch * 0.26), weight: .bold, design: .monospaced))
                            .kerning(1.2)
                            .foregroundColor(onColor)
                            .frame(width: w, alignment: .center)
                            .position(x: w / 2, y: h / 2)
                    }
                } else {
                    // 右侧大号七段曝光计数（真机计数在屏右侧）
                    let bigH = ch * 0.46, bigW = bigH * 0.56, gap = bigH * 0.14
                    let digits = String(format: "%02d", min(99, count))
                    HStack(spacing: gap) {
                        RelicSevenSeg(ch: Array(digits)[0], w: bigW, h: bigH, on: onColor, ghost: ghost)
                        RelicSevenSeg(ch: Array(digits)[1], w: bigW, h: bigH, on: onColor, ghost: ghost)
                    }
                    .position(x: right - (bigW * 2 + gap) + bigW + gap / 2, y: top + bigH / 2 + ch * 0.02)

                    // 左列上：闪电 bolt + 闪光模式文字
                    let boltH = ch * 0.30
                    RelicBolt()
                        .fill(flashLabel == "OFF" ? ghost : onColor)
                        .frame(width: boltH * 0.55, height: boltH)
                        .position(x: left + boltH * 0.28, y: top + ch * 0.02 + boltH / 2)
                    Text(flashLabel)
                        .font(.system(size: ch * 0.15, weight: .bold, design: .monospaced))
                        .foregroundColor(onColor)
                        .position(x: left + boltH * 0.78 + 22,
                                  y: top + ch * 0.02 + boltH * 0.92)

                    // 左列下：AF 眼图标（椭圆 + 瞳孔）
                    RelicEye().stroke(onColor, lineWidth: max(1, ch * 0.04))
                        .frame(width: ch * 0.36, height: ch * 0.20)
                        .position(x: left + ch * 0.18,
                                  y: top + ch * 0.02 + boltH + ch * 0.05 + ch * 0.10)

                    // 底行：ISO / EV / 模式 + 电池
                    let smH = ch * 0.15, smW = smH * 0.56
                    let y3 = h - padY - smH - ch * 0.03
                    // 先算好每个字符的 x，避免在 ViewBuilder 的 ForEach 里捕获可变局部量
                    let isoChars = Array(isoLabel.prefix(3))
                    let isoXs = isoChars.indices.map { left + 26 + CGFloat($0) * (smW + smH * 0.14) }
                    Text("ISO").font(.system(size: smH, design: .monospaced)).foregroundColor(onColor)
                        .position(x: left + 12, y: y3 + smH / 2)
                    ForEach(Array(zip(isoChars, isoXs).enumerated()), id: \.offset) { _, pair in
                        RelicSevenSeg(ch: pair.0, w: smW, h: smH, on: onColor, ghost: ghost)
                            .position(x: pair.1 + smW / 2, y: y3 + smH / 2)
                    }
                    if evSteps != 0 {
                        let evX = (isoXs.last ?? left + 26) + smW + 8
                        Text("EV").font(.system(size: smH, design: .monospaced)).foregroundColor(onColor)
                            .position(x: evX + 10, y: y3 + smH / 2)
                        RelicSevenSeg(ch: evSteps > 0 ? "+" : "-", w: smW, h: smH, on: onColor, ghost: ghost)
                            .position(x: evX + 34 + smW / 2, y: y3 + smH / 2)
                    }
                    Text(mode).font(.system(size: smH, weight: .bold, design: .monospaced))
                        .foregroundColor(onColor)
                        .position(x: right - ch * 0.40, y: y3 + smH / 2)
                    RelicBattery(level: battery, color: onColor, ghost: ghost)
                        .frame(width: ch * 0.32, height: smH)
                        .position(x: right - ch * 0.16, y: y3 + smH / 2)
                }

                // 表面玻璃斜向高光
                LinearGradient(colors: [Color.white.opacity(0.16 * (1 - bl * 0.5)), Color.clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color(red: 0.29, green: 0.30, blue: 0.33), lineWidth: 1))
            .background(Color(hex: 0x232428))
            .cornerRadius(8)
            }
        }
    }
}

// MARK: - 七段数码（ghost + 点亮）
private struct RelicSevenSeg: View {
    let ch: Character
    let w: CGFloat
    let h: CGFloat
    let on: Color
    let ghost: Color
    private static let segs: [Character: String] = [
        " ": "", "0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg",
        "5": "acdfg", "6": "acdefg", "7": "abc", "8": "abcdefg", "9": "abcdfg",
        "-": "g", "+": "gV", "A": "abcefg", "E": "adefg", "F": "aefg",
        "L": "def", "P": "abefg", "U": "bcdef", "T": "defg"
    ]
    var body: some View {
        let t = max(1.2, h * 0.13)
        let lit = Self.segs[ch.uppercased().first ?? ch] ?? ""
        ZStack {
            segPath("abcdefg", t, on: ghost)
            segPath(lit, t, on: on)
        }
        .frame(width: w, height: h)
    }
    private func segPath(_ set: String, _ t: CGFloat, on: Color) -> some View {
        let gp = t * 0.30
        let x0 = t * 0.5, x1 = w - t * 0.5
        let yA = t * 0.5, yG = h / 2, yD = h - t * 0.5
        let vTop = yA + gp, vMid = yG - gp, vBot = yD - gp
        return Path { p in
            if set.contains("a") { p.move(to: CGPoint(x: x0 + gp, y: yA)); p.addLine(to: CGPoint(x: x1 - gp, y: yA)) }
            if set.contains("g") { p.move(to: CGPoint(x: x0 + gp, y: yG)); p.addLine(to: CGPoint(x: x1 - gp, y: yG)) }
            if set.contains("d") { p.move(to: CGPoint(x: x0 + gp, y: yD)); p.addLine(to: CGPoint(x: x1 - gp, y: yD)) }
            if set.contains("f") { p.move(to: CGPoint(x: x0, y: vTop)); p.addLine(to: CGPoint(x: x0, y: vMid)) }
            if set.contains("b") { p.move(to: CGPoint(x: x1, y: vTop)); p.addLine(to: CGPoint(x: x1, y: vMid)) }
            if set.contains("e") { p.move(to: CGPoint(x: x0, y: yG + gp)); p.addLine(to: CGPoint(x: x0, y: vBot)) }
            if set.contains("c") { p.move(to: CGPoint(x: x1, y: yG + gp)); p.addLine(to: CGPoint(x: x1, y: vBot)) }
            if set.contains("V") { p.move(to: CGPoint(x: w / 2, y: yA + gp)); p.addLine(to: CGPoint(x: w / 2, y: yD - gp)) }
        }
        .stroke(on, style: StrokeStyle(lineWidth: t, lineCap: .butt))
    }
}

private struct RelicBolt: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.55, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.05, y: r.minY + r.height * 0.55))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.55))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.30, y: r.minY + r.height))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.95, y: r.minY + r.height * 0.40))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.55, y: r.minY + r.height * 0.40))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.72, y: r.minY))
        p.closeSubpath()
        return p
    }
}

private struct RelicEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: r)
        p.addEllipse(in: CGRect(x: r.midX - r.height * 0.11, y: r.midY - r.height * 0.11,
                                width: r.height * 0.22, height: r.height * 0.22))
        return p
    }
}

private struct RelicBattery: View {
    let level: Int
    let color: Color
    let ghost: Color
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let bodyW = w * 0.86
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: h * 0.18).stroke(color, lineWidth: max(1, h * 0.12))
                Rectangle().fill(color).frame(width: w * 0.10, height: h * 0.44)
                    .offset(x: bodyW + 1)
                HStack(spacing: h * 0.12) {
                    ForEach(0..<3, id: \.self) { i in
                        Rectangle().fill(i < level ? color : ghost)
                    }
                }
                .padding(.horizontal, h * 0.22).padding(.vertical, h * 0.22)
            }
        }
    }
}

private struct RelicPixelGrid: View {
    let step: CGFloat
    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(0..<max(1, Int(g.size.width / step)), id: \.self) { i in
                    Rectangle().fill(Color.black)
                        .frame(width: 0.5, height: g.size.height)
                        .position(x: CGFloat(i) * step, y: g.size.height / 2)
                }
                ForEach(0..<max(1, Int(g.size.height / step)), id: \.self) { i in
                    Rectangle().fill(Color.black)
                        .frame(width: g.size.width, height: 0.5)
                        .position(x: g.size.width / 2, y: CGFloat(i) * step)
                }
            }
        }
    }
}

// MARK: - 过卷动画遮罩（黑底 + 胶卷前进 + FILM ADVANCING...）
private struct RelicFilmAdvanceOverlay: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    RelicFilmStrip(now: timeline.date)
                        .frame(width: 72, height: 96)
                        .clipShape(Rectangle())
                }
                Text("FILM ADVANCING...")
                    .font(.system(size: 13, design: .monospaced))
                    .kerning(4)
                    .foregroundColor(.white)
            }
        }
    }
}

private struct RelicFilmStrip: View {
    let now: Date
    var body: some View {
        let offset = CGFloat(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)) * 60
        ZStack(alignment: .top) {
            Rectangle().fill(Color(hex: 0x1A1A1C))
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { i in
                    HStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1).fill(Color(hex: 0xE8E6DF))
                                .frame(width: 8, height: 6)
                        }
                    }
                    .frame(height: 15)
                    Rectangle().fill(Color(hex: 0x3A2A1E)).frame(height: 15)
                }
            }
            .offset(y: offset - 60)
        }
    }
}

// MARK: - 颜色工具
private extension Color {
    init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255)
    }
}
