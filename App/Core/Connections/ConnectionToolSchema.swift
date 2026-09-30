import CryptoKit
import Foundation
import MCP

/// Hard limits that keep a connection bounded. Everything a server can influence is capped here.
public struct ConnectionLimits: Sendable, Equatable {
    /// Tools the user may have turned on in total across all connections (spec section 7), so the tool list never
    /// crowds the model's context. Selections on a turned-off connection still count: they return when it is turned on.
    public var maxEnabledTools = 5
    /// Tools accepted from one server listing; the rest are ignored with a notice.
    public var maxListedTools = 64
    /// Fields in one tool's input description.
    public var maxSchemaProperties = 12
    /// Choices in one enumerated field.
    public var maxEnumChoices = 50
    /// Longest text argument a tool call may carry.
    public var maxStringArgumentLength = 2_000
    /// Bytes accepted from the server for one reply.
    public var maxResponseBytes = 256 * 1024
    /// Characters of tool output kept after a call.
    public var maxToolOutputCharacters = 12_000
    /// Seconds before a connect or list request is abandoned.
    public var requestTimeout: TimeInterval = 15
    /// Seconds before a tool call is abandoned.
    public var toolCallTimeout: TimeInterval = 30

    public init() {}
}

// MARK: - Argument values

/// One argument value a tool call can carry. Only the kinds the supported schema subset allows.
public enum ToolArgumentValue: Sendable, Hashable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)

    var mcpValue: Value {
        switch self {
        case .string(let value): .string(value)
        case .integer(let value): .int(value)
        case .number(let value): .double(value)
        case .boolean(let value): .bool(value)
        }
    }
}

/// Arguments that passed schema validation. The only way to obtain one is `ToolInputSchema.validate`,
/// so a request can never be built from unchecked input.
public struct ValidatedToolArguments: Sendable, Hashable {
    public let values: [String: ToolArgumentValue]

    fileprivate init(values: [String: ToolArgumentValue]) {
        self.values = values
    }

    var mcpValues: [String: Value] { values.mapValues(\.mcpValue) }
}

public enum ToolArgumentProblem: Error, Sendable, Equatable {
    case unknownArgument(String)
    case missing(String)
    case wrongType(String, expected: String)
    case notAChoice(String, allowed: [String])
    case outOfRange(String, detail: String)
    case tooLong(String, limit: Int)

    public var message: String {
        switch self {
        case .unknownArgument(let name): "“\(name)” is not an input this tool accepts."
        case .missing(let name): "“\(name)” is required."
        case .wrongType(let name, let expected): "“\(name)” must be \(expected)."
        case .notAChoice(let name, let allowed): "“\(name)” must be one of: \(allowed.joined(separator: ", "))."
        case .outOfRange(let name, let detail): "“\(name)” \(detail)."
        case .tooLong(let name, let limit): "“\(name)” is longer than \(limit) characters."
        }
    }
}

public struct ToolArgumentError: Error, Sendable, Equatable {
    public let problems: [ToolArgumentProblem]

    public var message: String {
        problems.map(\.message).joined(separator: " ")
    }
}

// MARK: - Schema

/// The supported subset of a tool's input description: an object whose fields are text, numbers, whole numbers,
/// yes/no values or a fixed list of text choices, plus a list of required fields. Nothing else can be enabled.
public struct ToolInputSchema: Sendable, Hashable {
    public struct Property: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            case string
            case number
            case integer
            case boolean
            case choice([String])
        }

        public var id: String { name }
        public let name: String
        public let kind: Kind
        public let description: String
        public let isRequired: Bool
        public let minimum: Double?
        public let maximum: Double?
        public let minLength: Int?
        public let maxLength: Int?

        /// Plain-language type for display.
        public var kindLabel: String {
            switch kind {
            case .string: "text"
            case .number: "number"
            case .integer: "whole number"
            case .boolean: "yes or no"
            case .choice(let values): "one of: " + values.joined(separator: ", ")
            }
        }
    }

    public let properties: [Property]

    public var requiredNames: [String] { properties.filter(\.isRequired).map(\.name) }

    /// Checks every argument before anything is sent. Unknown names, wrong types and out-of-range values are refused.
    public func validate(
        _ arguments: [String: ToolArgumentValue],
        limits: ConnectionLimits = ConnectionLimits()
    ) -> Result<ValidatedToolArguments, ToolArgumentError> {
        var problems: [ToolArgumentProblem] = []
        var normalized: [String: ToolArgumentValue] = [:]
        let byName = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0) })

        for name in arguments.keys.sorted() where byName[name] == nil {
            problems.append(.unknownArgument(PlainText.sanitizeLine(name, limit: 40)))
        }
        for property in properties {
            guard let value = arguments[property.name] else {
                if property.isRequired { problems.append(.missing(property.name)) }
                continue
            }
            switch check(value, against: property, limits: limits) {
            case .success(let checked): normalized[property.name] = checked
            case .failure(let problem): problems.append(problem)
            }
        }
        guard problems.isEmpty else { return .failure(ToolArgumentError(problems: problems)) }
        return .success(ValidatedToolArguments(values: normalized))
    }

    private func check(
        _ value: ToolArgumentValue,
        against property: Property,
        limits: ConnectionLimits
    ) -> Result<ToolArgumentValue, ToolArgumentProblem> {
        let name = property.name
        switch (property.kind, value) {
        case (.string, .string(let text)):
            let cap = min(property.maxLength ?? limits.maxStringArgumentLength, limits.maxStringArgumentLength)
            if text.count > cap { return .failure(.tooLong(name, limit: cap)) }
            if let minLength = property.minLength, text.count < minLength {
                return .failure(.outOfRange(name, detail: "must be at least \(minLength) characters"))
            }
            return .success(value)
        case (.choice(let allowed), .string(let text)):
            return allowed.contains(text) ? .success(value) : .failure(.notAChoice(name, allowed: allowed))
        case (.boolean, .boolean):
            return .success(value)
        case (.integer, .integer(let number)):
            return inRange(Double(number), property) ? .success(value) : .failure(rangeProblem(property))
        case (.integer, .number(let number)):
            guard number.isFinite, number == number.rounded(), abs(number) < 9_007_199_254_740_992 else {
                return .failure(.wrongType(name, expected: "a whole number"))
            }
            return inRange(number, property) ? .success(.integer(Int(number))) : .failure(rangeProblem(property))
        case (.number, .integer(let number)):
            return inRange(Double(number), property) ? .success(value) : .failure(rangeProblem(property))
        case (.number, .number(let number)):
            guard number.isFinite else { return .failure(.wrongType(name, expected: "a finite number")) }
            return inRange(number, property) ? .success(value) : .failure(rangeProblem(property))
        default:
            return .failure(.wrongType(name, expected: "a value of type \(property.kindLabel)"))
        }
    }

    private func inRange(_ number: Double, _ property: Property) -> Bool {
        if let minimum = property.minimum, number < minimum { return false }
        if let maximum = property.maximum, number > maximum { return false }
        return true
    }

    private func rangeProblem(_ property: Property) -> ToolArgumentProblem {
        switch (property.minimum, property.maximum) {
        case (let low?, let high?): .outOfRange(property.name, detail: "must be between \(format(low)) and \(format(high))")
        case (let low?, nil): .outOfRange(property.name, detail: "must be at least \(format(low))")
        case (nil, let high?): .outOfRange(property.name, detail: "must be at most \(format(high))")
        default: .outOfRange(property.name, detail: "is out of range")
        }
    }

    private func format(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }
}

public enum ToolSchemaSupport: Sendable, Hashable {
    case supported(ToolInputSchema)
    case unsupported(reasons: [String])

    public var schema: ToolInputSchema? {
        if case .supported(let schema) = self { return schema }
        return nil
    }

    public var isSupported: Bool { schema != nil }

    public var reasons: [String] {
        if case .unsupported(let reasons) = self { return reasons }
        return []
    }
}

extension ToolInputSchema {
    private static let rootKeys: Set<String> = [
        "type", "properties", "required", "description", "title", "additionalProperties", "$schema",
    ]
    private static let propertyKeys: Set<String> = [
        "type", "description", "title", "default", "enum", "minimum", "maximum", "minLength", "maxLength",
        "format", "examples",
    ]

    /// Reads a server-provided input description. Anything outside the supported subset is reported in plain
    /// language and the tool cannot be enabled.
    public static func evaluate(_ value: Value, limits: ConnectionLimits = ConnectionLimits()) -> ToolSchemaSupport {
        guard case .object(let root) = value else {
            return .unsupported(reasons: ["The tool’s input description is not an object."])
        }
        var reasons: [String] = []

        if root["type"]?.stringValue != "object" {
            reasons.append("The tool’s input is not described as an object with named fields.")
        }
        for key in root.keys.sorted() where !rootKeys.contains(key) {
            reasons.append("The input description uses “\(label(key))”, which DeskMate cannot check.")
        }
        if let extra = root["additionalProperties"], extra != .bool(true), extra != .bool(false) {
            reasons.append("The input description allows extra fields in a form DeskMate cannot check.")
        }

        var definitions: [String: Value] = [:]
        switch root["properties"] {
        case nil, .some(.null):
            break
        case .some(.object(let object)):
            definitions = object
        default:
            reasons.append("The tool’s fields are not described as a list of named fields.")
        }
        if definitions.count > limits.maxSchemaProperties {
            reasons.append("The tool has more than \(limits.maxSchemaProperties) input fields.")
        }

        var requiredNames = Set<String>()
        switch root["required"] {
        case nil, .some(.null):
            break
        case .some(.array(let items)):
            for item in items {
                if let name = item.stringValue {
                    requiredNames.insert(name)
                } else {
                    reasons.append("The list of required fields contains something that is not a field name.")
                    break
                }
            }
        default:
            reasons.append("The list of required fields is not a list.")
        }
        for name in requiredNames.sorted() where definitions[name] == nil {
            reasons.append("The required field “\(label(name))” is not described, so DeskMate cannot provide it.")
        }

        var properties: [Property] = []
        for name in definitions.keys.sorted() {
            guard IdentifierRules.isSafe(name) else {
                reasons.append("A field name “\(label(name))” uses unusual characters.")
                continue
            }
            switch property(named: name, definition: definitions[name]!, required: requiredNames.contains(name), limits: limits) {
            case .success(let property): properties.append(property)
            case .failure(let problem): reasons.append(problem.reason)
            }
        }

        guard reasons.isEmpty else { return .unsupported(reasons: reasons) }
        return .supported(ToolInputSchema(properties: properties))
    }

    private struct PropertyProblem: Error {
        let reason: String
    }

    private static func label(_ text: String) -> String {
        PlainText.sanitizeLine(text, limit: 40)
    }

    private static func property(
        named name: String,
        definition: Value,
        required: Bool,
        limits: ConnectionLimits
    ) -> Result<Property, PropertyProblem> {
        func fail(_ text: String) -> Result<Property, PropertyProblem> {
            .failure(PropertyProblem(reason: "Field “\(name)”: \(text)"))
        }
        guard case .object(let object) = definition else { return fail("its description is not an object.") }
        for key in object.keys.sorted() where !propertyKeys.contains(key) {
            return fail("uses “\(label(key))”, which DeskMate cannot check.")
        }

        let description = PlainText.sanitize(object["description"]?.stringValue ?? "", limit: 300)
        let typeName: String?
        switch object["type"] {
        case nil: typeName = nil
        case .some(.string(let text)): typeName = text
        default: return fail("has more than one possible type.")
        }

        let kind: Property.Kind
        if let choices = object["enum"] {
            guard typeName == nil || typeName == "string" else { return fail("has a list of choices that are not text.") }
            guard case .array(let items) = choices, !items.isEmpty, items.count <= limits.maxEnumChoices else {
                return fail("has no usable list of choices.")
            }
            var values: [String] = []
            for item in items {
                guard let text = item.stringValue, !text.isEmpty, text.count <= 100 else {
                    return fail("has choices that are not short text values.")
                }
                values.append(text)
            }
            kind = .choice(values)
        } else {
            switch typeName {
            case "string": kind = .string
            case "number": kind = .number
            case "integer": kind = .integer
            case "boolean": kind = .boolean
            case nil: return fail("has no type.")
            case .some(let other): return fail("has type “\(label(other))”, which DeskMate does not support.")
            }
        }

        func number(_ key: String) -> Double? {
            switch object[key] {
            case .some(.int(let value)): Double(value)
            case .some(.double(let value)) where value.isFinite: value
            default: nil
            }
        }
        func count(_ key: String) -> Int? {
            if case .some(.int(let value)) = object[key], value >= 0 { return value }
            return nil
        }

        return .success(
            Property(
                name: name,
                kind: kind,
                description: description,
                isRequired: required,
                minimum: number("minimum"),
                maximum: number("maximum"),
                minLength: count("minLength"),
                maxLength: count("maxLength")
            )
        )
    }

    /// Stable fingerprint of a tool as the server described it. A change after the user enabled the tool turns it off.
    static func fingerprint(name: String, title: String?, description: String?, inputSchema: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let schemaData = (try? encoder.encode(inputSchema)) ?? Data()
        var hasher = SHA256()
        for part in [name, title ?? "", description ?? ""] {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        hasher.update(data: schemaData)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
