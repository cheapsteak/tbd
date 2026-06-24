import Foundation

/// JSON text <-> `[String: String]` for the `env_overrides` columns.
/// nil/empty encode to nil (column stays NULL, round-trips back to nil);
/// nil/corrupt JSON decodes to `[:]` so a bad row degrades to "no overrides".
public enum EnvOverridesCoding {
    public static func encode(_ overrides: [String: String]?) -> String? {
        guard let overrides, !overrides.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(overrides) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
