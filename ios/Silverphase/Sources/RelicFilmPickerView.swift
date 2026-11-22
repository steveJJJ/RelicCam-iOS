import SwiftUI

// MARK: - 装卷选择器（阶段 B1）
//
// 1:1 参考 Android FilmRollPicker.kt + 真机截图 04_film_picker：
// 深色底、真实胶卷盒图标、卷名 + 中文描述 + 类型标签（电影/彩色/反转/黑白）。
// 胶卷目录直接复用 Silverphase 的 StockCatalog（与引擎绑定，选的 id 进 develop）。

struct RelicFilmPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let currentFilmID: String?
    let onPick: (Stock) -> Void

    private let films = StockCatalog.shared.filmsForPicker

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.09, green: 0.09, blue: 0.10).ignoresSafeArea()
                List {
                    ForEach(films) { stock in
                        Button {
                            onPick(stock)
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                // 胶卷盒图标：统一走 RelicFilmIcon（每支卷都有图）
                                if let img = RelicFilmIcon.uiImage(for: stock) {
                                    Image(uiImage: img)
                                        .resizable().scaledToFit()
                                        .frame(width: 44, height: 44)
                                        .cornerRadius(4)
                                } else {
                                    Image(systemName: "film")
                                        .font(.system(size: 30))
                                        .foregroundColor(.yellow)
                                        .frame(width: 44, height: 44)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(stock.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                    HStack(spacing: 8) {
                                        if let speed = stock.speedLabel {
                                            Text(speed)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.yellow.opacity(0.9))
                                        }
                                        Text(stock.typeLabel)
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.55))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.white.opacity(0.1))
                                            .cornerRadius(3)
                                    }
                                }
                                Spacer()
                                if stock.id == currentFilmID || stock.id == StockCatalog.canonicalID(currentFilmID ?? "") {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.yellow)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("选择胶卷 · 装卷")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }.foregroundColor(.yellow)
                }
            }
        }
    }
}

private extension Stock {
    /// 类型标签：电影 / 彩色负片 / 反转 / 黑白。
    var typeLabel: String {
        if isMonochrome { return "黑白" }
        if isPositive { return "反转" }
        if isCine { return "电影" }
        return "彩色"
    }
}
