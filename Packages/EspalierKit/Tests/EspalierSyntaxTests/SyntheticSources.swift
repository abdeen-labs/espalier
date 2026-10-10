// Long, realistic source files for the highlighter's performance tests, made
// by repeating a varied template.

import Foundation

enum SyntheticSources {
    /// At least `count` lines of Swift, in whole declarations.
    static func swift(lines count: Int) -> [String] {
        repeated(swiftTemplate, count)
    }

    /// At least `count` lines of TypeScript, in whole declarations.
    static func typeScript(lines count: Int) -> [String] {
        repeated(typeScriptTemplate, count)
    }

    private static func repeated(_ template: (Int) -> [String], _ count: Int) -> [String] {
        var lines: [String] = []
        var index = 0
        while lines.count < count {
            lines += template(index)
            index += 1
        }
        return lines
    }

    private static func swiftTemplate(_ i: Int) -> [String] {
        """
        /// A model of item \(i), with its tags.
        struct Item\(i): Codable, Hashable, Sendable {
            let id: Int
            var name: String = "Item \(i)"
            private(set) var tags: [String] = []

            init(id: Int, name: String) {
                self.id = id
                self.name = name
            }

            func describe(prefix: String = ">") -> String {
                // Build a description of the item.
                let count = tags.count * 2 + \(i)
                guard count > 0 else { return "\\(prefix) empty" }
                return "\\(prefix) \\(name) [\\(count)]"
            }

            mutating func add(_ tag: String) throws {
                if tag.isEmpty { throw ItemError\(i).invalid(tag) }
                tags.append(tag.lowercased())
            }
        }

        enum ItemError\(i): Error {
            case invalid(String)
            case missing(id: Int)
        }

        extension Item\(i) {
            static let all: [Item\(i)] = (0..<10).map { Item\(i)(id: $0, name: "n\\($0)") }

            @MainActor
            func load() async throws -> [Int] {
                let values = try await withThrowingTaskGroup(of: Int.self) { group in
                    for value in 0..<3 { group.addTask { value * 0x1F } }
                    return try await group.reduce(into: []) { $0.append($1) }
                }
                return values.sorted(by: >)
            }
        }

        """.components(separatedBy: "\n")
    }

    private static func typeScriptTemplate(_ i: Int) -> [String] {
        """
        /** A store for items of kind \(i). */
        export interface Item\(i) {
          readonly id: number
          name: string
          tags?: ReadonlyArray<string>
        }

        export class Store\(i)<T extends Item\(i)> extends BaseStore {
          private readonly items = new Map<number, T>()
          public static readonly limit = 0x\(String(i, radix: 16))

          public constructor(private readonly name: string = 'store-\(i)') {
            super()
          }

          public async load(ids: number[]): Promise<T[]> {
            // Fetch the items in parallel.
            const results = await Promise.all(ids.map(id => this.fetch(id)))
            return results.filter((item): item is T => item !== undefined)
          }

          private fetch(id: number): Promise<T | undefined> {
            if (id < 0 || id > Store\(i).limit) {
              throw new Error(`Invalid id ${id} in ${this.name}`)
            }
            return Promise.resolve(this.items.get(id))
          }

          public get count(): number {
            return this.items.size * 2 + \(i)
          }
        }

        export function describe\(i)(item: Item\(i)): string {
          const tags = item.tags?.join(', ') ?? 'none'
          return `${item.name} (${tags})`
        }

        """.components(separatedBy: "\n")
    }
}
