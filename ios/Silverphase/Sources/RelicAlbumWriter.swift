import Foundation
import Photos

/// 把暗房成片存进系统相册里「Relic Cam」独立相簿。
///
/// 为什么不用引擎的 PhotoLibraryWriter：它用 .addOnly 权限（只写不可读），
/// 系统不允许在 addOnly 下创建/枚举相簿，所以存进去只能落在「最近项目」。
/// 这里单独用 .readWrite 权限找或建同名相簿，把 APP 的照片和系统照片分开。
enum RelicAlbumWriter {
    static let albumName = "Relic Cam"

    enum SaveError: LocalizedError {
        case noPermission
        case albumFailed

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return "未获准访问照片。请在系统设置中允许 Relic Cam 访问所有照片。"
            case .albumFailed:
                return "无法创建或访问「Relic Cam」相簿。"
            }
        }
    }

    /// 确保相簿可写权限。App 首次调用会弹一次「访问所有照片」授权框。
    @discardableResult
    static func ensureAuthorization() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
                    cont.resume(returning: s == .authorized)
                }
            }
        default:
            // .limited / .denied / .restricted 都无法建相簿
            return false
        }
    }

    /// 找已有相簿，没有就建一个。
    private static func findOrCreateAlbum() async throws -> PHAssetCollection {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "localizedTitle == %@", albumName)
        let found = PHAssetCollection.fetchAssetCollections(with: .album,
                                                            subtype: .any,
                                                            options: opts)
        if let existing = found.firstObject { return existing }

        // 创建相簿只能在 change block 里发请求；placeholder 不是真 collection，
        // 提交完成后必须重新 fetch 才能拿到可写入的 PHAssetCollection。
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
        }
        let again = PHAssetCollection.fetchAssetCollections(with: .album,
                                                            subtype: .any,
                                                            options: opts)
        guard let real = again.firstObject else { throw SaveError.albumFailed }
        return real
    }

    /// 保存文件到「Relic Cam」相簿。
    static func save(_ file: URL) async throws {
        guard await ensureAuthorization() else { throw SaveError.noPermission }
        let album = try await findOrCreateAlbum()
        try await PHPhotoLibrary.shared().performChanges {
            let assetReq = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = file.lastPathComponent
            assetReq.addResource(with: .photo, fileURL: file, options: options)
            if let placeholder = assetReq.placeholderForCreatedAsset,
               let change = PHAssetCollectionChangeRequest(for: album) {
                change.addAssets([placeholder] as NSArray)
            }
        }
    }
}
