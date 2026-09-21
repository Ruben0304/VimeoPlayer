import Foundation

// Decodificador de datos comprimidos de RAR 5.0 (algoritmo LZ + filtros), portado a Swift a
// partir de unpack50.cpp / unpackinline.cpp de UnRAR.
//
// UnRAR source code may be used in any software to handle RAR archives without
// limitations free of charge, but cannot be used to develop RAR (WinRAR) compatible
// archiver and to re-create RAR compression algorithm, which is proprietary.
// Distribution of modified UnRAR source code in separate form or as a part of other
// software is permitted, provided that full text of this paragraph, starting from
// "UnRAR source code" words, is included in license, or in documentation if license
// is not available, and in source code comments of resulting package.
// (Copyright (c) Alexander Roshal. Este archivo solo descomprime; no comprime RAR.)

/// Descomprime en orden un único archivo RAR5 (los datos ya sin cifrar). Es síncrono: pide
/// entrada con `read` (que puede bloquearse esperando la descarga) y entrega la salida por `write`.
final class RAR5Decoder {
    enum Failure: Error {
        case corrupt(String)
        case unsupported(String)
    }

    /// Rellena hasta `capacity` bytes y devuelve cuántos; 0 significa fin de los datos.
    typealias Reader = (_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int) -> Int
    typealias Writer = (_ data: UnsafePointer<UInt8>, _ count: Int) -> Void

    // MARK: - Constantes (compress.hpp / unpack.hpp)

    private static let NC = 306
    private static let DCB = 64
    private static let DCX = 80
    private static let LDC = 16
    private static let RC = 44
    private static let BC = 20
    private static let maxQuickBits = 9
    private static let maxIncLZMatch = 0x1001 + 3
    private static let maxFilterBlockSize = 0x400000
    private static let unpackMaxWrite = 0x400000
    private static let maxUnpackFilters = 8192

    private static let filterDelta = 0
    private static let filterE8 = 1
    private static let filterE8E9 = 2
    private static let filterARM = 3
    private static let filterNone = -1

    // MARK: - Tablas Huffman

    private final class DecodeTable {
        var decodeLen = [UInt32](repeating: 0, count: 16)
        var decodePos = [UInt32](repeating: 0, count: 16)
        var quickBits = 0
        var quickLen = [UInt8](repeating: 0, count: 1 << RAR5Decoder.maxQuickBits)
        var quickNum = [UInt16](repeating: 0, count: 1 << RAR5Decoder.maxQuickBits)
        var decodeNum = [UInt16](repeating: 0, count: RAR5Decoder.NC)
        var maxNum = 0
    }

    private struct BlockHeader {
        var blockSize = -1
        var blockBitSize = 0
        var blockStart = 0
        var lastBlockInFile = false
        var tablePresent = false
    }

    private struct Filter {
        var type: Int
        var channels = 0
        var nextWindow = false
        var blockStart: Int
        var blockLength: Int
    }

    // MARK: - Estado

    private let extraDist: Bool
    private let destUnpSize: Int64
    private let read: Reader
    private let write: Writer

    // Ventana deslizante
    private let maxWinSize: Int
    private let window: UnsafeMutablePointer<UInt8>
    private var unpPtr = 0
    private var wrPtr = 0
    private var prevPtr = 0
    private var firstWinDone = false
    private var writeBorder = 0
    private var writtenFileSize: Int64 = 0

    // Entrada por bits, con posiciones absolutas dentro del flujo empaquetado
    private let bufCapacity = 2 << 20
    private let buf: UnsafeMutablePointer<UInt8>
    private var bufBase = 0
    private var bufEnd = 0
    private var pos = 0
    private var bit = 0
    private var inputEnded = false

    private var header = BlockHeader()
    private var tablesRead = false
    private let ld = DecodeTable()
    private let dd = DecodeTable()
    private let ldd = DecodeTable()
    private let rd = DecodeTable()
    private let bd = DecodeTable()

    private var oldDist = [Int](repeating: Int.max, count: 4)
    private var lastLength = 0
    private var filters: [Filter] = []
    private var filterSrc = [UInt8]()
    private var filterDst = [UInt8]()

    init(windowSize: Int, extraDist: Bool, unpackedSize: Int64, read: @escaping Reader, write: @escaping Writer) {
        // Mismo mínimo que UnRAR: el doble del mayor bloque de filtro, con margen.
        maxWinSize = max(windowSize, 0x40000)
        self.extraDist = extraDist
        destUnpSize = unpackedSize
        self.read = read
        self.write = write
        window = .allocate(capacity: maxWinSize)
        window.initialize(repeating: 0, count: maxWinSize)
        buf = .allocate(capacity: bufCapacity + 128)
        buf.initialize(repeating: 0, count: bufCapacity + 128)
        writeBorder = min(maxWinSize, Self.unpackMaxWrite)
    }

    deinit {
        window.deallocate()
        buf.deallocate()
    }

    // MARK: - Punto de entrada (Unpack::Unpack5)

    func run() throws {
        ensure(64)
        guard try readBlockHeader(), try readTables(), tablesRead else {
            throw Failure.corrupt("cabecera de bloque inicial")
        }

        while true {
            unpPtr = wrapUp(unpPtr)
            firstWinDone = firstWinDone || prevPtr > unpPtr
            prevPtr = unpPtr

            // ¿Fin del bloque actual? (con `while`: un bloque vacío puede traer solo una tabla)
            var fileDone = false
            while blockEnded() {
                if header.lastBlockInFile {
                    fileDone = true
                    break
                }
                guard try readBlockHeader(), try readTables() else { throw Failure.corrupt("cabecera de bloque") }
            }
            if fileDone { break }

            ensure(64)
            if inputEnded && pos >= bufEnd { throw Failure.corrupt("datos truncados") }

            // writeBorder == unpPtr significa que hay una ventana entera por delante.
            if wrapDown(writeBorder - unpPtr) <= Self.maxIncLZMatch && writeBorder != unpPtr {
                unpWriteBuf()
                if writtenFileSize > destUnpSize { return }
            }

            let mainSlot = decodeNumber(ld)
            if mainSlot < 256 {
                window[unpPtr] = UInt8(mainSlot)
                unpPtr += 1
                continue
            }
            if mainSlot >= 262 {
                var length = slotToLength(mainSlot - 262)

                var distance = 1
                var dBits = 0
                let distSlot = decodeNumber(dd)
                if distSlot < 4 {
                    dBits = 0
                    distance += distSlot
                } else {
                    dBits = distSlot / 2 - 1
                    distance += (2 | (distSlot & 1)) << dBits
                }

                if dBits > 0 {
                    if dBits >= 4 {
                        if dBits > 4 {
                            if dBits > 36 {
                                distance += Int(truncatingIfNeeded: getbits64() >> UInt64(68 - dBits)) << 4
                            } else {
                                distance += Int(getbits32() >> UInt32(36 - dBits)) << 4
                            }
                            addbits(dBits - 4)
                        }
                        distance += decodeNumber(ldd)
                    } else {
                        distance += Int(getbits() >> UInt32(16 - dBits))
                        addbits(dBits)
                    }
                }

                if distance > 0x100 {
                    length += 1
                    if distance > 0x2000 {
                        length += 1
                        if distance > 0x40000 { length += 1 }
                    }
                }

                insertOldDist(distance)
                lastLength = length
                copyString(length, distance)
                continue
            }
            if mainSlot == 256 {
                guard var filter = readFilter() else { break }
                addFilter(&filter)
                continue
            }
            if mainSlot == 257 {
                if lastLength != 0 { copyString(lastLength, oldDist[0]) }
                continue
            }
            // 258...261: repetición de una de las últimas distancias
            let distNum = mainSlot - 258
            let distance = oldDist[distNum]
            var i = distNum
            while i > 0 {
                oldDist[i] = oldDist[i - 1]
                i -= 1
            }
            oldDist[0] = distance

            let lengthSlot = decodeNumber(rd)
            let length = slotToLength(lengthSlot)
            lastLength = length
            copyString(length, distance)
        }
        unpWriteBuf()
    }

    // MARK: - Entrada por bits

    /// Garantiza `count` bytes disponibles desde `pos` (o el fin de los datos, rellenado con ceros).
    @inline(__always)
    private func ensure(_ count: Int) {
        while bufEnd - pos < count && !inputEnded { refill() }
    }

    private func refill() {
        // Descarta lo ya consumido cuando ocupa más de la mitad.
        if pos - bufBase > bufCapacity / 2 {
            let keep = bufEnd - pos
            if keep > 0 { memmove(buf, buf + (pos - bufBase), keep) }
            bufBase = pos
        }
        let used = bufEnd - bufBase
        let got = read(buf + used, bufCapacity - used)
        if got > 0 {
            bufEnd += got
        } else {
            inputEnded = true
            // Ceros tras el final, para que los getbits de los últimos símbolos no se salgan.
            (buf + (bufEnd - bufBase)).initialize(repeating: 0, count: 128)
        }
    }

    @inline(__always)
    private func addbits(_ bits: Int) {
        let total = bits + bit
        pos += total >> 3
        bit = total & 7
    }

    @inline(__always)
    private func getbits() -> UInt32 {
        let o = pos - bufBase
        var field = UInt32(buf[o]) << 16 | UInt32(buf[o + 1]) << 8 | UInt32(buf[o + 2])
        field >>= UInt32(8 - bit)
        return field & 0xffff
    }

    @inline(__always)
    private func getbits32() -> UInt32 {
        let o = pos - bufBase
        let be = UInt32(buf[o]) << 24 | UInt32(buf[o + 1]) << 16 | UInt32(buf[o + 2]) << 8 | UInt32(buf[o + 3])
        return (be &<< UInt32(bit)) | (UInt32(buf[o + 4]) >> UInt32(8 - bit))
    }

    @inline(__always)
    private func getbits64() -> UInt64 {
        let o = pos - bufBase
        var be: UInt64 = 0
        for i in 0..<8 { be = be << 8 | UInt64(buf[o + i]) }
        return (be &<< UInt64(bit)) | (UInt64(buf[o + 8]) >> UInt64(8 - bit))
    }

    // MARK: - Bloques y tablas

    private func blockEnded() -> Bool {
        let endByte = header.blockStart + header.blockSize - 1
        return pos > endByte || (pos == endByte && bit >= header.blockBitSize)
    }

    private func readBlockHeader() throws -> Bool {
        ensure(64)
        addbits((8 - bit) & 7)

        let blockFlags = Int(getbits() >> 8)
        addbits(8)
        let byteCount = ((blockFlags >> 3) & 3) + 1
        if byteCount == 4 { return false }

        header.blockBitSize = (blockFlags & 7) + 1

        let savedCheckSum = Int(getbits() >> 8)
        addbits(8)

        var blockSize = 0
        for i in 0..<byteCount {
            blockSize += Int(getbits() >> 8) << (i * 8)
            addbits(8)
        }
        header.blockSize = blockSize
        let checkSum = (0x5a ^ blockFlags ^ blockSize ^ (blockSize >> 8) ^ (blockSize >> 16)) & 0xff
        if checkSum != savedCheckSum { return false }

        header.blockStart = pos
        header.lastBlockInFile = blockFlags & 0x40 != 0
        header.tablePresent = blockFlags & 0x80 != 0
        return true
    }

    private func readTables() throws -> Bool {
        if !header.tablePresent { return true }
        ensure(4096)

        var bitLength = [UInt8](repeating: 0, count: Self.BC)
        var i = 0
        while i < Self.BC {
            let length = Int(getbits() >> 12)
            addbits(4)
            if length == 15 {
                var zeroCount = Int(getbits() >> 12)
                addbits(4)
                if zeroCount == 0 {
                    bitLength[i] = 15
                } else {
                    zeroCount += 2
                    while zeroCount > 0 && i < Self.BC {
                        bitLength[i] = 0
                        i += 1
                        zeroCount -= 1
                    }
                    i -= 1
                }
            } else {
                bitLength[i] = UInt8(length)
            }
            i += 1
        }
        makeDecodeTables(bitLength, offset: 0, bd, size: Self.BC)

        let tableSize = Self.NC + (extraDist ? Self.DCX : Self.DCB) + Self.RC + Self.LDC
        var table = [UInt8](repeating: 0, count: tableSize)
        i = 0
        while i < tableSize {
            ensure(64)
            let number = decodeNumber(bd)
            if number < 16 {
                table[i] = UInt8(number)
                i += 1
            } else if number < 18 {
                var n: Int
                if number == 16 {
                    n = Int(getbits() >> 13) + 3
                    addbits(3)
                } else {
                    n = Int(getbits() >> 9) + 11
                    addbits(7)
                }
                if i == 0 { return false }
                while n > 0 && i < tableSize {
                    table[i] = table[i - 1]
                    i += 1
                    n -= 1
                }
            } else {
                var n: Int
                if number == 18 {
                    n = Int(getbits() >> 13) + 3
                    addbits(3)
                } else {
                    n = Int(getbits() >> 9) + 11
                    addbits(7)
                }
                while n > 0 && i < tableSize {
                    table[i] = 0
                    i += 1
                    n -= 1
                }
            }
        }
        tablesRead = true
        let dCodes = extraDist ? Self.DCX : Self.DCB
        makeDecodeTables(table, offset: 0, ld, size: Self.NC)
        makeDecodeTables(table, offset: Self.NC, dd, size: dCodes)
        makeDecodeTables(table, offset: Self.NC + dCodes, ldd, size: Self.LDC)
        makeDecodeTables(table, offset: Self.NC + dCodes + Self.LDC, rd, size: Self.RC)
        return true
    }

    /// Unpack::MakeDecodeTables.
    private func makeDecodeTables(_ lengths: [UInt8], offset: Int, _ dec: DecodeTable, size: Int) {
        dec.maxNum = size

        var lengthCount = [UInt32](repeating: 0, count: 16)
        for i in 0..<size { lengthCount[Int(lengths[offset + i] & 0xf)] += 1 }
        lengthCount[0] = 0

        for i in 0..<dec.decodeNum.count { dec.decodeNum[i] = 0 }
        dec.decodePos[0] = 0
        dec.decodeLen[0] = 0

        var upperLimit: UInt32 = 0
        for i in 1..<16 {
            upperLimit &+= lengthCount[i]
            let leftAligned = upperLimit &<< UInt32(16 - i)
            upperLimit &*= 2
            dec.decodeLen[i] = leftAligned
            dec.decodePos[i] = dec.decodePos[i - 1] &+ lengthCount[i - 1]
        }

        var copyDecodePos = dec.decodePos
        for i in 0..<size {
            let curBitLength = Int(lengths[offset + i] & 0xf)
            if curBitLength != 0 {
                let lastPos = Int(copyDecodePos[curBitLength])
                dec.decodeNum[lastPos] = UInt16(i)
                copyDecodePos[curBitLength] += 1
            }
        }

        dec.quickBits = size == Self.NC ? Self.maxQuickBits : Self.maxQuickBits - 3

        let quickDataSize = 1 << dec.quickBits
        var curBitLength = 1
        for code in 0..<quickDataSize {
            let bitField = UInt32(code) << UInt32(16 - dec.quickBits)
            while curBitLength < dec.decodeLen.count && bitField >= dec.decodeLen[curBitLength] { curBitLength += 1 }
            dec.quickLen[code] = UInt8(curBitLength)

            var dist = bitField &- dec.decodeLen[curBitLength - 1]
            dist >>= UInt32(16 - curBitLength)

            let pos = Int(dec.decodePos[min(curBitLength, 15)] &+ dist)
            if curBitLength < dec.decodePos.count && pos < size {
                dec.quickNum[code] = dec.decodeNum[pos]
            } else {
                dec.quickNum[code] = 0
            }
        }
    }

    @inline(__always)
    private func decodeNumber(_ dec: DecodeTable) -> Int {
        let bitField = getbits() & 0xfffe
        if bitField < dec.decodeLen[dec.quickBits] {
            let code = Int(bitField >> UInt32(16 - dec.quickBits))
            addbits(Int(dec.quickLen[code]))
            return Int(dec.quickNum[code])
        }

        var bits = 15
        var i = dec.quickBits + 1
        while i < 15 {
            if bitField < dec.decodeLen[i] {
                bits = i
                break
            }
            i += 1
        }
        addbits(bits)

        let dist = (bitField &- dec.decodeLen[bits - 1]) >> UInt32(16 - bits)
        var position = Int(dec.decodePos[bits] &+ dist)
        if position >= dec.maxNum { position = 0 }
        return Int(dec.decodeNum[position])
    }

    @inline(__always)
    private func slotToLength(_ slot: Int) -> Int {
        var lBits = 0
        var length = 2
        if slot < 8 {
            length += slot
        } else {
            lBits = slot / 4 - 1
            length += (4 | (slot & 3)) << lBits
        }
        if lBits > 0 {
            length += Int(getbits() >> UInt32(16 - lBits))
            addbits(lBits)
        }
        return length
    }

    // MARK: - Ventana

    @inline(__always)
    private func wrapDown(_ value: Int) -> Int { value < 0 ? value + maxWinSize : value }

    @inline(__always)
    private func wrapUp(_ value: Int) -> Int { value >= maxWinSize ? value - maxWinSize : value }

    @inline(__always)
    private func insertOldDist(_ distance: Int) {
        oldDist[3] = oldDist[2]
        oldDist[2] = oldDist[1]
        oldDist[1] = oldDist[0]
        oldDist[0] = distance
    }

    /// Unpack::CopyString.
    private func copyString(_ length: Int, _ distance: Int) {
        var length = length
        var srcPtr = unpPtr &- distance

        if distance > unpPtr {
            srcPtr += maxWinSize
            if distance > maxWinSize || !firstWinDone {
                // Distancia inválida o aún sin ventana completa: se rellena con ceros.
                while length > 0 {
                    window[unpPtr] = 0
                    unpPtr = wrapUp(unpPtr + 1)
                    length -= 1
                }
                return
            }
        }

        if srcPtr < maxWinSize - Self.maxIncLZMatch && unpPtr < maxWinSize - Self.maxIncLZMatch {
            var src = window + srcPtr
            var dest = window + unpPtr
            unpPtr += length
            while length > 0 {
                dest.pointee = src.pointee
                src += 1
                dest += 1
                length -= 1
            }
        } else {
            while length > 0 {
                window[unpPtr] = window[wrapUp(srcPtr)]
                srcPtr += 1
                unpPtr = wrapUp(unpPtr + 1)
                length -= 1
            }
        }
    }

    // MARK: - Filtros

    private func readFilterData() -> Int {
        let byteCount = Int(getbits() >> 14) + 1
        addbits(2)
        var data = 0
        for i in 0..<byteCount {
            data += Int(getbits() >> 8) << (i * 8)
            addbits(8)
        }
        return data
    }

    private func readFilter() -> Filter? {
        ensure(64)
        let blockStart = readFilterData()
        var blockLength = readFilterData()
        if blockLength > Self.maxFilterBlockSize { blockLength = 0 }

        var filter = Filter(type: Int(getbits() >> 13), blockStart: blockStart, blockLength: blockLength)
        addbits(3)
        if filter.type == Self.filterDelta {
            filter.channels = Int(getbits() >> 11) + 1
            addbits(5)
        }
        return filter
    }

    private func addFilter(_ filter: inout Filter) {
        if filters.count >= Self.maxUnpackFilters {
            unpWriteBuf()
            if filters.count >= Self.maxUnpackFilters { filters.removeAll() }
        }
        filter.nextWindow = wrPtr != unpPtr && wrapDown(wrPtr - unpPtr) <= filter.blockStart
        filter.blockStart = (filter.blockStart + unpPtr) % maxWinSize
        filters.append(filter)
    }

    /// Unpack::UnpWriteBuf: escribe lo decodificado aplicando antes los filtros pendientes.
    private func unpWriteBuf() {
        var writtenBorder = wrPtr
        let fullWriteSize = wrapDown(unpPtr - writtenBorder)
        var writeSizeLeft = fullWriteSize
        var notAllFiltersProcessed = false

        var index = 0
        while index < filters.count {
            defer { index += 1 }
            if filters[index].type == Self.filterNone { continue }
            if filters[index].nextWindow {
                if wrapDown(filters[index].blockStart - wrPtr) <= fullWriteSize { filters[index].nextWindow = false }
                continue
            }
            let blockStart = filters[index].blockStart
            let blockLength = filters[index].blockLength
            if wrapDown(blockStart - writtenBorder) < writeSizeLeft {
                if writtenBorder != blockStart {
                    unpWriteArea(writtenBorder, blockStart)
                    writtenBorder = blockStart
                    writeSizeLeft = wrapDown(unpPtr - writtenBorder)
                }
                if blockLength <= writeSizeLeft {
                    if blockLength > 0 {
                        let blockEnd = wrapUp(blockStart + blockLength)

                        if filterSrc.count < blockLength { filterSrc = [UInt8](repeating: 0, count: blockLength) }
                        filterSrc.withUnsafeMutableBufferPointer { mem in
                            if blockStart < blockEnd || blockEnd == 0 {
                                memcpy(mem.baseAddress!, window + blockStart, blockLength)
                            } else {
                                let firstPart = maxWinSize - blockStart
                                memcpy(mem.baseAddress!, window + blockStart, firstPart)
                                memcpy(mem.baseAddress! + firstPart, window, blockEnd)
                            }
                        }

                        let ok = applyFilter(filters[index], size: blockLength)
                        filters[index].type = Self.filterNone
                        if ok { emit(lastFilterOutput, blockLength) }
                        writtenFileSize += Int64(blockLength)
                        writtenBorder = blockEnd
                        writeSizeLeft = wrapDown(unpPtr - writtenBorder)
                    }
                } else {
                    wrPtr = writtenBorder
                    for j in index..<filters.count where filters[j].type != Self.filterNone {
                        filters[j].nextWindow = false
                    }
                    notAllFiltersProcessed = true
                    break
                }
            }
        }

        filters.removeAll { $0.type == Self.filterNone }

        if !notAllFiltersProcessed {
            unpWriteArea(writtenBorder, unpPtr)
            wrPtr = unpPtr
        }

        writeBorder = wrapUp(unpPtr + min(maxWinSize, Self.unpackMaxWrite))
        if writeBorder == unpPtr || (wrPtr != unpPtr && wrapDown(wrPtr - unpPtr) < wrapDown(writeBorder - unpPtr)) {
            writeBorder = wrPtr
        }
    }

    private enum FilterOutput { case src, dst }
    private var lastFilterOutput = FilterOutput.src

    private func emit(_ output: FilterOutput, _ count: Int) {
        switch output {
        case .src: filterSrc.withUnsafeBufferPointer { write($0.baseAddress!, count) }
        case .dst: filterDst.withUnsafeBufferPointer { write($0.baseAddress!, count) }
        }
    }

    /// Unpack::ApplyFilter sobre `filterSrc`; deja el resultado en `filterSrc` o `filterDst`.
    private func applyFilter(_ flt: Filter, size dataSize: Int) -> Bool {
        switch flt.type {
        case Self.filterE8, Self.filterE8E9:
            let fileOffset = UInt32(truncatingIfNeeded: writtenFileSize)
            let fileSize: UInt32 = 0x1000000
            let cmpByte2: UInt8 = flt.type == Self.filterE8E9 ? 0xe9 : 0xe8
            filterSrc.withUnsafeMutableBufferPointer { data in
                var index = 0
                var curPos = 0
                while curPos + 4 < dataSize {
                    let curByte = data[index]
                    index += 1
                    curPos += 1
                    if curByte == 0xe8 || curByte == cmpByte2 {
                        let offset = (UInt32(curPos) &+ fileOffset) % fileSize
                        var addr = UInt32(data[index]) | UInt32(data[index + 1]) << 8
                            | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
                        if addr & 0x80000000 != 0 {
                            if (addr &+ offset) & 0x80000000 == 0 { addr = addr &+ fileSize; put4(addr, data, index) }
                        } else if (addr &- fileSize) & 0x80000000 != 0 {
                            addr = addr &- offset
                            put4(addr, data, index)
                        }
                        index += 4
                        curPos += 4
                    }
                }
            }
            lastFilterOutput = .src
            return true

        case Self.filterARM:
            let fileOffset = UInt32(truncatingIfNeeded: writtenFileSize)
            filterSrc.withUnsafeMutableBufferPointer { data in
                var curPos = 0
                while curPos + 3 < dataSize {
                    if data[curPos + 3] == 0xeb {
                        var offset = UInt32(data[curPos]) + UInt32(data[curPos + 1]) * 0x100 + UInt32(data[curPos + 2]) * 0x10000
                        offset = offset &- (fileOffset &+ UInt32(curPos)) / 4
                        data[curPos] = UInt8(truncatingIfNeeded: offset)
                        data[curPos + 1] = UInt8(truncatingIfNeeded: offset >> 8)
                        data[curPos + 2] = UInt8(truncatingIfNeeded: offset >> 16)
                    }
                    curPos += 4
                }
            }
            lastFilterOutput = .src
            return true

        case Self.filterDelta:
            let channels = flt.channels
            if filterDst.count < dataSize { filterDst = [UInt8](repeating: 0, count: dataSize) }
            var srcPos = 0
            for curChannel in 0..<channels {
                var prevByte: UInt8 = 0
                var destPos = curChannel
                while destPos < dataSize {
                    prevByte = prevByte &- filterSrc[srcPos]
                    srcPos += 1
                    filterDst[destPos] = prevByte
                    destPos += channels
                }
            }
            lastFilterOutput = .dst
            return true

        default:
            return false
        }
    }

    @inline(__always)
    private func put4(_ value: UInt32, _ data: UnsafeMutableBufferPointer<UInt8>, _ index: Int) {
        data[index] = UInt8(truncatingIfNeeded: value)
        data[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[index + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func unpWriteArea(_ startPtr: Int, _ endPtr: Int) {
        if endPtr < startPtr {
            unpWriteData(window + startPtr, maxWinSize - startPtr)
            unpWriteData(window, endPtr)
        } else {
            unpWriteData(window + startPtr, endPtr - startPtr)
        }
    }

    private func unpWriteData(_ data: UnsafePointer<UInt8>, _ size: Int) {
        if writtenFileSize >= destUnpSize { return }
        var writeSize = size
        let leftToWrite = destUnpSize - writtenFileSize
        if Int64(writeSize) > leftToWrite { writeSize = Int(leftToWrite) }
        if writeSize > 0 { write(data, writeSize) }
        writtenFileSize += Int64(size)
    }
}
