import Foundation
import MCP

/// Fictional project data served by the fixture. Nothing here is real: every name, date and number is invented for
/// demonstrations and tests.
enum ProjectLumen {
    static let name = "Project Lumen"

    static let statusText = """
        Project Lumen (fictional demo project)
        Phase: Beta hardening
        Launch date: 14 October
        Owner: Dana Whitfield
        Budget: $480,000 approved, $312,500 spent (65%)
        Open risks:
        1. Supplier delay for display panels (medium)
        2. Two open accessibility findings (low)
        3. Launch-week support staffing not confirmed (high)
        """

    struct Note {
        let date: String
        let text: String
    }

    static let notes: [Note] = [
        Note(date: "2 September", text: "Dana Whitfield confirmed the launch date of 14 October after the steering review."),
        Note(date: "5 September", text: "Budget check: $312,500 spent of $480,000. Display panel supplier quoted a two-week delay."),
        Note(date: "9 September", text: "Accessibility review found two open findings: focus order in the setup flow and a low-contrast label."),
        Note(date: "12 September", text: "Support staffing for launch week is not confirmed. Dana asked operations for a named on-call list."),
        Note(date: "16 September", text: "Beta feedback: testers liked the quick-open panel and asked for clearer error messages."),
        Note(date: "19 September", text: "Risk review: staffing is the highest risk. Supplier delay is medium and has a fallback panel."),
        Note(date: "23 September", text: "Launch checklist drafted. Owner for each item is Dana Whitfield unless noted."),
        Note(date: "26 September", text: "Press briefing scheduled for 7 October. Budget for launch events is $18,000."),
    ]

    static func isLumen(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "project lumen" || normalized == "lumen"
    }

    static func search(_ query: String, limit: Int) -> [Note] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        guard !words.isEmpty else { return [] }
        let scored = notes.map { note -> (Note, Int) in
            let haystack = (note.text + " " + note.date).lowercased()
            return (note, words.filter { haystack.contains($0) }.count)
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

/// Tool definitions and behavior. Exactly two retrieval tools by default; the demo set adds more so the five-tool
/// cap and the unsupported-schema explanation can be shown.
enum FixtureTools {
    static let statusToolName = "get_project_status"
    static let searchToolName = "search_project_notes"

    static func definitions(includeDemoTools: Bool, paddingBytes: Int) -> [Tool] {
        let padding = paddingBytes > 0 ? "\n" + String(repeating: "padding ", count: paddingBytes / 8) : ""
        var tools: [Tool] = [
            Tool(
                name: statusToolName,
                title: "Get project status",
                description: "Returns the launch date, owner, budget and open risks for a project. Demo data only; the only project is “Project Lumen”." + padding,
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "project": .object(["type": "string", "description": "The project name, for example Project Lumen."])
                    ]),
                    "required": .array(["project"]),
                ]),
                annotations: .init(title: "Get project status", readOnlyHint: true)
            ),
            Tool(
                name: searchToolName,
                title: "Search project notes",
                description: "Searches the project notes for words and returns the best matching notes. Demo data only.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "query": .object(["type": "string", "description": "Words to look for, for example budget or staffing."]),
                        "limit": .object([
                            "type": "integer", "minimum": 1, "maximum": 10,
                            "description": "How many notes to return (1 to 10). Defaults to 3.",
                        ]),
                    ]),
                    "required": .array(["query"]),
                ]),
                annotations: .init(title: "Search project notes", readOnlyHint: true)
            ),
        ]
        guard includeDemoTools else { return tools }
        tools += [
            Tool(
                name: "list_milestones",
                title: "List milestones",
                description: "Lists milestones for one phase of Project Lumen, or all phases.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "phase": .object(["type": "string", "enum": .array(["Design", "Build", "Beta", "Launch"]), "description": "Which phase to list."])
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "get_risk_detail",
                title: "Get risk detail",
                description: "Returns one risk by number.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "risk_id": .object(["type": "integer", "minimum": 1, "maximum": 3, "description": "Risk number, 1 to 3."])
                    ]),
                    "required": .array(["risk_id"]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "budget_summary",
                title: "Budget summary",
                description: "Returns approved and spent budget, optionally with a forecast.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "include_forecast": .object(["type": "boolean", "description": "Add a spending forecast."])
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "team_contacts",
                title: "Team contacts",
                description: "Returns the fictional contact for a team.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "team": .object(["type": "string", "enum": .array(["Design", "Engineering", "Operations"])])
                    ]),
                    "required": .array(["team"]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "find_dependencies",
                title: "Find dependencies",
                description: "Finds dependencies using a nested filter. This tool uses a nested object input, which DeskMate does not support.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "filter": .object([
                            "type": "object",
                            "properties": .object(["kind": .object(["type": "string"])]),
                        ])
                    ]),
                ])
            ),
            Tool(
                name: "bulk_status",
                title: "Bulk status",
                description: "Returns status for a list of projects. This tool uses a list input, which DeskMate does not support.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "projects": .object(["type": "array", "items": .object(["type": "string"])])
                    ]),
                    "required": .array(["projects"]),
                ])
            ),
        ]
        return tools
    }

    static func call(
        name: String,
        arguments: [String: Value]?,
        paddingBytes: Int
    ) -> CallTool.Result {
        let arguments = arguments ?? [:]
        func failure(_ text: String) -> CallTool.Result {
            reply(text, isError: true)
        }
        func reply(_ text: String, isError: Bool = false) -> CallTool.Result {
            .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
        }
        let pad = paddingBytes > 0 ? "\n" + String(repeating: "padding ", count: paddingBytes / 8) : ""

        switch name {
        case statusToolName:
            guard case .string(let project)? = arguments["project"] else { return failure("“project” must be text.") }
            guard ProjectLumen.isLumen(project) else {
                let shown = String(project.prefix(60))
                return failure("No project named “\(shown)” in this demo. The only project is Project Lumen.")
            }
            return reply(ProjectLumen.statusText + pad)

        case searchToolName:
            guard case .string(let query)? = arguments["query"] else { return failure("“query” must be text.") }
            var limit = 3
            switch arguments["limit"] {
            case nil, .some(.null): break
            case .some(.int(let value)) where (1...10).contains(value): limit = value
            default: return failure("“limit” must be a whole number from 1 to 10.")
            }
            let found = ProjectLumen.search(query, limit: limit)
            guard !found.isEmpty else { return reply("No notes matched.") }
            let lines = found.map { "- \($0.date): \($0.text)" }.joined(separator: "\n")
            return reply("Matching notes (demo data):\n" + lines + pad)

        case "list_milestones":
            let phase = arguments["phase"]?.stringValue
            let all = [
                ("Design", "Design freeze: 3 June"),
                ("Build", "Feature complete: 29 July"),
                ("Beta", "Beta exit: 30 September"),
                ("Launch", "Launch: 14 October"),
            ]
            let lines = all.filter { phase == nil || $0.0 == phase }.map { "- \($0.1)" }
            return reply("Milestones (demo data):\n" + lines.joined(separator: "\n"))

        case "get_risk_detail":
            guard case .int(let id)? = arguments["risk_id"], (1...3).contains(id) else { return failure("“risk_id” must be 1, 2 or 3.") }
            let risks = [
                "Supplier delay for display panels: medium. Fallback panel qualified.",
                "Two open accessibility findings: low. Fixes scheduled this sprint.",
                "Launch-week support staffing not confirmed: high. Owner: Dana Whitfield.",
            ]
            return reply("Risk \(id): \(risks[id - 1])")

        case "budget_summary":
            var text = "Approved $480,000. Spent $312,500 (65%)."
            if arguments["include_forecast"]?.boolValue == true { text += " Forecast at launch: $455,000." }
            return reply(text)

        case "team_contacts":
            let contacts = ["Design": "Priya Raman", "Engineering": "Tomas Lindqvist", "Operations": "Mei Okafor"]
            guard let team = arguments["team"]?.stringValue, let contact = contacts[team] else { return failure("Unknown team.") }
            return reply("\(team) contact (fictional): \(contact)")

        default:
            return failure("Unknown tool.")
        }
    }
}
