// NotchPilot: a notch teleprompter that can screenshot your screen / take voice
// and ask an AI (OpenAI, Gemini, Claude, or any OpenAI-compatible API) about it.
// Kept out of its own screenshots. Not reliably hidden from screen sharing on macOS 15+ (no public API for that).
import AppKit
import AVFoundation
import PDFKit
import ScreenCaptureKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

let collapsed = NSSize(width: 220, height: 34)
let expanded = NSSize(width: 560, height: 280)

// MARK: - Providers

enum Provider: String, CaseIterable, Identifiable {
    case openai = "OpenAI"
    case anthropic = "Anthropic (Claude)"
    case gemini = "Google Gemini"
    case custom = "OpenAI-compatible (Groq, OpenRouter, Ollama…)"
    case claudeCode = "Claude subscription (via Claude Code)"
    var id: String { rawValue }

    var defaultModel: String {
        switch self {
        case .gemini: "gemini-3.8-flash"
        case .openai: "gpt-5.4-mini"
        case .anthropic, .claudeCode: "claude-sonnet-5-5"
        case .custom: ""
        }
    }

    var keyPage: URL? {
        switch self {
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .custom, .claudeCode: nil
        }
    }

    func request(key: String, model: String, baseURL: String, system: String, prompt: String, image: String?) -> URLRequest? {
        let dataURL = image.map { "data:image/jpeg;base64," + $0 }
        var url: URL?
        var headers = ["content-type": "application/json"]
        var body: [String: Any]
        switch self {
        case .openai: // Responses API: works with OpenAI's newest models
            url = URL(string: "https://api.openai.com/v1/responses")
            headers["Authorization"] = "Bearer " + key
            var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
            if let dataURL { content.append(["type": "input_image", "image_url": dataURL]) }
            body = ["model": model, "instructions": system, "input": [["role": "user", "content": content]]]
        case .custom: // Chat Completions: the format most other providers copy
            url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/chat/completions")
            if !key.isEmpty { headers["Authorization"] = "Bearer " + key } // local servers need no key
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            if let dataURL { content.append(["type": "image_url", "image_url": ["url": dataURL]]) }
            body = ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": content]]]
        case .gemini:
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
            headers["x-goog-api-key"] = key
            var parts: [[String: Any]] = [["text": prompt]]
            if let image { parts.append(["inline_data": ["mime_type": "image/jpeg", "data": image]]) }
            body = ["system_instruction": ["parts": [["text": system]]], "contents": [["role": "user", "parts": parts]]]
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/messages")
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2023-06-01"
            body = ["model": model, "max_tokens": 1024, "system": system, "messages": [["role": "user", "content": anthropicContent(prompt, image)]]]
        case .claudeCode: return nil // not HTTP; see ClaudeCode below
        }
        guard let url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }
}

func anthropicContent(_ prompt: String, _ image: String?) -> [[String: Any]] {
    var content: [[String: Any]] = []
    if let image { content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image]]) }
    content.append(["type": "text", "text": prompt])
    return content
}

/// Pulls the answer (or error message) out of any of the four response shapes.
func replyText(_ j: [String: Any]) -> String? {
    if let c = j["choices"] as? [[String: Any]] { // chat completions
        return (c.first?["message"] as? [String: Any])?["content"] as? String
    }
    if let o = j["output"] as? [[String: Any]] { // OpenAI responses
        return o.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.compactMap { $0["text"] as? String }.joined()
    }
    if let c = j["candidates"] as? [[String: Any]] { // Gemini
        return ((c.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
    }
    if let c = j["content"] as? [[String: Any]] { // Anthropic
        return c.compactMap { $0["text"] as? String }.joined()
    }
    return (j["error"] as? [String: Any])?["message"] as? String
}

func selfTest() {
    func parse(_ s: String) -> String? { replyText(try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]) }
    precondition(parse(#"{"choices":[{"message":{"content":"hi"}}]}"#) == "hi")
    precondition(parse(#"{"output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"hi"}]}]}"#) == "hi")
    precondition(parse(#"{"candidates":[{"content":{"parts":[{"text":"h"},{"text":"i"}]}}]}"#) == "hi")
    precondition(parse(#"{"content":[{"type":"text","text":"hi"}]}"#) == "hi")
    precondition(parse(#"{"error":{"message":"bad key"}}"#) == "bad key")
    let r = ClaudeCode.parse(#"{"type":"result","subtype":"success","result":"hi","session_id":"abc"}"#)
    precondition(r.session == "abc" && r.result == "hi")
    precondition(ClaudeCode.parse(#"{"type":"system","subtype":"init","session_id":"abc"}"#).result == nil)
    precondition(ClaudeCode.parse("not json").session == nil)
    precondition(ClaudeCode.parse(#"{"type":"result","subtype":"error_during_execution","is_error":true}"#).result?.contains("New chat") == true)
    for p in Provider.allCases where p != .claudeCode {
        precondition(p.request(key: "k", model: "m", baseURL: "https://x.ai/v1/", system: "s", prompt: "p", image: "AAAA")?.httpBody != nil)
    }
    print("self-test passed")
}

// MARK: - Claude Code bridge
// One long-lived `claude -p` process signed in with the user's subscription.
// Each question is written to its stdin, so only the first one pays startup time,
// and every question lands in the same conversation.

final class ClaudeCode {
    private var proc: Process?, stdin: FileHandle?, buffer = Data()
    private var pending: [(String) -> Void] = []
    private(set) var model = "", system = ""
    var isRunning: Bool { proc != nil }

    var sessionID: String? {
        get { UserDefaults.standard.string(forKey: "claudeSession") }
        set { UserDefaults.standard.set(newValue, forKey: "claudeSession") }
    }

    static let binary = findBinary() // looked up once per launch

    static func findBinary() -> String? {
        let home = NSHomeDirectory()
        let known = [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let c = known.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return c }
        // Apps don't get the Terminal PATH, so ask the user's shell where claude lives.
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v claude"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let path = text.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    func start(model: String, system: String) {
        stop()
        guard let bin = Self.binary else { return }
        // A resumed chat keeps the instructions it started with, so new context means a new chat.
        if UserDefaults.standard.string(forKey: "claudeSystem") != system {
            sessionID = nil
            UserDefaults.standard.set(system, forKey: "claudeSystem")
        }
        let p = Process(), inPipe = Pipe(), outPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--model", model, "--system-prompt", system,
                       "--tools", "", "--strict-mcp-config"] // chat only: no file/shell access, no MCP servers
            + (sessionID.map { ["--resume", $0] } ?? [])
        // A folder of its own, so no project's CLAUDE.md/hooks get loaded.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchPilot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        p.currentDirectoryURL = dir
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] dead in DispatchQueue.main.async { self?.died(dead) } }
        guard (try? p.run()) != nil else { return }
        proc = p; stdin = inPipe.fileHandleForWriting; self.model = model; self.system = system
    }

    func stop() {
        proc?.terminationHandler = nil
        proc?.terminate()
        proc = nil; stdin = nil; buffer = Data()
        flush("Stopped.")
    }

    func newChat() { stop(); sessionID = nil }

    func openInDesktop() {
        guard let id = sessionID, let bin = Self.binary else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--desktop", "--resume", id]
        try? p.run()
    }

    func ask(_ content: [[String: Any]], done: @escaping (String) -> Void) {
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: msg) else {
            done("Couldn't start Claude Code. Install it from code.claude.com, then run `claude` once in Terminal to sign in.")
            return
        }
        pending.append(done)
        do { try stdin.write(contentsOf: data + Data("\n".utf8)) } catch { died(proc) }
    }

    static func parse(_ line: String) -> (session: String?, result: String?) {
        guard let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return (nil, nil) }
        let session = j["session_id"] as? String
        guard j["type"] as? String == "result" else { return (session, nil) }
        if let text = j["result"] as? String, j["is_error"] as? Bool != true { return (session, text) }
        return (session, "Something went wrong with this chat. Start a new chat in Settings (⚙︎ › New chat).")
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 10) { // one JSON event per line
            let line = String(decoding: buffer[..<nl], as: UTF8.self)
            buffer.removeSubrange(...nl)
            let r = Self.parse(line)
            if let s = r.session { sessionID = s }
            if let result = r.result, !pending.isEmpty { pending.removeFirst()(result) }
        }
    }

    private func died(_ p: Process?) {
        guard p === proc else { return }
        proc = nil; stdin = nil
        flush("Something went wrong with this chat. Start a new chat in Settings (⚙︎ › New chat).")
    }

    private func flush(_ message: String) {
        let waiting = pending
        pending = []
        waiting.forEach { $0(message) }
    }
}

let claudeCode = ClaudeCode()

// MARK: - Keychain (API keys never go in plain-text prefs)

enum Keychain {
    static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "NotchPilot", kSecAttrAccount: account]
    }
    static func get(_ account: String) -> String {
        var q = query(account)
        q[kSecReturnData] = true
        var out: CFTypeRef?
        SecItemCopyMatching(q as CFDictionary, &out)
        return (out as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    static func set(_ account: String, _ value: String) {
        SecItemDelete(query(account) as CFDictionary)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        var q = query(account)
        q[kSecValueData] = Data(v.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Defaults and shared helpers

let defaultMasterPrompt = """
You are me in a live interview. The interviewer's question comes from my screen or my mic. Answer it out loud as me, \
using only my resume for facts.

How to answer:
Open with one sentence that answers the question directly or states my approach. No warm-up.
Then give 3 or 4 points, no more.
Use at most 2 experiences from my resume in the whole answer: the ones that fit the question best. Go deeper on those \
instead of listing more. Not every point needs an example; a point can just explain what I do and why.
When I do use an experience, name the company or project and use its real numbers.
Be concrete: say what I actually built, said, or decided, not general traits.
For "tell me about a time" questions, tell ONE story as situation, then action, then result, spending most of it on \
what I did and ending with a number.
Close with one sentence that sums up my answer.

Rules:
Never invent companies, projects, or numbers that aren't in my resume. If the question goes beyond it, explain how \
I'd approach it in a way that's consistent with my experience, without making up specifics.
Sound like a sharp, confident person talking: short sentences, no buzzwords.
Each point gets its own short paragraph. Aim for about 90 to 120 seconds out loud.
"""

func resumeText(from url: URL) -> String? {
    let txt = url.pathExtension.lowercased() == "pdf"
        ? PDFDocument(url: url)?.string
        : (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
    return txt.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
}

func pickResumeText() -> String? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf, .plainText, .rtf, UTType(filenameExtension: "docx")].compactMap { $0 }
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return resumeText(from: url)
}

func screenAccessGranted() async -> Bool {
    (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
}

func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

/// Screen Recording only takes effect after a restart, so offer one.
func relaunch() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
    try? p.run()
    NSApp.terminate(nil)
}

// MARK: - Settings window

struct SettingsView: View {
    @AppStorage("provider") var provider = Provider.openai
    @AppStorage("baseURL") var baseURL = "https://openrouter.ai/api/v1"
    @AppStorage("speed") var speed = 30.0
    @AppStorage("script") var script = ""
    @AppStorage("masterPrompt") var masterPrompt = defaultMasterPrompt
    @AppStorage("resume") var resume = ""
    @AppStorage("jobDescription") var jobDescription = ""
    @State var model = ""
    @State var key = ""

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $provider) {
                    ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Model", text: $model, prompt: Text(provider.defaultModel))
                if provider == .claudeCode {
                    LabeledContent("Chat") {
                        HStack {
                            Button("New chat") { claudeCode.newChat() }
                            Button("Open in Claude Desktop") { claudeCode.openInDesktop() }
                        }
                    }
                } else {
                    SecureField("API key", text: $key, prompt: Text("Paste key"))
                }
                if provider == .custom { TextField("Base URL", text: $baseURL) }
            } header: {
                Text("AI")
            } footer: {
                Group {
                    if provider == .claudeCode {
                        Text("Uses your Claude subscription. Install Claude Code from code.claude.com and run `claude` once in Terminal to sign in. Editing the master prompt or resume starts a fresh chat.")
                    } else if let page = provider.keyPage {
                        Link("Get a \(provider.rawValue) key ↗", destination: page)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Teleprompter") {
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $speed, in: 10...150).labelsHidden()
                        Text("\(Int(speed))").monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                    }
                }
                Editor(text: $script, placeholder: "Paste a script to read from the notch…", height: 100)
                HStack {
                    Spacer()
                    Button("Show in notch") { notchModel.show(script) }.disabled(script.isEmpty)
                }
            }

            Section {
                Editor(text: $masterPrompt, placeholder: "Tell the AI who it is and how to answer", height: 130)
                HStack {
                    Spacer()
                    Button("Reset to default") { masterPrompt = defaultMasterPrompt }.disabled(masterPrompt == defaultMasterPrompt)
                }
            } header: {
                Text("Master prompt")
            } footer: {
                Text("Sent with every question.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Editor(text: $resume, placeholder: "Paste your resume, or load a file…", height: 130)
                HStack {
                    Spacer()
                    Button("Load file…") { if let t = pickResumeText() { resume = t } }
                }
            } header: {
                Text("Resume")
            } footer: {
                Text(resume.isEmpty ? "Gives the AI context about you. PDF, Word, or text."
                                    : "\(wordCount(resume)) words loaded. Answers will draw on this.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Editor(text: $jobDescription, placeholder: "Paste the job posting you're interviewing for…", height: 130)
                HStack {
                    Button("Clear") { jobDescription = "" }.disabled(jobDescription.isEmpty)
                    Spacer()
                    Button("Load file…") { if let t = pickResumeText() { jobDescription = t } }
                }
            } header: {
                Text("Job description")
            } footer: {
                Text(jobDescription.isEmpty ? "Optional. Answers lean toward what this role asks for."
                                            : "\(wordCount(jobDescription)) words loaded. Answers will match this role.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Run setup again") { (NSApp.delegate as? Notch)?.showOnboarding() }
                Spacer()
                Button("Quit NotchPilot", role: .destructive) { NSApp.terminate(nil) }
            }
            .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
        .onAppear(perform: load)
        .onChange(of: provider) { load() }
        .onChange(of: model) { _, v in UserDefaults.standard.set(v, forKey: "model_" + provider.rawValue) }
        .onChange(of: key) { _, v in Keychain.set(provider.rawValue, v) }
    }

    func load() {
        model = UserDefaults.standard.string(forKey: "model_" + provider.rawValue) ?? ""
        key = Keychain.get(provider.rawValue)
    }

}

/// TextEditor with a placeholder, since SwiftUI's has none.
struct Editor: View {
    @Binding var text: String
    let placeholder: String
    let height: CGFloat
    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @AppStorage("provider") var provider = Provider.openai
    @AppStorage("resume") var resume = ""
    @State var step = 0
    @State var key = ""
    @State var screenOK = false
    let finish: () -> Void
    let pages = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: aiStep
                case 2: resumeStep
                default: permissionsStep
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 44)
            .padding(.top, 44)

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Capsule().fill(i == step ? Color.primary : Color.secondary.opacity(0.3))
                            .frame(width: i == step ? 16 : 6, height: 6)
                    }
                }
                Spacer()
                if step > 0 { Button("Back") { withAnimation(.easeInOut(duration: 0.25)) { step -= 1 } } }
                Button(nextTitle, action: next)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 560, height: 560)
        .onAppear { key = Keychain.get(provider.rawValue) }
        .onChange(of: provider) { key = Keychain.get(provider.rawValue) }
        .onChange(of: key) { _, v in Keychain.set(provider.rawValue, v) }
    }

    var canContinue: Bool {
        step != 1 || provider == .claudeCode || provider == .custom || !key.trimmingCharacters(in: .whitespaces).isEmpty
    }
    var nextTitle: String {
        step == pages - 1 ? "Start using NotchPilot" : (step == 2 && resume.isEmpty ? "Skip for now" : "Continue")
    }
    func next() {
        if step < pages - 1 { withAnimation(.easeInOut(duration: 0.25)) { step += 1 } } else { finish() }
    }

    func header(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 104, height: 104)
            Text("Welcome to NotchPilot").font(.largeTitle.weight(.semibold))
            Text("An AI copilot that lives in your Mac's notch. Hover the notch, tap the camera or mic, and read the answer like a teleprompter.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            HStack(spacing: 24) {
                feature("camera.viewfinder", "Reads the question on your screen")
                feature("mic.fill", "Hears it when you tap the mic")
                feature("eye.slash", "Kept out of its own screenshots")
            }
            .padding(.top, 12)
        }
    }

    func feature(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(height: 28)
            Text(label).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(width: 120)
    }

    var aiStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Connect an AI", "Questions and screenshots go straight from your Mac to the provider you pick. Your key is stored in your Mac's Keychain.")
            Picker("Provider", selection: $provider) {
                ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
            }
            switch provider {
            case .claudeCode:
                Text("Uses your Claude subscription through Claude Code. Install it from code.claude.com, then run `claude` once in Terminal to sign in.")
                    .font(.callout).foregroundStyle(.secondary)
            case .custom:
                Text("You'll set the server address and model in Settings after setup.")
                    .font(.callout).foregroundStyle(.secondary)
            default:
                SecureField("Paste your \(provider.rawValue) API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                if let page = provider.keyPage { Link("Get a key ↗", destination: page).font(.callout) }
            }
        }
    }

    var resumeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Add your resume", "Answers pull real experiences and numbers from it. You can change it anytime in Settings.")
            Button { if let t = pickResumeText() { resume = t } } label: {
                VStack(spacing: 8) {
                    Image(systemName: resume.isEmpty ? "doc.badge.plus" : "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(resume.isEmpty ? Color.secondary : Color.green)
                    Text(resume.isEmpty ? "Choose or drop your resume" : "\(wordCount(resume)) words loaded").font(.headline)
                    Text(resume.isEmpty ? "PDF, Word, or text file" : "Choose a different file").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(.tertiary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dropDestination(for: URL.self) { urls, _ in
                guard let t = urls.first.flatMap(resumeText(from:)) else { return false }
                resume = t
                return true
            }
        }
    }

    var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Allow access", "NotchPilot only looks at your screen or listens when you tap the camera or mic.")
            TimelineView(.periodic(from: .now, by: 1)) { _ in // re-check while you flip switches in System Settings
                VStack(spacing: 10) {
                    PermissionRow(symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                                  detail: "To read the question on your screen",
                                  granted: screenOK || CGPreflightScreenCaptureAccess()) {
                        Task {
                            screenOK = await screenAccessGranted() // asks macOS directly; shows its prompt the first time
                            if !screenOK {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }
                        }
                    }
                    PermissionRow(symbol: "mic.fill", title: "Microphone and Speech Recognition",
                                  detail: "To hear the question when you tap the mic",
                                  granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                                      && SFSpeechRecognizer.authorizationStatus() == .authorized) {
                        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied || SFSpeechRecognizer.authorizationStatus() == .denied {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        } else {
                            SFSpeechRecognizer.requestAuthorization { _ in AVCaptureDevice.requestAccess(for: .audio) { _ in } }
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "video.fill").font(.title3).foregroundStyle(.tint).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Using Zoom?").font(.headline)
                    Text("Zoom › Settings › Share Screen › Advanced › Screen capture mode: choose \"Advanced capture with window filtering\" so Zoom skips NotchPilot. Meet, Teams, and QuickTime need nothing.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.6)))
            HStack {
                Text("Just turned on Screen Recording? macOS applies it after NotchPilot reopens.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reopen NotchPilot") {
                    UserDefaults.standard.set(true, forKey: "onboarded")
                    relaunch()
                }
                .controlSize(.small)
            }
        }
    }
}

struct PermissionRow: View {
    let symbol: String, title: String, detail: String
    let granted: Bool
    let allow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else {
                Button("Allow", action: allow)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.6)))
    }
}

// MARK: - Notch UI

final class NotchModel: ObservableObject {
    @Published var isOpen = false
    @Published var text = ""
    @Published var status = ""
    @Published var recording = false
    @Published var thinking = false
    @Published var scrolling = false
    @Published var typing = false
    @Published var draft = ""
    @Published var attachScreen = false
    var notchWidth: CGFloat = 200, notchHeight: CGFloat = 32
    var openSize: CGSize { CGSize(width: max(420, notchWidth + 240), height: notchHeight + 236) } // narrow enough to leave your menus visible
    let shoulder: CGFloat = 8 // the little outward curve where the panel meets the top of the screen

    func show(_ s: String) {
        text = s
        scroller.offset = 0
        status = ""
    }
}

let notchModel = NotchModel()

/// Kept apart from NotchModel: it changes 60 times a second, and only the text should redraw that often.
final class ScrollState: ObservableObject {
    @Published var offset: CGFloat = 0
    var contentHeight: CGFloat = 0, viewportHeight: CGFloat = 0 // measured by the view
    var end: CGFloat { max(0, contentHeight - viewportHeight) }
}

let scroller = ScrollState()

/// A notch outline: square to the top of the screen, with small outward "shoulders" at the top corners
/// (like the real notch) and rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let t = shoulder, b = min(bottomRadius, (r.width - 2 * t) / 2, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var m: NotchModel
    let app: Notch

    var body: some View {
        // The window never resizes; only this black shape grows out of the notch,
        // and the content inside keeps its full size so text never re-wraps mid-animation.
        content
            .frame(width: m.openSize.width, height: m.openSize.height)
            .opacity(m.isOpen ? 1 : 0)
            .frame(width: m.isOpen ? m.openSize.width : m.notchWidth + 2 * m.shoulder,
                   height: m.isOpen ? m.openSize.height : m.notchHeight, alignment: .top)
            .background(.black)
            .clipShape(NotchShape(bottomRadius: m.isOpen ? 22 : 10, shoulder: m.shoulder))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea() // otherwise SwiftUI pushes everything down below the notch
            .environment(\.colorScheme, .dark)
    }

    var content: some View {
        VStack(spacing: 0) {
            // The strip beside the physical notch. Clicking it (or the notch itself) opens the text box.
            Color.clear
                .frame(height: m.notchHeight)
                .contentShape(Rectangle())
                .onTapGesture { app.startTyping() }
                .help("Click to type a question")

            HStack(spacing: 2) {
                IconButton(symbol: "camera.viewfinder", help: "Screenshot → ask AI") { app.shot() }
                IconButton(symbol: m.recording ? "stop.fill" : "mic.fill", tint: m.recording ? .red : .white,
                           help: m.recording ? "Stop and send" : "Record voice → ask AI") { app.mic() }
                IconButton(symbol: "keyboard", help: "Type a question") { app.startTyping() }
                Spacer()
                IconButton(symbol: m.scrolling ? "pause.fill" : "play.fill", help: "Play / pause scrolling") { app.play() }
                IconButton(symbol: "gearshape.fill", help: "Settings") { app.openSettings() }
                IconButton(symbol: "xmark", help: "Quit NotchPilot") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 12 + m.shoulder)
            .frame(height: 30)

            Teleprompter(m: m, s: scroller)
                .padding(.horizontal, 20 + m.shoulder)

            if m.typing {
                AskField(m: m) { app.sendTyped() }
                    .padding(.horizontal, 12 + m.shoulder)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 6) {
                if m.recording {
                    Image(systemName: "waveform").foregroundStyle(.red).symbolEffect(.variableColor.iterative)
                } else if m.thinking {
                    Image(systemName: "sparkle").symbolEffect(.pulse)
                }
                Text(m.status).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .frame(height: 24)
            .opacity(m.status.isEmpty && !m.recording && !m.thinking ? 0 : 1)
        }
    }
}

/// The text box that opens when you click the notch.
struct AskField: View {
    @ObservedObject var m: NotchModel
    let send: () -> Void
    @FocusState var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { m.attachScreen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: m.attachScreen ? "macwindow" : "plus")
                        .font(.system(size: 11, weight: .bold))
                    if m.attachScreen {
                        Text("Screen").font(.system(size: 12, weight: .semibold, design: .rounded))
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).opacity(0.6)
                    }
                }
                .foregroundStyle(m.attachScreen ? Color.black : Color.white.opacity(0.85))
                .padding(.horizontal, m.attachScreen ? 9 : 0)
                .frame(minWidth: 24, minHeight: 24)
                .background(Capsule().fill(m.attachScreen ? Color.white : Color.white.opacity(0.12)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(m.attachScreen ? "Screenshot will be sent with your question. Click to remove." : "Attach a screenshot")

            TextField(m.attachScreen ? "Ask about your screen…" : "Ask anything…", text: $m.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit(send)
                .onExitCommand { withAnimation(.easeOut(duration: 0.15)) { m.typing = false } }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(m.draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.white.opacity(0.25) : Color.white)
            }
            .buttonStyle(.plain)
            .help("Send (Return)")
        }
        .padding(.leading, 6).padding(.trailing, 6).padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .onAppear { focused = true }
    }
}

struct Teleprompter: View {
    @ObservedObject var m: NotchModel
    @ObservedObject var s: ScrollState

    var body: some View {
        GeometryReader { box in
            Text(m.text)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .frame(width: box.size.width)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 18)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { s.contentHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in s.contentHeight = h }
                })
                .offset(y: -s.offset)
                .allowsHitTesting(false) // scrolled text slides up under the buttons; it must not eat their clicks
                .onAppear { s.viewportHeight = box.size.height }
                .onChange(of: box.size.height) { _, h in s.viewportHeight = h }
        }
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                     .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom)) // soft fade top and bottom, like a real prompter
    }
}

struct IconButton: View {
    let symbol: String
    var tint: Color = .white
    let help: String
    let action: () -> Void
    @State var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint.opacity(hover ? 1 : 0.7))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 24)
                .background(Capsule().fill(.white.opacity(hover ? 0.14 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

// MARK: - Notch panel

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // macOS normally shoves windows below the menu bar; we need to sit on top of the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class NotchHost: NSHostingView<NotchView> {
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true } // buttons work without activating the app
}

final class Notch: NSObject, NSApplicationDelegate {
    let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let m = notchModel
    var settingsWindow: NSWindow?
    var timer: Timer?
    let engine = AVAudioEngine()
    var request: SFSpeechAudioBufferRecognitionRequest?, task: SFSpeechRecognitionTask?
    var transcript = ""
    var mouseTimer: Timer?, wasInside = false, leftAt: Date?
    var pendingStart: DispatchWorkItem?
    var onboardingWindow: NSWindow?
    var busy: Bool { m.thinking || m.recording || m.scrolling || m.typing } // stay open while these run

    static var screen: NSScreen { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main! } // prefer the notched display

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: ["speed": 30.0])
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Marks the window private: Meet, Teams, QuickTime and Zoom's "window filtering" mode skip it (same flag as
        // Electron's setContentProtection). Best effort: macOS 15.4+ can let some capture tools see it anyway.
        panel.sharingType = .none
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        // Never set isFloatingPanel: it silently resets this to the floating level, under the menu bar.
        panel.level = .screenSaver // above the menu bar, so the panel grows out of the notch

        let host = NotchHost(rootView: NotchView(m: m, app: self))
        host.sizingOptions = []    // SwiftUI was resizing the window, and macOS keeps the bottom edge, so the top slid off the notch
        host.safeAreaRegions = []  // and don't push content below the notch either
        panel.contentView = host
        placePanel()
        panel.ignoresMouseEvents = true // collapsed: clicks pass through to the menu bar
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [self] _ in placePanel() }

        // Hover by polling the cursor: steadier than tracking areas, which misfire while things animate.
        let t = Timer(timeInterval: 1 / 30, repeats: true) { [self] _ in trackMouse() }
        RunLoop.main.add(t, forMode: .common)
        mouseTimer = t

        // Scroll the answer yourself; doing so pauses the auto-scroll.
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] e in
            guard m.isOpen else { return e }
            setScrolling(false)
            scroller.offset = min(scroller.end, max(0, scroller.offset - e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 12)))
            return nil
        }

        if currentProvider == .claudeCode { claudeCode.start(model: currentModel, system: systemPrompt) } // warm up now
        if !UserDefaults.standard.bool(forKey: "onboarded") { showOnboarding() }
        let script = UserDefaults.standard.string(forKey: "script") ?? ""
        m.show(script.isEmpty ? "Tap the camera or mic to ask AI about your screen. Set it up in Settings." : script)
        panel.orderFrontRegardless()
        placePanel()
    }

    /// Pins the panel's top edge to the top of the notched screen and sizes the collapsed bar to the notch.
    func placePanel() {
        let s = Self.screen
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            m.notchHeight = s.safeAreaInsets.top
            m.notchWidth = s.frame.width - l.width - r.width
        }
        let size = m.openSize
        panel.setFrame(NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    func trackMouse() {
        let s = Self.screen, p = NSEvent.mouseLocation
        let notch = NSRect(x: s.frame.midX - m.notchWidth / 2, y: s.frame.maxY - m.notchHeight,
                           width: m.notchWidth, height: m.notchHeight)
        let inside = (m.isOpen ? panel.frame : notch).insetBy(dx: -4, dy: -4).contains(p)
        if inside {
            leftAt = nil
            if !m.isOpen { setOpen(true) }
        } else if wasInside {
            leftAt = Date() // just left; close after a short grace period
        }
        // Only close on leaving, so an answer that arrived while you were elsewhere stays up until you hover again.
        if let t = leftAt, Date().timeIntervalSince(t) > 0.25 {
            leftAt = nil
            if !busy { setOpen(false) }
        }
        wasInside = inside
    }

    func setOpen(_ open: Bool) {
        guard open != m.isOpen else { return }
        panel.ignoresMouseEvents = !open
        withAnimation(open ? .spring(response: 0.4, dampingFraction: 0.78) : .spring(response: 0.3, dampingFraction: 1)) {
            m.isOpen = open
        }
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView { [self] in finishOnboarding() }))
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.sharingType = .none // best effort: older capture APIs skip it; macOS 15+ screen shares may not
            w.isReleasedWhenClosed = false
            w.center()
            onboardingWindow = w
        }
        present(onboardingWindow!)
    }

    /// The app normally has no Dock icon, and macOS won't reliably bring such an app's windows forward
    /// or give them the keyboard. So while setup or settings is open, act like a regular app.
    func present(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Dead center of the screen you're on (AppKit's center() sits in the upper third).
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let v = screen.visibleFrame, size = w.frame.size
            w.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2))
        }
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [self] _ in
            DispatchQueue.main.async { [self] in
                let open = [onboardingWindow, settingsWindow].contains { $0?.isVisible == true }
                if !open { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        onboardingWindow?.close()
        onboardingWindow = nil
        m.show("You're set. When a question comes up, tap the camera to read it off your screen, or the mic to hear it.")
        setOpen(true) // show where it lives; it tucks away once you hover and move off
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "NotchPilot"
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.sharingType = .none // best effort: older capture APIs skip it; macOS 15+ screen shares may not
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        present(settingsWindow!)
    }

    // MARK: teleprompter auto-scroll
    func play() { setScrolling(!m.scrolling) }

    func setScrolling(_ on: Bool) {
        pendingStart?.cancel(); pendingStart = nil // your tap wins over a scheduled auto-start
        timer?.invalidate(); timer = nil
        m.scrolling = on
        guard on else { return }
        if scroller.offset >= scroller.end { scroller.offset = 0 } // at the end: play from the top
        let t = Timer(timeInterval: 1 / 60, repeats: true) { [self] _ in
            guard scroller.offset < scroller.end else { setScrolling(false); return }
            scroller.offset = min(scroller.end, scroller.offset + UserDefaults.standard.double(forKey: "speed") / 60) // points/sec → per tick
        }
        RunLoop.main.add(t, forMode: .common) // keep rolling while menus/drags are active
        timer = t
    }

    // MARK: typing
    func startTyping() {
        setScrolling(false)
        panel.makeKey() // a non-activating panel can take the keyboard without pulling you out of your app
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { m.typing = true }
    }

    func sendTyped() {
        let q = m.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let withScreen = m.attachScreen
        m.draft = ""
        m.attachScreen = false
        withAnimation(.easeOut(duration: 0.15)) { m.typing = false }
        guard withScreen else { ask(q, image: nil); return }
        screenshot { [self] image in
            guard let image else { return } // you asked for the screen; don't silently send without it
            ask("My screen is attached. " + q, image: image)
        }
    }

    // MARK: screenshot
    /// ScreenCaptureKit checks permission live (the old CGPreflight check stayed "no" until a relaunch,
    /// and isn't reliable on newer macOS), and it can leave our own windows out of the shot.
    func screenshot(_ done: @escaping (String?) -> Void) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
                else { throw CocoaError(.featureUnsupported) }
                let me = ProcessInfo.processInfo.processIdentifier
                let filter = SCContentFilter(display: display,
                                             excludingWindows: content.windows.filter { $0.owningApplication?.processID == me })
                let cfg = SCStreamConfiguration()
                cfg.width = 1600 // readable text, and under every provider's image size limit
                cfg.height = Int(1600 * CGFloat(display.height) / CGFloat(display.width))
                cfg.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
                DispatchQueue.main.async { done(jpeg?.base64EncodedString()) }
            } catch {
                DispatchQueue.main.async { [self] in
                    m.show("NotchPilot can't see your screen yet.\n\nIn System Settings › Privacy & Security › Screen & System Audio Recording, turn NotchPilot on. If it's already on, select it, click the minus button to remove it, add it again with plus, then reopen NotchPilot.")
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    done(nil)
                }
            }
        }
    }

    func shot() {
        screenshot { [self] image in
            guard let image else { return }
            ask("Here's my screen right now. Answer the question or prompt on it for me.", image: image)
        }
    }

    // MARK: voice
    func mic() {
        if task != nil { stopMic(); return }
        SFSpeechRecognizer.requestAuthorization { st in
            AVCaptureDevice.requestAccess(for: .audio) { micOK in
                DispatchQueue.main.async {
                    guard st == .authorized, micOK else {
                        self.m.status = "Allow Microphone and Speech Recognition in System Settings › Privacy"
                        return
                    }
                    self.startMic()
                }
            }
        }
    }

    func startMic() {
        guard let rec = SFSpeechRecognizer(), rec.isAvailable else { m.status = "Speech recognition unavailable"; return }
        setScrolling(false)
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in r.append(buf) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            m.status = "Mic error: \(error.localizedDescription)"
            return
        }
        transcript = ""; request = r
        task = rec.recognitionTask(with: r) { res, _ in
            guard let res else { return }
            DispatchQueue.main.async {
                guard self.task != nil else { return }
                self.transcript = res.bestTranscription.formattedString
                self.m.show(self.transcript)
                self.m.status = "Listening — tap stop to send"
            }
        }
        m.recording = true
        m.show("")
        m.status = "Listening — tap stop to send"
    }

    func stopMic() {
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        task = nil; request = nil
        m.recording = false
        guard !transcript.isEmpty else { m.status = "Didn't catch that"; return }
        let said = transcript
        screenshot { [self] image in
            ask("Here's what was just said (transcribed from my mic): \"\(said)\"\nAnswer it for me. My screen is attached for context.",
                image: image)
        }
    }

    // MARK: AI request
    var currentProvider: Provider { Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .openai }
    var currentModel: String {
        let saved = UserDefaults.standard.string(forKey: "model_" + currentProvider.rawValue) ?? ""
        return saved.isEmpty ? currentProvider.defaultModel : saved
    }
    var systemPrompt: String {
        let d = UserDefaults.standard
        var system = """
        Your reply appears in a small teleprompter at the top of the user's screen, and they will read it out loud. \
        Write in first person as the user, in natural spoken sentences. Plain text only: no markdown, bullets, or \
        headings; give each point its own short paragraph. If a screenshot is attached, find the question or \
        prompt on it and answer that.
        """
        let mp = d.string(forKey: "masterPrompt") ?? defaultMasterPrompt
        if !mp.isEmpty { system += "\n\n" + mp }
        if let r = d.string(forKey: "resume"), !r.isEmpty { system += "\n\nResume:\n<resume>\n" + r + "\n</resume>" }
        if let j = d.string(forKey: "jobDescription"), !j.isEmpty {
            system += "\n\nThe job I'm interviewing for:\n<job>\n" + j + "\n</job>\n"
                + "Pick the experiences that best match what this role asks for, and use its language where it fits naturally."
        }
        return system
    }

    func ask(_ prompt: String, image: String?) {
        let p = currentProvider, model = currentModel
        setScrolling(false)
        if p == .claudeCode {
            let sys = systemPrompt
            if !claudeCode.isRunning || claudeCode.model != model || claudeCode.system != sys { claudeCode.start(model: model, system: sys) }
            beginThinking(image)
            claudeCode.ask(anthropicContent(prompt, image)) { self.finish($0) }
            return
        }
        let key = Keychain.get(p.rawValue)
        guard !key.isEmpty || p == .custom else {
            m.show("Add your \(p.rawValue) API key in Settings.")
            openSettings()
            return
        }
        guard let req = p.request(key: key, model: model, baseURL: UserDefaults.standard.string(forKey: "baseURL") ?? "https://openrouter.ai/api/v1",
                                  system: systemPrompt, prompt: prompt, image: image) else {
            m.show("Invalid model name or base URL. Check Settings.")
            return
        }
        beginThinking(image)
        URLSession.shared.dataTask(with: req) { data, _, err in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let reply = json.flatMap(replyText) ?? err?.localizedDescription ?? "No response"
            DispatchQueue.main.async { self.finish(reply) }
        }.resume()
    }

    func beginThinking(_ image: String?) {
        m.thinking = true
        m.status = image == nil ? "Thinking — screenshot failed, allow Screen Recording" : "Thinking"
    }

    func finish(_ reply: String) {
        m.thinking = false
        m.show(reply.isEmpty ? "Empty response" : reply)
        let start = DispatchWorkItem { [self] in setScrolling(true) }
        pendingStart = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: start) // a beat to read the first line
    }
}

if CommandLine.arguments.contains("--selftest") { selfTest(); exit(0) }
signal(SIGPIPE, SIG_IGN) // a dead Claude Code process must not crash us
let app = NSApplication.shared

// Without an Edit menu, ⌘V/⌘C/⌘A do nothing in text fields, so you couldn't paste your key or resume.
let mainMenu = NSMenu()
let appItem = NSMenuItem(), editItem = NSMenuItem()
mainMenu.addItem(appItem); mainMenu.addItem(editItem)
appItem.submenu = NSMenu()
appItem.submenu!.addItem(withTitle: "Quit NotchPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
edit.addItem(.separator())
edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = edit
app.mainMenu = mainMenu
let delegate = Notch()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon
app.run()
