import Foundation

public enum FileCategory: String, CaseIterable, Sendable {
    case code
    case images
    case video
    case audio
    case archives
    case documents
    case other

    public static func classify(name: String) -> FileCategory {
        let ext = fastExtension(name)
        if ext.isEmpty {
            switch name.lowercased() {
            case "makefile", "dockerfile", "containerfile", "gemfile", "rakefile", "podfile":
                return .code
            default:
                return .other
            }
        }
        if codeExtensions.contains(ext) { return .code }
        if imageExtensions.contains(ext) { return .images }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if archiveExtensions.contains(ext) { return .archives }
        if documentExtensions.contains(ext) { return .documents }
        return .other
    }

    /// Same result as `NSString.pathExtension.lowercased()`, without bridging to Objective-C.
    private static func fastExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        let extStart = name.index(after: dot)
        guard extStart < name.endIndex else { return "" }
        return name[extStart...].lowercased()
    }

    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hh", "c", "cc", "cpp", "cxx", "hpp", "hxx",
        "rs", "py", "pyi", "rb", "php", "java", "kt", "kts", "scala", "go",
        "cs", "fs", "hs", "ml", "erl", "ex", "exs", "clj", "lua", "pl", "r",
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte",
        "html", "htm", "css", "scss", "sass", "less",
        "json", "xml", "yml", "yaml", "toml", "ini", "plist",
        "sh", "bash", "zsh", "fish", "sql", "gradle", "cmake",
        "lock", "mod", "sum", "gitignore", "gitattributes", "editorconfig"
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff",
        "bmp", "ico", "icns", "svg", "raw", "dng", "psd", "ai", "eps"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg"
    ]

    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "aac", "flac", "m4a", "aiff", "aif", "ogg", "opus", "wma"
    ]

    private static let archiveExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "dmg", "iso", "pkg"
    ]

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "pages", "numbers", "key", "txt", "rtf", "md", "csv",
        "epub", "odt", "ods", "odp"
    ]
}
