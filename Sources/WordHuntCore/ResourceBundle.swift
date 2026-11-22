import Foundation

public enum ResourceBundle {
    /// SwiftPM's generated `Bundle.module` looks only in the app's root folder,
    /// where code signing forbids files, and then in the absolute build directory.
    /// A packaged app would read the build tree, prompt for Documents access after
    /// each re-sign, and crash once moved. Prefer the copy in Contents/Resources.
    /// `swift run` and tests have no packaged copy and use `fallback`.
    public static func packaged(_ name: String, fallback: () -> Bundle) -> Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("\(name).bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return fallback()
    }
}
