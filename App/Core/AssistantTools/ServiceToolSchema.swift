import Foundation
import FoundationModels

/// Turns a stored MCP input description (`ToolInputSchema`, already limited to text, numbers, yes/no and fixed choices)
/// into a Foundation Models schema, and turns what the model produced back into plain argument values.
///
/// The model's output is never trusted: decoded values go through `ConnectionManager.prepareToolCall`, which validates
/// them against the same stored schema (unknown names, missing fields, types, ranges, lengths) and refuses on any problem.
enum ServiceToolSchema {
    /// Longest field description handed to the model. The context window is small.
    static let fieldDescriptionLimit = 120

    /// Builds the dynamic schema. Fails only if the SDK rejects the shape (for example a duplicate field name).
    static func generationSchema(toolName: String, schema: ToolInputSchema) throws -> GenerationSchema {
        var properties: [DynamicGenerationSchema.Property] = []
        for property in schema.properties {
            let description = PlainText.sanitizeLine(property.description, limit: fieldDescriptionLimit)
            properties.append(
                DynamicGenerationSchema.Property(
                    name: property.name,
                    description: description.isEmpty ? nil : description,
                    schema: fieldSchema(for: property, toolName: toolName),
                    isOptional: !property.isRequired
                )
            )
        }
        let root = DynamicGenerationSchema(name: "\(toolName)_inputs", properties: properties)
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func fieldSchema(for property: ToolInputSchema.Property, toolName: String) -> DynamicGenerationSchema {
        switch property.kind {
        case .string:
            return DynamicGenerationSchema(type: String.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .choice(let values):
            return DynamicGenerationSchema(name: "\(toolName)_\(property.name)_choice", anyOf: values)
        case .integer:
            return DynamicGenerationSchema(type: Int.self, guides: integerGuides(property))
        case .number:
            return DynamicGenerationSchema(type: Double.self, guides: numberGuides(property))
        }
    }

    private static func integerGuides(_ property: ToolInputSchema.Property) -> [GenerationGuide<Int>] {
        let low = property.minimum.flatMap(clampedInt)
        let high = property.maximum.flatMap(clampedInt)
        switch (low, high) {
        case (let low?, let high?) where low <= high: return [.range(low...high)]
        case (let low?, nil): return [.minimum(low)]
        case (nil, let high?): return [.maximum(high)]
        default: return []
        }
    }

    private static func numberGuides(_ property: ToolInputSchema.Property) -> [GenerationGuide<Double>] {
        switch (property.minimum, property.maximum) {
        case (let low?, let high?) where low <= high: return [.range(low...high)]
        case (let low?, nil): return [.minimum(low)]
        case (nil, let high?): return [.maximum(high)]
        default: return []
        }
    }

    private static func clampedInt(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) < 9_007_199_254_740_992 else { return nil }
        return Int(value.rounded())
    }

    // MARK: Decoding what the model produced

    /// Turns the model's structure into argument values. Anything that is not a single text, number or yes/no value is
    /// reported as a problem so the call is refused. Unknown names are kept so validation can refuse them by name.
    static func decode(_ content: GeneratedContent) -> Result<[String: ToolArgumentValue], ToolArgumentError> {
        guard case .structure(let properties, let keys) = content.kind else {
            return .failure(ToolArgumentError(problems: [.wrongType("inputs", expected: "a set of named values")]))
        }
        var values: [String: ToolArgumentValue] = [:]
        var problems: [ToolArgumentProblem] = []
        for key in keys {
            guard let item = properties[key] else { continue }
            let shown = PlainText.sanitizeLine(key, limit: 40)
            switch item.kind {
            case .null:
                continue  // an optional field the model left out
            case .string(let text):
                if PlainText.containsHiddenCharacters(text) {
                    problems.append(.wrongType(shown, expected: "plain text without control or invisible characters"))
                } else {
                    values[key] = .string(text)
                }
            case .bool(let flag):
                values[key] = .boolean(flag)
            case .number(let number):
                if number.isFinite, number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
                    values[key] = .integer(Int(number))
                } else {
                    values[key] = .number(number)
                }
            case .array, .structure:
                problems.append(.wrongType(shown, expected: "a single text, number or yes/no value"))
            @unknown default:
                problems.append(.wrongType(shown, expected: "a single text, number or yes/no value"))
            }
        }
        guard problems.isEmpty else { return .failure(ToolArgumentError(problems: problems)) }
        return .success(values)
    }

    // MARK: Naming

    /// A model-facing tool name made from the server's name: letters, digits and underscores only, never empty, and
    /// different from every name in `taken`.
    static func modelName(for serverName: String, taken: Set<String>) -> String {
        var base = String(serverName.unicodeScalars.map { scalar -> Character in
            let isWord = (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) || scalar == "_"
            return isWord ? Character(scalar) : "_"
        })
        if base.isEmpty || !(base.first!.isLetter) { base = "tool_" + base }
        base = String(base.prefix(48))
        var candidate = base
        var counter = 2
        while taken.contains(candidate) || candidate == "searchMyFiles" {
            candidate = "\(base.prefix(44))_\(counter)"
            counter += 1
        }
        return candidate
    }
}
