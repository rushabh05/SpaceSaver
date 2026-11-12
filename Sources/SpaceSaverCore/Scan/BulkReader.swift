import Darwin
import Foundation

public struct DirEntry: Sendable {
    public enum Kind: UInt8, Sendable { case file, directory, symlink, other }

    public var name: String = ""
    public var kind: Kind = .other
    /// Bytes actually allocated on disk (all forks). What deleting the file frees.
    public var allocatedSize: Int64 = 0
    /// Logical length (all forks).
    public var logicalSize: Int64 = 0
    public var modified: Int = 0
    /// When the item was added to its parent folder (APFS/HFS+), 0 if unknown.
    public var added: Int = 0
    public var fileID: UInt64 = 0
    public var linkCount: UInt32 = 1
    public var flags: UInt32 = 0

    /// iCloud "optimized storage" placeholder: reading it would trigger a download.
    public var isDataless: Bool { flags & 0x4000_0000 != 0 }
    public var isDirectory: Bool { kind == .directory }
}

/// Reads a whole directory's entries and metadata with getattrlistbulk(2): one syscall per
/// batch of entries instead of one stat per file. Falls back to readdir+fstatat on
/// filesystems that don't support it.
public enum BulkReader {
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnFlags: UInt32 = 0x0004_0000
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnAddedTime: UInt32 = 0x1000_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileTotalSize: UInt32 = 0x0000_0002
    private static let fileAllocSize: UInt32 = 0x0000_0004
    private static let bufferSize = 256 * 1024

    public struct Result: Sendable {
        public var error: Int32
        /// st_dev of the directory itself (after firmlink resolution).
        public var device: Int32
    }

    public static func read(_ path: String, _ body: (DirEntry) -> Void) -> Result {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { return Result(error: errno, device: 0) }
        defer { close(fd) }

        var st = stat()
        let device: Int32 = fstat(fd, &st) == 0 ? st.st_dev : 0

        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = cmnReturnedAttrs | cmnName | cmnError | cmnObjType | cmnModTime | cmnFlags
            | cmnFileID | cmnAddedTime
        list.fileattr = fileLinkCount | fileTotalSize | fileAllocSize

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var first = true
        while true {
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, 0)
            if count < 0 {
                let err = errno
                if first && (err == ENOTSUP || err == EINVAL) {
                    return readFallback(fd: fd, device: device, body)
                }
                return Result(error: err, device: device)
            }
            first = false
            if count == 0 { break }

            var entryStart = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                var field = entryStart + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                var entry = DirEntry()
                var failed = false
                // ATTR_CMN_ERROR, when present, comes right after the returned-attributes set.
                if returned.commonattr & cmnError != 0 {
                    if field.loadUnaligned(as: UInt32.self) != 0 { failed = true }
                    field += 4
                }
                if returned.commonattr & cmnName != 0 {
                    let ref = field.loadUnaligned(as: attrreference_t.self)
                    let namePtr = (field + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    entry.name = String(cString: namePtr)
                    field += MemoryLayout<attrreference_t>.size
                }
                if returned.commonattr & cmnObjType != 0 {
                    switch field.loadUnaligned(as: UInt32.self) {
                    case 1: entry.kind = .file
                    case 2: entry.kind = .directory
                    case 5: entry.kind = .symlink
                    default: entry.kind = .other
                    }
                    field += 4
                }
                if returned.commonattr & cmnModTime != 0 {
                    entry.modified = field.loadUnaligned(as: timespec.self).tv_sec
                    field += MemoryLayout<timespec>.size
                }
                if returned.commonattr & cmnFlags != 0 {
                    entry.flags = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returned.commonattr & cmnFileID != 0 {
                    entry.fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                if returned.commonattr & cmnAddedTime != 0 {
                    entry.added = field.loadUnaligned(as: timespec.self).tv_sec
                    field += MemoryLayout<timespec>.size
                }
                if returned.fileattr & fileLinkCount != 0 {
                    entry.linkCount = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returned.fileattr & fileTotalSize != 0 {
                    entry.logicalSize = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                if returned.fileattr & fileAllocSize != 0 {
                    entry.allocatedSize = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                if !failed && !entry.name.isEmpty {
                    body(entry)
                }
                entryStart += length
            }
        }
        return Result(error: 0, device: device)
    }

    private static func readFallback(fd: Int32, device: Int32, _ body: (DirEntry) -> Void) -> Result {
        let dupFD = dup(fd)
        guard dupFD >= 0, let dir = fdopendir(dupFD) else { return Result(error: errno, device: device) }
        defer { closedir(dir) }
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            var entry = DirEntry()
            entry.name = name
            switch st.st_mode & S_IFMT {
            case S_IFREG: entry.kind = .file
            case S_IFDIR: entry.kind = .directory
            case S_IFLNK: entry.kind = .symlink
            default: entry.kind = .other
            }
            entry.allocatedSize = Int64(st.st_blocks) * 512
            entry.logicalSize = Int64(st.st_size)
            entry.modified = st.st_mtimespec.tv_sec
            entry.fileID = st.st_ino
            entry.linkCount = UInt32(st.st_nlink)
            entry.flags = st.st_flags
            body(entry)
        }
        return Result(error: 0, device: device)
    }

    /// Convenience: all entries as an array.
    public static func entries(_ path: String) -> [DirEntry] {
        var result: [DirEntry] = []
        _ = read(path) { result.append($0) }
        return result
    }
}
