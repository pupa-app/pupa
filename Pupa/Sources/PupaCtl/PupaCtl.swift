import Foundation
import AGUIKit
import PupaScripting
import PupaApp
import PupaHarness

/// Drive Pupa from a shell: send chat turns through the real app graph and
/// print what they did. No window, no simulator, no Xcode.
///
///     pupactl chat "add a Books tracker"      # live backend on :8004
///     pupactl repl                            # keep talking
///     pupactl replay script.jsonl --send "…"  # deterministic, no network
///     pupactl record out.jsonl --send "…"     # tee a real turn into a fixture
///     pupactl dump                            # state between turns
///
/// State lives under `--root` and persists across invocations, so consecutive
/// calls continue the same conversation. `--new-session` starts over.
@main
enum PupaCtl {

    static let usage = """
    pupactl — drive Pupa headlessly

      chat "<prompt>"        send one turn, print the report
      repl                   interactive multi-turn session
      replay <script.jsonl>  serve a canned backend; needs --send
      record <out.jsonl>     tee a live turn into a replayable script
      dump                   print current state, run nothing
      pair <CODE>            redeem a pairing code, print the device token

    Options
      --root DIR       storage root (default ~/.pupa-ctl); persists between runs
      --backend URL    AG-UI endpoint (default http://localhost:8004/)
      --harness ID     backend agent harness, e.g. claude_code (or
                       PUPA_CTL_HARNESS); omit for the backend's default
      --send "<text>"  prompt for replay / record
      --token TOKEN    paired-device token (or PUPA_CTL_TOKEN); live backends
                       answer 401 without one. Never written to the Keychain.
      --type KIND      MyApp type to seed on a fresh root (default tracker)
      --new-session    wipe the root first
      --json           machine-readable report
      --no-wire        omit the per-round wire summary
      --quiet          suppress AGUIKit stream logs

    In the repl: :dump  :canvas  :wire  :new  :quit
    """

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, !command.hasPrefix("-") else { return print(usage) }
        args.removeFirst()

        let options = Options(args)
        if options.quiet { setenv("AGUIKIT_LOG", "0", 1) }

        switch command {
        case "chat":    await chat(options)
        case "repl":    await repl(options)
        case "replay":  await replay(options)
        case "record":  await record(options)
        case "dump":    await dump(options)
        case "pair":    await pair(options)
        case "help", "-h", "--help": print(usage)
        default:
            FileHandle.standardError.write(Data("unknown command '\(command)'\n\n".utf8))
            print(usage)
            exit(2)
        }
    }

    // MARK: Commands

    private static func chat(_ options: Options) async {
        guard let prompt = options.positional.first ?? options.send else {
            return fail("chat needs a prompt")
        }
        let scenario = await makeScenario(options, urlSession: liveSession(options))
        await scenario.hydrate()
        await run(prompt, in: scenario, options: options)
    }

    private static func repl(_ options: Options) async {
        let scenario = await makeScenario(options, urlSession: liveSession(options))
        await scenario.hydrate()
        print("root \(options.root.path)  backend \(options.backend)")
        print("prompts run a turn; :dump :canvas :wire :new :quit")
        while true {
            print("> ", terminator: "")
            guard let line = readLine(strippingNewline: true) else { return }
            let input = line.trimmingCharacters(in: .whitespaces)
            switch input {
            case "": continue
            case ":quit", ":q": return
            case ":dump": await MainActor.run { print(scenario.report().text()) }
            case ":canvas": await MainActor.run { print(scenario.report().text(includeWire: false)) }
            case ":wire": await MainActor.run { printWire(scenario) }
            case ":new": await MainActor.run { scenario.coordinator.discardSession(for: scenario.scope) }
            default: await run(input, in: scenario, options: options)
            }
        }
    }

    private static func replay(_ options: Options) async {
        guard let path = options.positional.first else { return fail("replay needs a script path") }
        guard let prompt = options.send else { return fail("replay needs --send \"<prompt>\"") }
        do {
            ScriptedTransport.reset()
            ScriptedTransport.script = try Script.load(URL(fileURLWithPath: path))
        } catch {
            return fail("could not read script: \(error)")
        }
        let scenario = await makeScenario(options, urlSession: ScriptedTransport.session())
        await scenario.hydrate()
        await run(prompt, in: scenario, options: options)
    }

    private static func record(_ options: Options) async {
        guard let path = options.positional.first else { return fail("record needs an output path") }
        guard let prompt = options.send else { return fail("record needs --send \"<prompt>\"") }
        RecordingTransport.reset()
        let scenario = await makeScenario(options, urlSession: RecordingTransport.session())
        await scenario.hydrate()
        await run(prompt, in: scenario, options: options)
        do {
            let script = Script(rounds: RecordingTransport.rounds)
            try script.jsonl().write(toFile: path, atomically: true, encoding: .utf8)
            print("\nrecorded \(script.rounds.count) round(s) → \(path)")
        } catch {
            fail("could not write script: \(error)")
        }
    }

    private static func dump(_ options: Options) async {
        let scenario = await makeScenario(options, urlSession: liveSession(options))
        await scenario.hydrate()
        await MainActor.run { print(scenario.report().text(includeWire: !options.noWire)) }
    }

    /// Redeem a one-time pairing code for a device token.
    ///
    /// Live backends answer 401 without one. Mint the code on the backend with
    /// `make pair`, redeem it here, then pass the token via `--token` or
    /// `PUPA_CTL_TOKEN` — it is printed, never stored, so it can't disturb the
    /// real app's pairing.
    private static func pair(_ options: Options) async {
        guard let code = options.positional.first else { return fail("pair needs a code") }
        let client = BackendPairingClient(
            backendURL: options.backend, session: liveSession(options))
        do {
            let result = try await client.pair(code: code, label: "pupactl")
            print("paired \(result.label)  device \(result.deviceID)")
            print("scopes: \(result.scopes.joined(separator: ", "))")
            print("\nexport PUPA_CTL_TOKEN=\(result.token)")
        } catch {
            fail("pairing failed: \(error)")
        }
    }

    // MARK: Plumbing

    @MainActor
    private static func makeScenario(_ options: Options, urlSession: URLSession) -> Scenario {
        Scenario(
            root: options.root,
            backend: options.backend,
            urlSession: urlSession,
            typeId: options.typeId,
            reset: options.newSession,
            token: options.token,
            harnessID: options.harness)
    }

    /// A plain session for a live backend. Cert pinning is a settings concern
    /// the harness deliberately doesn't inherit — point it at a real URL.
    private static func liveSession(_ options: Options) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = options.timeout
        cfg.timeoutIntervalForResource = options.timeout
        return URLSession(configuration: cfg)
    }

    private static func run(_ prompt: String, in scenario: Scenario, options: Options) async {
        let settled = await scenario.send(prompt, timeout: options.timeout)
        await MainActor.run {
            let report = scenario.report()
            if options.json {
                print((try? report.json()) ?? "{}")
            } else {
                print(report.text(includeWire: !options.noWire))
            }
            if !settled {
                FileHandle.standardError.write(
                    Data("\nturn did not settle within \(Int(options.timeout))s\n".utf8))
            }
        }
    }

    @MainActor
    private static func printWire(_ scenario: Scenario) {
        for (n, body) in scenario.report().wire.enumerated() {
            print("── round \(n + 1) ──")
            print(String(decoding: body, as: UTF8.self))
        }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(2)
    }

    // MARK: Options

    struct Options {
        var positional: [String] = []
        var root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pupa-ctl", isDirectory: true)
        var backend = URL(string: "http://localhost:8004/")!
        var send: String?
        var harness = ProcessInfo.processInfo.environment["PUPA_CTL_HARNESS"]
        var token = ProcessInfo.processInfo.environment["PUPA_CTL_TOKEN"]
        var typeId = MyAppType.tracker.id
        var newSession = false
        var json = false
        var noWire = false
        var quiet = false
        var timeout: TimeInterval = 180

        init(_ args: [String]) {
            var rest = args[...]
            while let arg = rest.first {
                rest = rest.dropFirst()
                func value() -> String? {
                    guard let next = rest.first, !next.hasPrefix("--") else { return nil }
                    rest = rest.dropFirst()
                    return next
                }
                switch arg {
                case "--root": if let v = value() { root = URL(fileURLWithPath: v) }
                case "--backend": if let v = value(), let url = URL(string: v) { backend = url }
                case "--harness": harness = value()
                case "--send": send = value()
                case "--token": token = value()
                case "--type": if let v = value() { typeId = v }
                case "--timeout": if let v = value(), let n = TimeInterval(v) { timeout = n }
                case "--new-session": newSession = true
                // Accepted and ignored: continuing is the default, but saying so
                // at the call site is worth the two words.
                case "--continue": break
                case "--json": json = true
                case "--no-wire": noWire = true
                case "--quiet": quiet = true
                default: if !arg.hasPrefix("--") { positional.append(arg) }
                }
            }
        }
    }
}
