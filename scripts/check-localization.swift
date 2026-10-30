import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var problems: [String] = []
func placeholders(_ value: String) -> Int {
    let regex = try! NSRegularExpression(pattern: "%([0-9]+\\$)?@")
    return regex.numberOfMatches(in: value, range: NSRange(value.startIndex..., in: value))
}
for name in ["Localizable", "InfoPlist"] {
    let url = root.appendingPathComponent("App/\(name).xcstrings")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let strings = json["strings"] as! [String: [String: Any]]
    for (key, entry) in strings {
        let locales = entry["localizations"] as? [String: [String: Any]] ?? [:]
        let english = (locales["en"]?["stringUnit"] as? [String: Any])?["value"] as? String
        let chinese = (locales["zh-Hans"]?["stringUnit"] as? [String: Any])?["value"] as? String
        guard let english, let chinese, !english.isEmpty, !chinese.isEmpty else {
            problems.append("\(name): missing translation for \(key)"); continue
        }
        if placeholders(english) != placeholders(chinese) { problems.append("\(key): placeholder mismatch") }
    }
    if name == "Localizable" {
        let expression = try NSRegularExpression(pattern: "L10n\\.(?:tr|format)\\(\"([^\"]+)\"")
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("App"), includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let key = (source as NSString).substring(with: match.range(at: 1))
                if strings[key] == nil { problems.append("\(file.lastPathComponent): missing key \(key)") }
            }
        }
    }
    print("\(name): checked \(strings.count) entries")
}
let resources = root.appendingPathComponent("Sources/LunaSyncCore/Resources")
let en = try PropertyListSerialization.propertyList(from: Data(contentsOf: resources.appendingPathComponent("en.lproj/Localizable.strings")), format: nil) as! [String: String]
let zh = try PropertyListSerialization.propertyList(from: Data(contentsOf: resources.appendingPathComponent("zh-Hans.lproj/Localizable.strings")), format: nil) as! [String: String]
if Set(en.keys) != Set(zh.keys) { problems.append("Engine translations have different key sets") }
for (key, value) in en where placeholders(value) != placeholders(zh[key] ?? "") { problems.append("\(key): engine placeholder mismatch") }
print("Engine: checked \(en.count) entries")
if !problems.isEmpty {
    problems.forEach { print("ERROR: \($0)") }
    exit(1)
}
print("All localization checks passed.")
