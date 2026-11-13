// Ed25519 keys and signatures for SpaceSaver updates.
//
//   swift scripts/update-signing.swift generate          # once: creates the private key and
//                                                        # writes scripts/update-public-key.txt
//   swift scripts/update-signing.swift sign <file>       # prints the base64 signature
//   swift scripts/update-signing.swift verify <file> <signature-file>
//
// The private key lives at ~/.spacesaver-release/update-signing.key (or $SPACESAVER_SIGNING_KEY).
// Back it up somewhere safe: without it you can't ship updates that existing installs accept.
// The signature covers the file's SHA-256, matching UpdateSigner in SpaceSaverCore.
import CryptoKit
import Foundation

let keyPath = ProcessInfo.processInfo.environment["SPACESAVER_SIGNING_KEY"]
    ?? (NSHomeDirectory() + "/.spacesaver-release/update-signing.key")
let publicKeyFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("update-public-key.txt").path

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("update-signing: \(message)\n".utf8))
    exit(1)
}

func sha256(_ path: String) -> Data {
    guard let handle = FileHandle(forReadingAtPath: path) else { die("can't read \(path)") }
    var hasher = SHA256()
    while case let chunk = handle.readData(ofLength: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return Data(hasher.finalize())
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        die("no signing key at \(keyPath). Run `swift scripts/update-signing.swift generate` first.")
    }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "generate":
    if FileManager.default.fileExists(atPath: keyPath) {
        let key = loadPrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        try? (pub + "\n").write(toFile: publicKeyFile, atomically: true, encoding: .utf8)
        print("A signing key already exists at \(keyPath). Public key written to \(publicKeyFile).")
        exit(0)
    }
    let key = Curve25519.Signing.PrivateKey()
    let dir = (keyPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: keyPath, contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
                                   attributes: [.posixPermissions: 0o600])
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    try (pub + "\n").write(toFile: publicKeyFile, atomically: true, encoding: .utf8)
    print("Created the private key at \(keyPath) (back it up; never commit it).")
    print("Public key written to \(publicKeyFile).")

case "sign":
    guard args.count == 2 else { die("usage: sign <file>") }
    let signature = try loadPrivateKey().signature(for: sha256(args[1]))
    print(signature.base64EncodedString())

case "verify":
    guard args.count == 3 else { die("usage: verify <file> <signature-file>") }
    guard let pubText = try? String(contentsOfFile: publicKeyFile, encoding: .utf8),
          let pubRaw = Data(base64Encoded: pubText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw) else { die("no public key in \(publicKeyFile)") }
    guard let sigText = try? String(contentsOfFile: args[2], encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { die("unreadable signature") }
    if pub.isValidSignature(sig, for: sha256(args[1])) { print("OK") } else { die("signature does NOT match") }

default:
    die("usage: generate | sign <file> | verify <file> <signature-file>")
}
