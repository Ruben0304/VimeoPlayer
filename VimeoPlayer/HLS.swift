import Foundation

/// Lectura mínima de playlists HLS: lo justo para servir un VOD de TS desde el proxy local.
enum HLS {
    struct Variant {
        let index: Int
        let bandwidth: Int
        let width: Int
        let height: Int
        let codecs: String?
        let frameRate: String?
        let url: URL
    }

    struct AudioTrack {
        let index: Int
        let name: String
        let language: String?
        let isDefault: Bool
        let channels: String?
        let url: URL
    }

    struct Master {
        /// De menor a mayor ancho de banda; `index` es la posición en esta lista.
        let variants: [Variant]
        let audio: [AudioTrack]
    }

    struct Segment {
        let duration: Double
        let url: URL
    }

    struct MediaPlaylist {
        let segments: [Segment]
        var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }
    }

    enum ParseError: Error {
        case notAPlaylist
        case unsupported(String)
    }

    static func parseMaster(_ text: String, baseURL: URL) throws -> Master {
        let lines = Self.lines(of: text)
        guard lines.first?.hasPrefix("#EXTM3U") == true else { throw ParseError.notAPlaylist }

        var variants: [(attrs: [String: String], url: URL)] = []
        var audio: [AudioTrack] = []
        var pending: [String: String]?

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(of: line)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = attributes(of: line)
                guard attrs["TYPE"] == "AUDIO", let uri = attrs["URI"],
                      let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { continue }
                audio.append(AudioTrack(index: audio.count,
                                        name: attrs["NAME"] ?? "Audio \(audio.count + 1)",
                                        language: attrs["LANGUAGE"],
                                        isDefault: attrs["DEFAULT"] == "YES",
                                        channels: attrs["CHANNELS"],
                                        url: url))
            } else if !line.hasPrefix("#"), let attrs = pending {
                pending = nil
                if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL { variants.append((attrs, url)) }
            }
        }
        guard !variants.isEmpty else { throw ParseError.notAPlaylist }

        let sorted = variants.sorted { (Int($0.attrs["BANDWIDTH"] ?? "") ?? 0) < (Int($1.attrs["BANDWIDTH"] ?? "") ?? 0) }
        return Master(
            variants: sorted.enumerated().map { index, item in
                let size = (item.attrs["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
                return Variant(index: index,
                               bandwidth: Int(item.attrs["BANDWIDTH"] ?? "") ?? 0,
                               width: size.count == 2 ? size[0] : 0,
                               height: size.count == 2 ? size[1] : 0,
                               codecs: item.attrs["CODECS"],
                               frameRate: item.attrs["FRAME-RATE"],
                               url: item.url)
            },
            audio: audio)
    }

    static func parseMedia(_ text: String, baseURL: URL) throws -> MediaPlaylist {
        let lines = Self.lines(of: text)
        guard lines.first?.hasPrefix("#EXTM3U") == true else { throw ParseError.notAPlaylist }

        var segments: [Segment] = []
        var duration: Double?
        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "")
            } else if line.hasPrefix("#EXT-X-KEY:"), attributes(of: line)["METHOD"] != "NONE" {
                throw ParseError.unsupported("cifrado")
            } else if line.hasPrefix("#EXT-X-MAP") {
                throw ParseError.unsupported("fMP4")
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                throw ParseError.unsupported("byte ranges")
            } else if !line.hasPrefix("#"), let duration,
                      let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                segments.append(Segment(duration: duration, url: url))
            }
        }
        guard !segments.isEmpty else { throw ParseError.notAPlaylist }
        return MediaPlaylist(segments: segments)
    }

    /// `KEY=valor,OTRA="con, comas"` → diccionario.
    static func attributes(of line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, inQuotes = false
        for ch in line[line.index(after: colon)...] {
            if inKey {
                if ch == "=" { inKey = false } else if ch != "," { key.append(ch) }
            } else if ch == "\"" {
                inQuotes.toggle()
            } else if ch == ",", !inQuotes {
                result[key.trimmingCharacters(in: .whitespaces)] = value
                key = ""
                value = ""
                inKey = true
            } else {
                value.append(ch)
            }
        }
        if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }
        return result
    }

    private static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
