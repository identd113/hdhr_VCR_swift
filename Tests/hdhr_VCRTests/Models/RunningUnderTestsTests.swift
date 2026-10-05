import Testing
import Foundation
@testable import hdhr_VCR

@Suite("Test isolation")
struct RunningUnderTestsTests {
    @Test func testsNeverWriteToTheLiveLogFolder() {
        #expect(runningUnderTests)
        #expect(!appLogsDirectory.hasSuffix("/Library/Logs"))
        #expect(logFilePath.hasPrefix(NSTemporaryDirectory()))
        #expect(discordLogFilePath.hasPrefix(NSTemporaryDirectory()))
        #expect(curlVerboseLogFilePath.hasPrefix(NSTemporaryDirectory()))
    }
}
