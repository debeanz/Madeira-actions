import Foundation
import UIKit

// ============================================================================
// Minimal PE reader for the Games tab (ml791): the machine type of an .exe
// (so 32-bit builds are recognised as unsupported without launching them)
// and its main icon (RT_GROUP_ICON -> RT_ICON, repackaged as an .ico that
// ImageIO decodes). Reads headers and the resource section only; the file
// is memory-mapped, never copied.
// ============================================================================

enum PEResources {
    static let machineI386: UInt16 = 0x014c
    static let machineAMD64: UInt16 = 0x8664
    static let machineARM64: UInt16 = 0xaa64
    static let machineARM64EC: UInt16 = 0xa641

    /// True for the machines this port can run (x86-64 through FEX, or native).
    static func isSupported(machine: UInt16) -> Bool {
        machine == machineAMD64 || machine == machineARM64 || machine == machineARM64EC
    }

    static func machine(of url: URL) -> UInt16? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let r = Reader(d)
        guard let pe = r.peHeaderOffset() else { return nil }
        return r.u16(pe + 4)
    }

    static func icon(of url: URL) -> UIImage? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard let ico = Reader(d).mainIconICO() else { return nil }
        return UIImage(data: ico)
    }

    // MARK: - Reader

    private struct Section {
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawSize: UInt32
        let rawPointer: UInt32
    }

    private struct Reader {
        let d: Data

        init(_ d: Data) { self.d = d }

        func u8(_ off: Int) -> UInt8 {
            guard off >= 0, off < d.count else { return 0 }
            return d[d.startIndex + off]
        }
        func u16(_ off: Int) -> UInt16 {
            UInt16(u8(off)) | (UInt16(u8(off + 1)) << 8)
        }
        func u32(_ off: Int) -> UInt32 {
            UInt32(u16(off)) | (UInt32(u16(off + 2)) << 16)
        }
        func bytes(_ off: Int, _ len: Int) -> Data? {
            guard off >= 0, len >= 0, off + len <= d.count else { return nil }
            return d.subdata(in: (d.startIndex + off)..<(d.startIndex + off + len))
        }

        /// Offset of the "PE\0\0" signature, or nil if this is not a PE file.
        func peHeaderOffset() -> Int? {
            guard d.count > 0x40, u16(0) == 0x5a4d else { return nil }
            let pe = Int(u32(0x3c))
            guard pe > 0, pe + 24 < d.count, u32(pe) == 0x0000_4550 else { return nil }
            return pe
        }

        func sections(pe: Int) -> [Section] {
            let count = Int(u16(pe + 6))
            let optSize = Int(u16(pe + 20))
            let base = pe + 24 + optSize
            guard count > 0, count < 128 else { return [] }
            return (0..<count).map { i in
                let s = base + i * 40
                return Section(virtualAddress: u32(s + 12), virtualSize: u32(s + 8),
                               rawSize: u32(s + 16), rawPointer: u32(s + 20))
            }
        }

        func fileOffset(rva: UInt32, in sections: [Section]) -> Int? {
            for s in sections {
                let span = max(s.virtualSize, s.rawSize)
                if rva >= s.virtualAddress && rva < s.virtualAddress &+ span {
                    let off = Int(s.rawPointer) + Int(rva - s.virtualAddress)
                    return off < d.count ? off : nil
                }
            }
            return nil
        }

        private struct DirEntry {
            let id: UInt32
            let isDirectory: Bool
            let offset: Int      // absolute file offset of the sub-directory or data entry
        }

        private func entries(at dir: Int, rsrcBase: Int) -> [DirEntry] {
            let named = Int(u16(dir + 12)), ids = Int(u16(dir + 14))
            let total = named + ids
            guard total > 0, total < 4096 else { return [] }
            return (0..<total).map { i in
                let e = dir + 16 + i * 8
                let data = u32(e + 4)
                return DirEntry(id: u32(e), isDirectory: data & 0x8000_0000 != 0,
                                offset: rsrcBase + Int(data & 0x7fff_ffff))
            }
        }

        /// Follow a leaf: name/id level -> language level -> data entry.
        /// Returns (file offset, size) of the resource bytes.
        private func leafData(_ entry: DirEntry, rsrcBase: Int, sections: [Section]) -> (Int, Int)? {
            var e = entry
            var hops = 0
            while e.isDirectory && hops < 3 {
                guard let first = entries(at: e.offset, rsrcBase: rsrcBase).first else { return nil }
                e = first
                hops += 1
            }
            guard !e.isDirectory else { return nil }
            let rva = u32(e.offset), size = Int(u32(e.offset + 4))
            guard size > 0, size < 16 * 1024 * 1024, let off = fileOffset(rva: rva, in: sections) else { return nil }
            return (off, size)
        }

        /// The exe's first icon group, repackaged as a single-image .ico.
        func mainIconICO() -> Data? {
            guard let pe = peHeaderOffset() else { return nil }
            let opt = pe + 24
            let magic = u16(opt)
            let dataDirs = opt + (magic == 0x20b ? 112 : 96)
            let rsrcRVA = u32(dataDirs + 2 * 8)
            guard rsrcRVA != 0 else { return nil }
            let secs = sections(pe: pe)
            guard let rsrc = fileOffset(rva: rsrcRVA, in: secs) else { return nil }

            let types = entries(at: rsrc, rsrcBase: rsrc)
            guard let groupType = types.first(where: { $0.id == 14 && $0.isDirectory }),
                  let iconType = types.first(where: { $0.id == 3 && $0.isDirectory }) else { return nil }

            // First icon group = the application icon by convention.
            guard let group = entries(at: groupType.offset, rsrcBase: rsrc).first,
                  let (gOff, gSize) = leafData(group, rsrcBase: rsrc, sections: secs) else { return nil }
            let count = Int(u16(gOff + 4))
            guard count > 0, count < 64, 6 + count * 14 <= gSize else { return nil }

            // Pick the largest, deepest image (width 0 means 256).
            var best: (score: Int, id: UInt16, width: UInt8, height: UInt8, colors: UInt8,
                       planes: UInt16, bits: UInt16)? = nil
            for i in 0..<count {
                let e = gOff + 6 + i * 14
                let w = u8(e), h = u8(e + 1)
                let bits = u16(e + 6)
                let score = Int(w == 0 ? 256 : Int(w)) * 1000 + Int(bits)
                if best == nil || score > best!.score {
                    best = (score, u16(e + 12), w, h, u8(e + 2), u16(e + 4), bits)
                }
            }
            guard let chosen = best else { return nil }

            let icons = entries(at: iconType.offset, rsrcBase: rsrc)
            guard let entry = icons.first(where: { $0.id == UInt32(chosen.id) }),
                  let (iOff, iSize) = leafData(entry, rsrcBase: rsrc, sections: secs),
                  let image = bytes(iOff, iSize) else { return nil }

            var ico = Data()
            func put16(_ v: UInt16) { ico.append(UInt8(v & 0xff)); ico.append(UInt8(v >> 8)) }
            func put32(_ v: UInt32) { put16(UInt16(v & 0xffff)); put16(UInt16(v >> 16)) }
            put16(0); put16(1); put16(1)                       // ICONDIR
            ico.append(chosen.width); ico.append(chosen.height)  // ICONDIRENTRY
            ico.append(chosen.colors); ico.append(0)
            put16(chosen.planes); put16(chosen.bits)
            put32(UInt32(iSize)); put32(22)
            ico.append(image)
            return ico
        }
    }
}
