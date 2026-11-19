import Foundation

public enum FileCategory: String, CaseIterable, Sendable {
    case code
    case images
    case video
    case audio
    case archives
    case documents
    case other

    public var displayName: String {
        switch self {
        case .code: "Code"
        case .images: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .archives: "Archives"
        case .documents: "Documents"
        case .other: "Other"
        }
    }

    public static func classify(name: String) -> FileCategory {
        let ext = fastExtension(name)
        if ext.isEmpty {
            return exactNameMap[asciiLowercased(name[...])] ?? .other
        }
        return extensionMap[ext] ?? .other
    }

    /// Extracts and lowercases the path extension without Objective-C bridging.
    private static func fastExtension(_ name: String) -> String {
        let utf8 = name.utf8
        guard let dot = utf8.lastIndex(of: 0x2E), dot != utf8.startIndex else { return "" }
        let extStart = utf8.index(after: dot)
        guard extStart < utf8.endIndex else { return "" }
        return asciiLowercased(name[extStart...])
    }

    /// Fast ASCII lowercasing that avoids ICU overhead for the common case.
    private static func asciiLowercased(_ slice: Substring) -> String {
        let utf8 = slice.utf8
        var hasUppercase = false
        for byte in utf8 {
            if byte >= 0x80 {
                return slice.lowercased()
            }
            if byte >= 0x41 && byte <= 0x5A {
                hasUppercase = true
            }
        }
        if !hasUppercase {
            return String(slice)
        }
        return String(unsafeUninitializedCapacity: utf8.count) { buffer in
            var index = 0
            for byte in utf8 {
                buffer[index] = (byte >= 0x41 && byte <= 0x5A) ? (byte &+ 32) : byte
                index += 1
            }
            return index
        }
    }

    private static let exactNameMap: [String: FileCategory] = [
        "makefile": .code,
        "dockerfile": .code,
        "containerfile": .code,
        "gemfile": .code,
        "rakefile": .code,
        "podfile": .code,
        ".gitignore": .code,
        ".gitattributes": .code,
        ".editorconfig": .code
    ]

    private static let extensionMap: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        map.reserveCapacity(140)
        let groups: [(FileCategory, [String])] = [
            (.code, [
                "swift", "m", "mm", "h", "hh", "c", "cc", "cpp", "cxx", "hpp", "hxx",
                "rs", "py", "pyi", "rb", "php", "java", "kt", "kts", "scala", "go",
                "cs", "fs", "hs", "ml", "erl", "ex", "exs", "clj", "lua", "pl", "r",
                "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte",
                "html", "htm", "css", "scss", "sass", "less",
                "json", "xml", "yml", "yaml", "toml", "ini", "plist",
                "sh", "bash", "zsh", "fish", "sql", "gradle", "cmake",
                "lock", "mod", "sum", "gitignore", "gitattributes", "editorconfig"
            ]),
            (.images, [
                "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff",
                "bmp", "ico", "icns", "svg", "raw", "dng", "psd", "ai", "eps"
            ]),
            (.video, [
                "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg"
            ]),
            (.audio, [
                "mp3", "wav", "aac", "flac", "m4a", "aiff", "aif", "ogg", "opus", "wma"
            ]),
            (.archives, [
                "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "dmg", "iso", "pkg"
            ]),
            (.documents, [
                "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
                "pages", "numbers", "key", "txt", "rtf", "md", "csv",
                "epub", "odt", "ods", "odp"
            ])
        ]
        for (category, extensions) in groups {
            for ext in extensions {
                map[ext] = category
            }
        }
        return map
    }()
}
