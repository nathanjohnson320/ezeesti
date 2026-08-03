import Foundation

public enum LessonCatalog {
    public static func loadBundled() throws -> [LessonPack] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil)
            ?? Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Lessons")
            ?? []

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
            packs = [fallbackMinemaLesson]
        }

        return packs
    }

    public static let fallbackMinemaLesson = LessonPack(
        id: "a2-minema-illative",
        title: "Going somewhere (illative)",
        cefr: .a2,
        focusTip: "After minema / minna, the destination usually takes the illative (-sse / short form like poodi).",
        patternExplanation: "Ma lähen + destination in illative. Pattern: Ma lähen poodi / kooli / koju.",
        items: [
            LessonItem(
                id: "poodi",
                targetEstonian: "Ma lähen poodi.",
                glossEnglish: "I'm going to the store.",
                focusTip: "pood → poodi (illative)"
            ),
            LessonItem(
                id: "kooli",
                targetEstonian: "Ma lähen kooli.",
                glossEnglish: "I'm going to school.",
                focusTip: "kool → kooli (illative)"
            ),
            LessonItem(
                id: "koju",
                targetEstonian: "Ma lähen koju.",
                glossEnglish: "I'm going home.",
                focusTip: "kodu → koju (illative)"
            ),
            LessonItem(
                id: "tööle",
                targetEstonian: "Ma lähen tööle.",
                glossEnglish: "I'm going to work.",
                focusTip: "töö → tööle (allative; common with work)"
            ),
            LessonItem(
                id: "trenni",
                targetEstonian: "Ma lähen trenni.",
                glossEnglish: "I'm going to practice / the gym.",
                focusTip: "treening → trenni (short illative)"
            ),
        ]
    )
}
