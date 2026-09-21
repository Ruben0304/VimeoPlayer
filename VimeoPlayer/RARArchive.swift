import CommonCrypto
import Foundation

/// El vídeo dentro de un RAR5: dónde empiezan sus datos y cómo descifrarlos y descomprimirlos.
struct RARVideoEntry {
    struct Encryption {
        let salt: Data
        let iv: Data
        let kdfCount: Int
    }

    let name: String
    /// Posición, dentro del RAR, donde empiezan los datos empaquetados del archivo.
    let dataOffset: Int64
    let packedSize: Int64
    let unpackedSize: Int64
    /// 0 = sin comprimir (store); 1...5 = comprimido.
    let method: Int
    let windowSize: Int
    /// RAR 7.0 (distancias extendidas).
    let extraDist: Bool
    let encryption: Encryption?
}

enum RARError: Error {
    case notRAR
    case wrongPassword
    case unsupported(String)
    case noVideo
}

/// Lectura de las cabeceras de un RAR5 (con o sin cabeceras cifradas).
enum RARArchive {
    /// `fetch(offset, count)` devuelve hasta `count` bytes del archivo desde `offset`.
    static func findVideo(password: String, fetch: (Int64, Int) async throws -> Data) async throws -> RARVideoEntry {
        let signature = try await fetch(0, 8)
        guard signature == Data([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00]) else { throw RARError.notRAR }

        var position: Int64 = 8
        var headerKey: Data?
        var best: RARVideoEntry?

        headers: while true {
            // Cabecera (cifrada o no) que empieza en `position`.
            var block: Data
            var blockLength: Int64
            if let key = headerKey {
                let raw = try await fetch(position, 16 + 16)
                guard raw.count == 32 else { break headers }
                let iv = raw.prefix(16)
                let first = try aesDecrypt(key: key, iv: Data(iv), data: raw.suffix(16))
                var probe = ByteReader(first)
                _ = probe.uint32()
                guard let size = probe.vint() else { throw RARError.unsupported("cabecera") }
                let total = 4 + probe.offset - 4 + Int(size)
                let encrypted = (total + 15) / 16 * 16
                let all = try await fetch(position + 16, encrypted)
                guard all.count == encrypted else { break headers }
                block = try aesDecrypt(key: key, iv: Data(iv), data: all).prefix(total)
                blockLength = Int64(16 + encrypted)
            } else {
                let raw = try await fetch(position, 4096)
                guard raw.count >= 8 else { break headers }
                var probe = ByteReader(raw)
                _ = probe.uint32()
                guard let size = probe.vint() else { throw RARError.unsupported("cabecera") }
                let total = probe.offset + Int(size)
                block = raw.count >= total ? raw.prefix(total) : try await fetch(position, total)
                blockLength = Int64(total)
            }

            block = Data(block)
            var reader = ByteReader(block)
            guard let storedCRC = reader.uint32(),
                  let headerSize = reader.vint(), let type = reader.vint(), let flags = reader.vint() else { break headers }
            let headerEnd = 4 + reader.sizeFieldLength(of: headerSize) + Int(headerSize)
            guard headerEnd <= block.count else { break headers }
            if crc32(block.subdata(in: 4..<headerEnd)) != storedCRC {
                // Con las cabeceras cifradas, una contraseña incorrecta se nota aquí.
                throw headerKey != nil ? RARError.wrongPassword : RARError.unsupported("cabecera dañada")
            }
            var extraSize = 0
            var dataSize: Int64 = 0
            if flags & 0x01 != 0 { extraSize = Int(reader.vint() ?? 0) }
            if flags & 0x02 != 0 { dataSize = Int64(reader.vint() ?? 0) }

            switch type {
            case 4: // cifrado de cabeceras
                _ = reader.vint() // versión
                let encFlags = reader.vint() ?? 0
                guard let count = reader.byte(), let salt = reader.bytes(16) else { throw RARError.unsupported("cifrado") }
                let key = try deriveKey(password: password, salt: salt, iterations: 1 << Int(count))
                _ = encFlags
                headerKey = key

            case 2: // archivo
                let fileFlags = reader.vint() ?? 0
                let unpackedSize = Int64(reader.vint() ?? 0)
                _ = reader.vint() // atributos
                if fileFlags & 0x02 != 0 { _ = reader.uint32() }
                if fileFlags & 0x04 != 0 { _ = reader.uint32() }
                let compInfo = Int(reader.vint() ?? 0)
                _ = reader.vint() // sistema
                let nameLength = Int(reader.vint() ?? 0)
                let name = String(decoding: reader.bytes(nameLength) ?? Data(), as: UTF8.self)

                var encryption: RARVideoEntry.Encryption?
                var extra = ByteReader(block.subdata(in: (headerEnd - extraSize)..<headerEnd))
                while extra.remaining > 0 {
                    guard let recordSize = extra.vint() else { break }
                    let recordEnd = extra.offset + Int(recordSize)
                    guard let recordType = extra.vint() else { break }
                    if recordType == 1 { // cifrado de los datos del archivo
                        _ = extra.vint()
                        let recFlags = extra.vint() ?? 0
                        if let count = extra.byte(), let salt = extra.bytes(16), let iv = extra.bytes(16) {
                            encryption = .init(salt: salt, iv: iv, kdfCount: Int(count))
                        }
                        _ = recFlags
                    }
                    extra.seek(to: recordEnd)
                }

                let isDirectory = fileFlags & 0x01 != 0
                let algorithm = compInfo & 0x3f
                if !isDirectory, dataSize > 0, algorithm <= 1 {
                    if compInfo & 0x40 != 0 { throw RARError.unsupported("archivo sólido") }
                    let method = (compInfo >> 7) & 7
                    var windowSize = 0x20000 << ((compInfo >> 10) & (algorithm == 0 ? 0x0f : 0x1f))
                    if algorithm == 1 { windowSize += windowSize / 32 * ((compInfo >> 15) & 0x1f) }
                    let entry = RARVideoEntry(name: name, dataOffset: position + blockLength, packedSize: dataSize,
                                              unpackedSize: unpackedSize, method: method, windowSize: windowSize,
                                              extraDist: algorithm == 1, encryption: encryption)
                    if best == nil || entry.unpackedSize > best!.unpackedSize { best = entry }
                }

            case 5: // fin del archivo
                break headers

            default:
                break
            }

            position += blockLength + dataSize
        }

        guard let best else { throw RARError.noVideo }
        return best
    }

    // MARK: - Cifrado RAR5 (AES-256-CBC, clave PBKDF2-HMAC-SHA256)

    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data {
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     keyBytes.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard status == kCCSuccess else { throw RARError.unsupported("derivación de clave") }
        return key
    }

    static func aesDecrypt(key: Data, iv: Data, data: Data) throws -> Data {
        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                keyBytes.baseAddress, 32, ivBytes.baseAddress,
                                inBytes.baseAddress, data.count, outBytes.baseAddress, data.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw RARError.unsupported("descifrado") }
        return out.prefix(moved)
    }
}

/// Descifrado AES-256-CBC en flujo (sin relleno), para los datos del archivo.
final class AESCBCStream {
    private var cryptor: CCCryptorRef?

    init(key: Data, iv: Data) throws {
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                keyBytes.baseAddress, 32, ivBytes.baseAddress, &cryptor)
            }
        }
        guard status == kCCSuccess else { throw RARError.unsupported("descifrado") }
    }

    deinit { if let cryptor { CCCryptorRelease(cryptor) } }

    /// `input.count` debe ser múltiplo de 16.
    func decrypt(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> Int {
        var moved = 0
        CCCryptorUpdate(cryptor, input.baseAddress, input.count, output.baseAddress, output.count, &moved)
        return moved
    }
}

// MARK: - Lector de bytes con enteros de longitud variable (vint) de RAR5

struct ByteReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) { self.data = Data(data) }

    var remaining: Int { data.count - offset }

    mutating func byte() -> UInt8? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }

    mutating func uint32() -> UInt32? {
        guard let b = bytes(4) else { return nil }
        return b.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32(8 * $1.offset) }
    }

    mutating func vint() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while let b = byte() {
            value |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return value }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    mutating func seek(to newOffset: Int) { offset = min(max(newOffset, 0), data.count) }

    func sizeFieldLength(of value: UInt64) -> Int {
        var length = 1
        var v = value >> 7
        while v > 0 { length += 1; v >>= 7 }
        return length
    }

}

/// CRC-32 (el de zlib/RAR).
private let crcTable: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)
    for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1 }
    return value
}

func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFFFFFF
}
