import Foundation

public enum NameGenerator {
    public static let adjectives = AdjectiveList.words
    public static let animals = AnimalList.words

    public static func generate(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let dateStr = formatter.string(from: date)

        let adjective = adjectives.randomElement()!
        let animal = animals.randomElement()!

        return "\(dateStr)-\(adjective)-\(animal)"
    }
}
