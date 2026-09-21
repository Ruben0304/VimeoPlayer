import Foundation

/// Claves de configuración. La de TMDB sale de `.env` (TMDB_API_KEY): un script de build
/// la copia al Info.plist, porque la app va en sandbox y no puede leer `.env` en runtime.
enum Config {
    static var tmdbAPIKey: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
            ?? ProcessInfo.processInfo.environment["TMDB_API_KEY"]
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
