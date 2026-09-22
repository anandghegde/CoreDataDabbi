import Foundation

enum AppEnvironment {
    /// The app also runs as the host of its own unit tests, where it must not open windows of its own accord
    /// or tidy up files a second copy of the app may be using.
    static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}
