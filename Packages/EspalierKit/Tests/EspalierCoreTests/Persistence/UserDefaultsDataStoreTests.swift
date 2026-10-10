// The UserDefaults store that GitHubKit's accounts and endpoint versions
// use.

@testable import EspalierCore
import Foundation
import GitHubKit
import Testing
import TestSupport

@Suite("UserDefaultsDataStore")
struct UserDefaultsDataStoreTests {
    @Test("reads a value that isn't a string as nothing")
    func otherTypes() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let store = UserDefaultsDataStore(temporary.defaults)

        for value: Any in [5, true, Data("[]".utf8), ["[]"]] {
            temporary.defaults.set(value, forKey: "users")
            #expect(store.getItem("users") == nil)
        }
    }

    @Test("keeps GitHub Enterprise versions under desktop's key, across launches")
    func endpointVersions() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let endpoint = "https://ghe.example.com/api/v3"

        EndpointVersionCache(dataStore: UserDefaultsDataStore(temporary.defaults)).updateEndpointVersion(endpoint, "3.14.2")
        #expect(temporary.defaults.string(forKey: "endpoint-version:\(endpoint)") == "3.14.2")

        let relaunched = EndpointVersionCache(dataStore: UserDefaultsDataStore(temporary.defaults))
        #expect(relaunched.getEndpointVersion(endpoint) == SemVer(major: 3, minor: 14, patch: 2))
    }
}
