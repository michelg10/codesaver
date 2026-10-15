//
//  CodeSetupViews.swift
//  CodeSaver
//
//  The host window's code rows, moved out of ContentView: the GitHub setup
//  step (two ways in — a username for public repos, or a token for private
//  ones), the Auto-refresh step with its power rule, and the status block
//  under YOUR CODE — what's on disk, a run in progress in either process, and
//  last run's problems in plain words with the one button that fixes each.
//  Same vocabulary as the rest of the window: SF Mono, ✽ glowing for the
//  step to do next, ✻ for done, · for later.
//

import SwiftUI

fileprivate enum StepState { case done, current, pending }

fileprivate func stepState(done: Bool, current: Bool) -> StepState {
    done ? .done : (current ? .current : .pending)
}

fileprivate struct StepGlyph: View {
    let state: StepState

    var body: some View {
        switch state {
        case .done:
            Text("✻").font(Theme.mono(13)).foregroundStyle(Theme.slate)
        case .current:
            Text("✽").font(Theme.mono(13)).foregroundStyle(Theme.violetHot)
                .shadow(color: Theme.violet.opacity(0.9), radius: 5)
        case .pending:
            Text("·").font(Theme.mono(13)).foregroundStyle(Theme.dim)
        }
    }
}

fileprivate struct StepTitle: View {
    let text: String
    let state: StepState

    var body: some View {
        Text(text)
            .font(Theme.mono(13))
            .foregroundStyle(state == .pending ? Theme.dim : Theme.ink)
    }
}

fileprivate struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.mono(10))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }
}

fileprivate struct AlertLine: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.alert)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - GitHub

struct GitHubStep: View {
    @ObservedObject var refresh: RefreshManager
    let isCurrent: Bool

    private enum Path: Hashable { case publicRepos, privateRepos }

    @State private var path = Path.publicRepos
    @State private var username = ""
    @State private var token = ""
    @State private var showPicker = false
    @State private var showConnect = false
    @State private var confirmDisconnect = false

    private var state: StepState { stepState(done: refresh.hasSource, current: isCurrent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StepGlyph(state: state)
                StepTitle(text: "GitHub", state: state)
                Spacer()
                status
            }
            Group {
                if refresh.githubConnected {
                    if refresh.replacingToken && !refresh.publicOnly {
                        tokenEntry
                    }
                } else if refresh.folders.isEmpty || showConnect {
                    connectRows
                } else {
                    Button("connect GitHub too…") { showConnect = true }
                        .buttonStyle(.link)
                        .font(Theme.mono(11))
                }
                if let error = refresh.connectError {
                    AlertLine(error)
                }
                if !refresh.githubConnected && refresh.folders.isEmpty {
                    Button("or skip GitHub and add folders from this Mac…") {
                        refresh.chooseFolders { added in if added { refresh.refreshNow(afterCurrent: true) } }
                    }
                    .buttonStyle(.link)
                    .font(Theme.mono(11))
                }
                pickerLink
            }
            .padding(.leading, 24)
        }
        .sheet(isPresented: $showPicker) {
            CodePicker(refresh: refresh) { changed in refresh.pickerClosed(changed: changed) }
        }
        .onChange(of: path) { refresh.connectError = nil }
        // A token is a chore to make again; a public username isn't.
        .confirmationDialog("Disconnect GitHub?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Forget the token", role: .destructive) { refresh.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("CodeSaver deletes the token from your keychain and stops fetching. What's already downloaded stays until you delete it.")
        }
    }

    @ViewBuilder
    private var status: some View {
        if refresh.connecting {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
                Text("checking with GitHub…").font(Theme.mono(11)).foregroundStyle(Theme.slate)
            }
        } else if refresh.githubConnected {
            HStack(spacing: 8) {
                Text(connectedLabel).font(Theme.mono(11)).foregroundStyle(Theme.slate)
                Button("disconnect") {
                    if refresh.publicOnly { refresh.disconnect() } else { confirmDisconnect = true }
                }
                    .buttonStyle(.link)
                    .font(Theme.mono(11))
                    .help(refresh.publicOnly
                          ? "stop fetching this account's repos — what's downloaded stays until you delete it"
                          : "forget the token — what's downloaded stays until you delete it")
            }
        } else if !refresh.folders.isEmpty {
            Text("folders only").font(Theme.mono(11)).foregroundStyle(Theme.slate)
        }
    }

    private var connectedLabel: String {
        let name = refresh.accountName
        if refresh.publicOnly { return "public repos · \(name ?? "")" }
        return name.map { "connected · \($0)" } ?? "connected"
    }

    // MARK: Not connected

    @ViewBuilder
    private var connectRows: some View {
        Picker("How to connect GitHub", selection: $path) {
            Text("just my public repos").tag(Path.publicRepos)
            Text("include private repos").tag(Path.privateRepos)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 330, alignment: .leading)
        .disabled(refresh.connecting)

        if path == .publicRepos {
            HStack(spacing: 8) {
                TextField("your GitHub username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(11))
                    .onSubmit(connectPublic)
                    .accessibilityLabel("GitHub username")
                Button("Connect", action: connectPublic)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || refresh.connecting)
            }
            Caption("no sign-in, no token · reads your public repos only")
        } else {
            tokenEntry
        }
    }

    private func connectPublic() {
        refresh.connectPublic(username)
    }

    /// The token path — first connection, or "Replace token" after GitHub
    /// rejected the saved one.
    @ViewBuilder
    private var tokenEntry: some View {
        HStack(spacing: 8) {
            Button("Create a token on GitHub…") { refresh.openTokenPage() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if refresh.replacingToken {
                Button("cancel") {
                    refresh.replacingToken = false
                    refresh.connectError = nil
                }
                .buttonStyle(.link)
                .font(Theme.mono(11))
            }
        }
        Caption("on that page pick: repository access › all repositories (or only the ones you want) · permissions › contents › read-only · then Generate token and paste it here")
        HStack(spacing: 8) {
            SecureField("paste the token", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(11))
                .onSubmit(saveToken)
                .accessibilityLabel("GitHub token")
            Button("Save", action: saveToken)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || refresh.connecting)
        }
        Caption("checked with GitHub before it's kept · stored in your keychain, never anywhere else")
        if refresh.ghInstalled {
            Button("or use the token GitHub's gh tool already has") { refresh.importTokenFromGH() }
                .buttonStyle(.link)
                .font(Theme.mono(11))
                .disabled(refresh.connecting)
        }
    }

    private func saveToken() {
        refresh.saveToken(token)
        token = ""   // never left sitting in the field, whatever GitHub says
    }

    // MARK: Picker

    @ViewBuilder
    private var pickerLink: some View {
        if refresh.hasSource {
            Button(pickerLabel) { showPicker = true }
                .buttonStyle(.link)
                .font(Theme.mono(11))
                .help("tick the repos to show, add or remove folders on this Mac")
            if !refresh.publicOnly, refresh.githubConnected,
               let listing = refresh.listing, listing.repos.contains(where: { $0.isPrivate && refresh.choices[$0.name] == nil }) {
                Caption("private repos stay off until you tick them")
            }
        }
    }

    private var pickerLabel: String {
        var parts: [String] = []
        if refresh.githubConnected {
            if let listing = refresh.listing {
                parts.append("choose repos · \(refresh.selectedCount) of \(listing.repos.count)")
            } else {
                parts.append("choose repos")
            }
        } else {
            parts.append("choose folders")
        }
        let n = refresh.folders.count
        if n > 0 { parts.append("\(n) folder\(n == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Auto-refresh

struct AutoRefreshStep: View {
    @ObservedObject var refresh: RefreshManager
    let isCurrent: Bool

    var body: some View {
        let state = stepState(done: refresh.agentEnabled, current: isCurrent)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StepGlyph(state: state)
                StepTitle(text: "Auto-refresh", state: state)
                Text(refresh.onlyWhenPluggedIn ? "daily · plugged in · lowest priority"
                                               : "daily · on battery too · lowest priority")
                    .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                Spacer()
                Toggle("Refresh automatically", isOn: Binding(get: { refresh.agentEnabled },
                                                              set: { refresh.setAutoRefresh($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!refresh.hasSource)
                    .help("once a day in the background, picking up new pushes — turn off to refresh only by hand")
            }
            if refresh.agentEnabled {
                Toggle(isOn: Binding(get: { refresh.onlyWhenPluggedIn },
                                     set: { refresh.setOnlyWhenPluggedIn($0) })) {
                    Text("refresh only when plugged in")
                        .font(Theme.mono(11)).foregroundStyle(Theme.slate)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Refresh only when plugged in")
                .help("on: a laptop waits for power before downloading · off: it refreshes on battery too · Refresh Now always runs")
                .padding(.leading, 24)
            }
            if refresh.agentNeedsApproval {
                HStack(spacing: 8) {
                    Text("waiting for approval in Login Items")
                        .font(Theme.mono(11)).foregroundStyle(Theme.alert)
                    Button("Open Login Items") { refresh.openLoginItems() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.leading, 24)
            }
        }
    }
}

// MARK: - Status (under YOUR CODE)

struct CodeStatus: View {
    @ObservedObject var refresh: RefreshManager

    @State private var showSkipped = false
    @State private var confirmDelete = false

    private var state: CorpusStore.State { refresh.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                headline
                Spacer()
                Button("Refresh Now") { refresh.refreshNow() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(refresh.refreshActive || !refresh.hasSource)
            }
            Group {
                if let run = refresh.run { progress(run) }
                if !refresh.refreshActive { problemRows }
                skippedRepos
                unreadableFolders
                diskRow
            }
            .padding(.leading, 24)
        }
        .confirmationDialog("Delete downloaded code?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(diskSize)", role: .destructive) { refresh.deleteDownloadedCode() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the code CodeSaver downloaded and the text the saver shows. Your connection, repo choices and folders stay. The next refresh downloads it all again — turn off Auto-refresh first to keep it gone.")
        }
    }

    @ViewBuilder
    private var headline: some View {
        if let run = refresh.run {
            Text("✽").font(Theme.mono(13)).foregroundStyle(Theme.violetHot)
                .shadow(color: Theme.violet.opacity(0.9), radius: 5)
            Text(RefreshManager.describe(run))
                .font(Theme.mono(12)).foregroundStyle(Theme.ink)
        } else if state.lastSuccess != nil {
            Text("✻").font(Theme.mono(13)).foregroundStyle(Theme.slate)
            let sources = refresh.folders.isEmpty ? "repos" : "sources"
            Text("\(state.fileCount.formatted()) files · \(state.repoCount) \(sources) · \(refresh.lastRefreshDescription)")
                .font(Theme.mono(12)).foregroundStyle(Theme.ink)
        } else {
            Text("·").font(Theme.mono(13)).foregroundStyle(Theme.dim)
            Text(refresh.hasSource ? "no code yet — Refresh Now fetches it"
                                   : "no code yet — connect GitHub above")
                .font(Theme.mono(12)).foregroundStyle(Theme.slate)
        }
    }

    /// A row of box-drawing cells, the saver's own idiom for a gauge.
    private func progress(_ run: CorpusStore.State.Run) -> some View {
        let cells = 24
        let fraction = run.phase == "packing" ? 1 : (run.total > 0 ? Double(run.done) / Double(run.total) : 0)
        let filled = min(cells, Int((fraction * Double(cells)).rounded()))
        return HStack(spacing: 8) {
            Text(bar(filled: filled, of: cells))
                .font(Theme.mono(10))
                .accessibilityLabel(RefreshManager.describe(run))
            Text([run.current, refresh.runIsElsewhere ? "in the background" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func bar(filled: Int, of cells: Int) -> AttributedString {
        var done = AttributedString(String(repeating: "━", count: filled))
        done.foregroundColor = Theme.violetHot
        var rest = AttributedString(String(repeating: "─", count: cells - filled))
        rest.foregroundColor = Theme.dim
        return done + rest
    }

    // MARK: Problems

    @ViewBuilder
    private var problemRows: some View {
        if let problem = state.problem {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AlertLine(problem.headline)
                Spacer(minLength: 0)
                problemAction(problem)
            }
            if let detail = problem.detail { Caption(detail) }
        } else if let legacy = state.lastError {
            AlertLine(legacy)  // written by a build from before the plain-words errors
        }
    }

    @ViewBuilder
    private func problemAction(_ problem: CorpusStore.State.Problem) -> some View {
        switch FetchError.Kind(rawValue: problem.kind) {
        case .tokenRejected?, .forbidden?:
            if !refresh.publicOnly && !refresh.replacingToken {
                Button("Replace token") {
                    refresh.connectError = nil
                    refresh.replacingToken = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .noSuchUser?:
            Button("Change") { refresh.disconnect() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var skippedRepos: some View {
        let repos = state.skipped?.filter { !$0.isFolder } ?? []
        if !repos.isEmpty {
            Button {
                showSkipped.toggle()
            } label: {
                Text("\(showSkipped ? "▾" : "▸") \(repos.count) repo\(repos.count == 1 ? "" : "s") skipped")
                    .font(Theme.mono(11)).foregroundStyle(Theme.slate)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(repos.map { "\($0.name) — \($0.reason)" }.joined(separator: "\n"))
            if showSkipped {
                ForEach(repos, id: \.name) { repo in
                    Text("\(repo.name) — \(repo.reason)")
                        .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.leading, 14)
            }
        }
    }

    @ViewBuilder
    private var unreadableFolders: some View {
        ForEach(state.skipped?.filter(\.isFolder) ?? [], id: \.name) { folder in
            let protected = LocalFolder.protectedArea(of: (folder.name as NSString).expandingTildeInPath) != nil
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("couldn't read \(folder.name)")
                        .font(Theme.mono(11)).foregroundStyle(Theme.alert)
                    Caption(folder.reason)
                }
                Spacer(minLength: 0)
                if protected {
                    Button("Open") { openFilesAndFolders() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("System Settings › Privacy & Security › Files and Folders")
                }
            }
        }
    }

    // MARK: Disk

    private var diskSize: String {
        ByteCountFormatter.string(fromByteCount: refresh.diskBytes ?? 0, countStyle: .file)
    }

    @ViewBuilder
    private var diskRow: some View {
        if let bytes = refresh.diskBytes, bytes > 0 {
            HStack(spacing: 8) {
                Text("\(diskSize) on disk")
                    .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    .help("the downloaded repos and folders, plus the text the saver reads")
                Button("delete downloaded code") { confirmDelete = true }
                    .buttonStyle(.link)
                    .font(Theme.mono(10))
                    .disabled(refresh.refreshActive)
            }
        }
    }

    private func openFilesAndFolders() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}
