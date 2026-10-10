// Ported from dugite/test/fast/environment-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

/// The tests pass the runtime's `processEnvironment` explicitly instead of
/// mutating the process environment, so they stay safe to run in parallel.
@Suite("environment variables")
struct DugiteEnvironmentTests {
    @Test("when GIT_EXEC_PATH environment variable is *not* set, it will be calculated")
    func calculatesGitExecPathWhenNotSet() {
        let runtime = TestEnvironment.runtime
        let processEnv = runtime.processEnvironment
        #expect(processEnv["GIT_EXEC_PATH"] == nil)
        let (env, _) = Dugite.setupEnvironment([:], processEnv: processEnv, gitDir: Dugite.resolveGitDir(runtime))
        #expect(env["GIT_EXEC_PATH"]?.isEmpty == false)
    }

    @Test("when GIT_EXEC_PATH environment variable is set, that will be used as is")
    func usesGitExecPathAsIsWhenSet() {
        let runtime = TestEnvironment.runtime
        var processEnv = runtime.processEnvironment
        #expect(processEnv["GIT_EXEC_PATH"] == nil)
        processEnv["GIT_EXEC_PATH"] = #filePath
        let (env, _) = Dugite.setupEnvironment([:], processEnv: processEnv, gitDir: Dugite.resolveGitDir(runtime))
        #expect(env["GIT_EXEC_PATH"] == #filePath)
    }
}
