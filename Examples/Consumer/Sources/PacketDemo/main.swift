import Foundation

// The GIF is already a literal byte array in the compiled program.
// Runtime work is limited to choosing a path and writing those bytes.
let path = CommandLine.arguments.dropFirst().first ?? "packet.gif"
try Data(animatedGIF).write(to: URL(fileURLWithPath: path), options: .atomic)
print("Wrote \(animatedGIF.count) bytes to \(path)")
