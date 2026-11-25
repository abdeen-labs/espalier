// Tests never touch `UserDefaults.standard`.

import EspalierSupport
import Foundation

/// A `UserDefaults` domain for one test, kept in memory.
///
/// `defaults` is an `InMemoryDefaults`: what a test stores stays in the
/// process, without cfprefsd, and is what it reads back. Its name is a path
/// in a temporary directory, so the domain the superclass would use stays
/// out of `~/Library/Preferences`. Remove it when the test is done:
///
/// ```swift
/// let temporary = try TemporaryDefaults()
/// defer { temporary.remove() }
/// ```
public struct TemporaryDefaults: @unchecked Sendable {
    // `@unchecked`: `InMemoryDefaults` locks its values.

    public let defaults: UserDefaults
    public let suiteName: String

    public init() throws {
        suiteName = POSIXPath.join(try createTempDirectory(), "defaults")
        guard let defaults = InMemoryDefaults(suiteName: suiteName) else {
            throw TestSupportError("Could not create the defaults domain \(suiteName)")
        }
        self.defaults = defaults
    }

    /// Removes everything stored in the domain.
    public func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// A `UserDefaults` whose domain, named `suiteName`, lives in memory: a
/// value set is the value read back, on any thread, at once.
///
/// Reads and writes of values, the typed getters and setters (with
/// `UserDefaults`'s conversions between numbers, strings, and Booleans),
/// the registration domain, and the persistent domain named `suiteName`
/// all use the memory. Changes notify key-value observers of the key, as
/// `@AppStorage` observes, and post `didChangeNotification`. URLs, other
/// domains, and suites go to the superclass.
final class InMemoryDefaults: UserDefaults {
    private let name: String
    private let lock = NSLock()
    nonisolated(unsafe) private var values: [String: Any] = [:]
    nonisolated(unsafe) private var registered: [String: Any] = [:]

    override init?(suiteName suitename: String?) {
        name = suitename ?? ""
        super.init(suiteName: suitename)
    }

    // MARK: Values

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] ?? registered[defaultName] }
    }

    override func value(forKey key: String) -> Any? {
        object(forKey: key)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        guard let value else {
            removeObject(forKey: defaultName)
            return
        }
        // Stored as Foundation objects, as `UserDefaults` returns them: an
        // `Int` comes back an `NSNumber`, which `as? Bool` reads.
        let object = value as AnyObject
        Self.requirePropertyList(object, forKey: defaultName)
        change(defaultName) { $0[defaultName] = object }
    }

    /// Stops on a value that isn't a property list, which `UserDefaults`
    /// raises an exception for.
    private static func requirePropertyList(_ value: Any, forKey key: String) {
        precondition(
            PropertyListSerialization.propertyList(value, isValidFor: .binary),
            "Attempt to set a non-property-list object as a defaults value for key \(key)"
        )
    }

    override func removeObject(forKey defaultName: String) {
        change(defaultName) { $0[defaultName] = nil }
    }

    /// Changes `values` under the lock, then tells observers of `key`.
    private func change(_ key: String, _ body: (inout [String: Any]) -> Void) {
        willChangeValue(forKey: key)
        lock.withLock { body(&values) }
        didChangeValue(forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    // MARK: Typed getters

    override func string(forKey defaultName: String) -> String? {
        switch object(forKey: defaultName) {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    override func array(forKey defaultName: String) -> [Any]? {
        object(forKey: defaultName) as? [Any]
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }

    override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    override func stringArray(forKey defaultName: String) -> [String]? {
        guard let array = object(forKey: defaultName) as? [Any] else {
            return nil
        }
        let strings = array.compactMap { $0 as? String }
        return strings.count == array.count ? strings : nil
    }

    override func integer(forKey defaultName: String) -> Int {
        switch object(forKey: defaultName) {
        case let number as NSNumber: number.intValue
        case let string as NSString: string.integerValue
        default: 0
        }
    }

    override func float(forKey defaultName: String) -> Float {
        Float(double(forKey: defaultName))
    }

    override func double(forKey defaultName: String) -> Double {
        switch object(forKey: defaultName) {
        case let number as NSNumber: number.doubleValue
        case let string as NSString: string.doubleValue
        default: 0
        }
    }

    override func bool(forKey defaultName: String) -> Bool {
        switch object(forKey: defaultName) {
        case let number as NSNumber: number.boolValue
        case let string as NSString: string.boolValue
        default: false
        }
    }

    // MARK: Typed setters

    override func set(_ value: Int, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }

    override func set(_ value: Float, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }

    override func set(_ value: Double, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }

    // MARK: Domains

    override func register(defaults registrationDictionary: [String: Any]) {
        lock.withLock { registered.merge(registrationDictionary) { _, new in new } }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { registered.merging(values) { _, stored in stored } }
    }

    override func persistentDomain(forName domainName: String) -> [String: Any]? {
        guard domainName == name else {
            return super.persistentDomain(forName: domainName)
        }
        return lock.withLock { values.isEmpty ? nil : values }
    }

    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        guard domainName == name else {
            super.setPersistentDomain(domain, forName: domainName)
            return
        }
        let objects = domain.mapValues { $0 as AnyObject }
        for (key, object) in objects {
            Self.requirePropertyList(object, forKey: key)
        }
        lock.withLock { values = objects }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    override func removePersistentDomain(forName domainName: String) {
        guard domainName == name else {
            super.removePersistentDomain(forName: domainName)
            return
        }
        lock.withLock { values = [:] }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    override func synchronize() -> Bool {
        true
    }
}
