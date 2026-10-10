// espalier-askpass: git's way back into Espalier for SSH prompts, HTTPS
// credentials, and hooks. See Helper.swift.

import Foundation

exit(Helper.run(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment))
