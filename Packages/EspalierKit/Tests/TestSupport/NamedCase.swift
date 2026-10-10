import Testing

/// One case of a parameterized test, labeled with its name in the results.
///
/// Where cases of the same shape would be one test per input, they're one
/// `@Test(arguments:)` over `NamedCase`s, each named as its test was, so
/// each case still shows that name:
///
/// ```swift
/// @Test("reads git's booleans", arguments: [
///     NamedCase("treats \"off\" as false", (value: "off", expected: false)),
///     NamedCase("treats \"on\" as true", (value: "on", expected: true)),
/// ])
/// func booleans(_ testCase: NamedCase<(value: String, expected: Bool)>) {
///     let (value, expected) = testCase.value
///     ...
/// }
/// ```
///
/// A case's comments stay next to its row.
public struct NamedCase<Value: Sendable>: Sendable, CustomTestStringConvertible {
    /// The case's name, shown in the results.
    public let name: String
    /// The case's input and expected output.
    public let value: Value

    public init(_ name: String, _ value: Value) {
        self.name = name
        self.value = value
    }

    public var testDescription: String { name }
}
