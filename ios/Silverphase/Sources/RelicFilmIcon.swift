import SwiftUI

// MARK: - 统一胶卷盒图标解析器（阶段 C11）
//
// 根因：装卷页此前直接读 `stock.packagingArtworkURL`（{id}-packaging-vN.png）。
// 引擎只给约 25 支"正式"胶卷生成了这张图，29 支 _fotufilm 实验卷没有，
// 于是退化成系统黄色 film 符号 —— 这就是"有的有图有的没有"。
//
// 现在对齐安卓 FilmRollRepository 的做法：每支胶卷一个固定图标。
// AppResources/FilmCovers/relic_ic_<stock_id>.png 由阶段 C11 随包打入：
//   · 25 支正式卷 = 安卓真实胶卷盒 PNG（ic_film_*.png）
//   · 29 支实验卷 = 同视觉语言生成（品牌色 + 型号 + 感光度）
// 解析顺序统一收口在这里，任何显示胶卷盒的地方都调用它。
enum RelicFilmIcon {

    /// 按 stock id 取图标；优先统一图标，其次引擎 packaging / cover 兜底。
    static func uiImage(stockID: String) -> UIImage? {
        let id = StockCatalog.canonicalID(stockID)
        let subdir = StockCatalog.resourceDirectory + "/FilmCovers"
        if let img = loadPNG(named: "relic_ic_" + id, subdirectory: subdir) {
            return img
        }
        if let stock = StockCatalog.shared.stock(stockID) {
            return uiImage(for: stock)
        }
        return nil
    }

    /// 按 Stock 取图标。
    static func uiImage(for stock: Stock) -> UIImage? {
        let id = StockCatalog.canonicalID(stock.id)
        let subdir = StockCatalog.resourceDirectory + "/FilmCovers"
        if let img = loadPNG(named: "relic_ic_" + id, subdirectory: subdir) {
            return img
        }
        if let url = stock.packagingArtworkURL, let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            return img
        }
        if let url = stock.coverURL, let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            return img
        }
        return nil
    }

    private static func loadPNG(named name: String, subdirectory: String) -> UIImage? {
        guard let url = StockCatalog.bundle.url(forResource: name,
                                                withExtension: "png",
                                                subdirectory: subdirectory),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
