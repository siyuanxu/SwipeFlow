import Foundation

/// Produces display-only playback addresses without retaining authentication data.
public enum PlaybackAddressRedactor {
    public static func redactedAddress(for url: URL) -> String {
        if url.isFileURL {
            return "本地文件/\(url.lastPathComponent)"
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "无法识别的播放地址"
        }
        let hadQuery = components.query != nil
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        let base = components.string ?? "无法识别的播放地址"
        return hadQuery ? "\(base)?<查询参数已隐藏>" : base
    }
}
