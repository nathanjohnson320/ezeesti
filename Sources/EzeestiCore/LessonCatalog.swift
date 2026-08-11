import Foundation

public enum LessonCatalog {
    public static func loadBundled() throws -> [LessonPack] {
        let urls = Array(Set(
            (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            + (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Lessons") ?? [])
        ))

        let decoder = JSONDecoder()
        var packs: [LessonPack] = []

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try Data(contentsOf: url)
            do {
                packs.append(try decoder.decode(LessonPack.self, from: data))
            } catch {
                throw EzeestiError.invalidLessonData("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if packs.isEmpty {
            throw EzeestiError.invalidLessonData("No bundled lessons found")
        }

        return packs
    }
}
