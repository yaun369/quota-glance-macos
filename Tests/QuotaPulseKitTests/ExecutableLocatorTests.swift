#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class ExecutableLocatorTests: XCTestCase {
    /// What a GUI app inherits when it is launched from Finder, the Dock or as
    /// a login item — none of the places a developer installs tools into.
    private static let launchdPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeLocator(
        path: String = ExecutableLocatorTests.launchdPath,
        loginShellLookup: @escaping @Sendable (String, Bool) -> String? = { _, _ in nil }
    ) -> ExecutableLocator {
        ExecutableLocator(
            environment: ["PATH": path],
            homeDirectory: home,
            // Scanning the real /opt/homebrew/bin would let whatever the
            // machine running the tests has installed decide the outcome.
            systemDirectories: [],
            loginShellLookup: loginShellLookup
        )
    }

    @discardableResult
    private func installExecutable(_ name: String, in directory: String) throws -> String {
        let directoryURL = home.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let executableURL = directoryURL.appendingPathComponent(name)
        try "#!/bin/bash\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        return executableURL.path
    }

    /// The regression this whole type exists for: `npm install -g` puts the
    /// binary under the npm prefix, which is not on a GUI app's `PATH`, so the
    /// app used to report "not installed" for a working install.
    func testFindsToolInstalledByNpmUnderACustomPrefix() throws {
        let installed = try installExecutable("codex", in: ".npm-global/bin")
        XCTAssertEqual(makeLocator().locate("codex"), installed)
    }

    /// nvm is the most common way a Node install ends up outside `PATH`, and
    /// its bin directory is versioned, so it has to be discovered by scanning.
    func testFindsToolUnderNodeVersionManagerAndPrefersTheNewestVersion() throws {
        try installExecutable("codex", in: ".nvm/versions/node/v18.20.0/bin")
        let newest = try installExecutable("codex", in: ".nvm/versions/node/v20.20.0/bin")

        // Plain string ordering would put v18 after v20 ("v18" < "v20" is fine,
        // but "v9" > "v20"), so the sort has to be numeric.
        try installExecutable("codex", in: ".nvm/versions/node/v9.11.2/bin")

        XCTAssertEqual(makeLocator().locate("codex"), newest)
    }

    func testFindsToolUnderThePrefixRecordedInNpmrc() throws {
        let installed = try installExecutable("codex", in: "elsewhere/npm/bin")
        try "prefix = \(home.appendingPathComponent("elsewhere/npm").path)\n"
            .write(to: home.appendingPathComponent(".npmrc"), atomically: true, encoding: .utf8)

        XCTAssertEqual(makeLocator().locate("codex"), installed)
    }

    func testExpandsATildePrefixInNpmrc() throws {
        let installed = try installExecutable("codex", in: "npm-prefix/bin")
        try "prefix=~/npm-prefix\n"
            .write(to: home.appendingPathComponent(".npmrc"), atomically: true, encoding: .utf8)

        XCTAssertEqual(makeLocator().locate("codex"), installed)
    }

    func testStillHonoursTheInheritedPathWhenTheAppIsLaunchedFromATerminal() throws {
        let installed = try installExecutable("codex", in: "opt/custom/bin")
        let directory = home.appendingPathComponent("opt/custom/bin").path

        XCTAssertEqual(
            makeLocator(path: "\(Self.launchdPath):\(directory)").locate("codex"),
            installed
        )
    }

    func testAsksTheLoginShellOnlyAfterTheDirectoryScanFails() throws {
        let installed = try installExecutable("codex", in: ".npm-global/bin")
        let askedShell = LockedFlag()

        let locator = makeLocator(loginShellLookup: { _, _ in
            askedShell.set()
            return "/somewhere/exotic/codex"
        })

        XCTAssertEqual(locator.locate("codex"), installed)
        XCTAssertFalse(askedShell.value, "the scan already answered; spawning a shell is wasted work")
    }

    func testFallsBackToTheLoginShellForSetupsTheScanCannotEnumerate() {
        let locator = makeLocator(loginShellLookup: { name, allowSpawn in
            allowSpawn ? "/volumes/work/\(name)" : nil
        })

        XCTAssertEqual(locator.locate("codex"), "/volumes/work/codex")
    }

    /// The main actor builds the menu with this, and spawning a login shell
    /// there would block the UI for as long as the user's `.zshrc` takes.
    func testDoesNotSpawnALoginShellWhenTheCallerForbidsIt() {
        let locator = makeLocator(loginShellLookup: { _, allowSpawn in
            allowSpawn ? "/volumes/work/codex" : nil
        })

        XCTAssertNil(locator.locate("codex", allowLoginShell: false))
    }

    func testReturnsNilWhenTheToolIsGenuinelyNotInstalled() {
        XCTAssertNil(makeLocator().locate("codex"))
    }

    // MARK: - Login shell output parsing

    /// Built from the marker rather than spelled out, so renaming it cannot
    /// leave these tests passing against a format nothing produces.
    private func markedOutput(_ value: String, noise: String = "") -> String {
        let marker = LoginShellLookup.marker
        return "\(noise)\(marker):\(value):\(marker)"
    }

    func testExtractsThePathFromBetweenTheMarkersDespiteStartupFileNoise() {
        let output = markedOutput("/bin/ls", noise: "Welcome back! You have 3 new messages.\n")

        XCTAssertEqual(LoginShellLookup.extractMarkedPath(from: output), "/bin/ls")
    }

    /// `command -v` also answers for builtins, functions and aliases, none of
    /// which can be handed to `Process`.
    func testRejectsAShellBuiltinOrAliasReportedByCommandV() {
        XCTAssertNil(LoginShellLookup.extractMarkedPath(from: markedOutput("cd")))
        XCTAssertNil(LoginShellLookup.extractMarkedPath(from: markedOutput("")))
        XCTAssertNil(LoginShellLookup.extractMarkedPath(from: markedOutput("/nonexistent/codex")))
    }

    func testRejectsOutputWithoutMarkersRatherThanGuessing() {
        XCTAssertNil(LoginShellLookup.extractMarkedPath(from: "/bin/ls\n"))
        XCTAssertNil(LoginShellLookup.extractMarkedPath(from: ""))
    }

    // MARK: - Memoization

    func testCachesAResolvedPathSoTheMainActorCanReadItWithoutSpawning() {
        let spawns = LockedCounter()
        let lookup = LoginShellLookup(shells: ["/bin/zsh"], spawn: { _, _, _ in
            spawns.increment()
            return self.markedOutput("/bin/ls")
        })

        XCTAssertEqual(lookup.path(of: "ls", allowSpawn: true), "/bin/ls")
        // This is the call the setup inspector makes on the main actor.
        XCTAssertEqual(lookup.path(of: "ls", allowSpawn: false), "/bin/ls")
        XCTAssertEqual(spawns.value, 1)
    }

    /// Installing the tool while the app is open has to be picked up by the
    /// next refresh, not only after a relaunch.
    func testRetriesAfterAFailedLookupExpires() {
        let spawns = LockedCounter()
        let lookup = LoginShellLookup(negativeCacheInterval: 0, shells: ["/bin/zsh"], spawn: { _, _, _ in
            spawns.increment()
            return spawns.value == 1 ? "" : self.markedOutput("/bin/ls")
        })

        XCTAssertNil(lookup.path(of: "ls", allowSpawn: true))
        XCTAssertEqual(lookup.path(of: "ls", allowSpawn: true), "/bin/ls")
    }

    func testDoesNotRetryWhileTheFailedLookupIsStillCached() {
        let spawns = LockedCounter()
        let lookup = LoginShellLookup(negativeCacheInterval: 600, shells: ["/bin/zsh"], spawn: { _, _, _ in
            spawns.increment()
            return ""
        })

        XCTAssertNil(lookup.path(of: "ls", allowSpawn: true))
        XCTAssertNil(lookup.path(of: "ls", allowSpawn: true))
        XCTAssertEqual(spawns.value, 1)
    }

    // MARK: - Real login shell

    /// Exercises the actual `Process` plumbing — flags, markers and timeout —
    /// against a tool that is guaranteed to exist.
    func testRealLoginShellResolvesAToolThatIsOnTheUserPath() throws {
        let output = try XCTUnwrap(
            LoginShellLookup.runCapturingOutput(
                executable: "/bin/zsh",
                arguments: [
                    "-l", "-i", "-c",
                    "printf '\(LoginShellLookup.marker):'; command -v 'ls'; printf ':\(LoginShellLookup.marker)'",
                ],
                timeout: 15
            )
        )

        XCTAssertEqual(LoginShellLookup.extractMarkedPath(from: output), "/bin/ls")
    }

    func testRunCapturingOutputReturnsNilForACommandThatCannotBeLaunched() {
        XCTAssertNil(
            LoginShellLookup.runCapturingOutput(
                executable: "/nonexistent/shell",
                arguments: ["-c", "true"],
                timeout: 1
            )
        )
    }

    /// A startup file that blocks must not hold a refresh cycle open.
    func testRunCapturingOutputGivesUpOnAShellThatNeverExits() {
        let started = Date()
        let output = LoginShellLookup.runCapturingOutput(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            timeout: 1
        )

        XCTAssertEqual(output, "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}

/// Test helpers: the spawn closure is `@Sendable`, so the counters it touches
/// have to be too.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
#endif
