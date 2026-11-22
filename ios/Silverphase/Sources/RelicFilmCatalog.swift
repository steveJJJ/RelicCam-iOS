import Foundation

/// 装卷页可见胶卷 —— 与安卓 FilmRollRepository.defaultRolls 完全一致的 25 支。
///
/// 引擎 catalog 仍保留全部 63 支（冲洗、相纸配对等内部路径照常读取），
/// 这里只是一份**展示白名单**：顺序也照抄安卓出厂顺序，不按引擎的字母序。
/// id 取自安卓 FilmStockMapper.ROLL_TABLE，已逐一核对 iOS StockCatalog 均存在。
enum RelicFilmCatalog {
    static let pickerIDs: [String] = [
        "kodak_portra_400",              // PORTRA 400
        "kodak_ektar_100",               // EKTAR 100
        "kodak_gold_200",                // GOLD 200
        "fujifilm_xtra_400",             // SUPERIA 400
        "kodak_kodachrome_64",           // KODACHROME 64
        "kodak_vision3_250d",            // VISION3 250D
        "kodak_tri_x_400",               // TRI-X 400
        "ilford_hp5_plus_400",           // HP5 PLUS
        "cinestill_800t",                // CINESTILL 800T
        "kodak_portra_160",              // PORTRA 160
        "kodak_portra_800",              // PORTRA 800
        "kodak_portra_800_push1",        // PORTRA 800 PUSH 1
        "kodak_portra_800_push2",        // PORTRA 800 PUSH 2
        "kodak_ultramax_400",            // ULTRAMAX 400
        "fujifilm_c200",                 // C200
        "fujifilm_pro_400h",             // PRO 400H
        "kodak_tmax_100",                // T-MAX 100
        "fujifilm_neopan_acros_100_ii",  // NEOPAN ACROS 100 II
        "fujifilm_provia_100f",          // PROVIA 100F
        "fujifilm_velvia_100",           // VELVIA 100
        "kodak_ektachrome_100",          // EKTACHROME 100
        "kodak_verita_200d",             // VERITA 200D
        "kodak_vision3_50d",             // VISION3 50D
        "kodak_vision3_200t",            // VISION3 200T
        "kodak_vision3_500t",            // VISION3 500T
    ]

    /// 按白名单顺序返回可装卷胶卷；catalog 里缺失的 id 自动跳过（不崩、不显示）。
    static var pickerFilms: [Stock] {
        let all = StockCatalog.shared.filmsForPicker
        return pickerIDs.compactMap { id in all.first { $0.id == id } }
    }
}
