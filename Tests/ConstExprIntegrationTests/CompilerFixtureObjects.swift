import Foundation

/// SwiftPM can leave objects for moved/deleted sources in an incremental build.
/// Link the current output map, not every historical object in the directory.
func compilerFixtureObjects(module: String, build: URL) throws -> [URL] {
    let directory = build.appendingPathComponent("\(module).build")
    let map = directory.appendingPathComponent("output-file-map.json")
    if FileManager.default.fileExists(atPath: map.path) {
        let entries = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: map))
        return entries.values.compactMap { $0["object"] }
            .sorted().map { URL(fileURLWithPath: $0) }
    }
    // C shim targets do not emit Swift output maps.
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "o" }.sorted { $0.path < $1.path }
}
