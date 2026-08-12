import Foundation

public enum LessonCatalog {
    /// Loads every bundled `LessonPack` JSON, preserving first-seen URL order then sorting by filename.
    public static func loadBundled() throws -> [LessonPack] {
        let combined =
            (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            + (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Lessons") ?? [])

        var seen = Set<URL>()
        var urls: [URL] = []
        urls.reserveCapacity(combined.count)
        for url in combined where seen.insert(url).inserted {
            urls.append(url)
        }

        let decoder = JSONDecoder()
        var packs: [LessonPack] = []

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try Data(contentsOf: url)
            do {
                packs.append(try decoder.decode(LessonPack.self, from: data))
            } catch {
                throw EzeestiError.invalidLessonData(
                    "\(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }

        if packs.isEmpty {
            throw EzeestiError.invalidLessonData("No bundled lessons found")
        }

        return packs
    }
}
