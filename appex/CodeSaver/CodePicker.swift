//
//  CodePicker.swift
//  CodeSaver
//
//  The "choose repos" sheet: every listed repo as a checkbox (private ones
//  badged, and off until ticked), then the folders on this Mac in the same
//  list. Ticks are saved as they're made — the hourly agent reads the same
//  defaults key — and Done applies them with a refresh in the window.
//

import SwiftUI

struct CodePicker: View {
    @ObservedObject var refresh: RefreshManager
    let onDone: (_ changed: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startChoices: [String: Bool] = [:]
    @State private var startFolders: [LocalFolder] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                eyebrow("CHOOSE CODE")
                Spacer()
                Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
            if refresh.githubConnected {
                repoSection
            } else {
                caption("GitHub isn't connected — only folders on this Mac are used")
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            folderSection
        }
        .padding(20)
        .frame(width: 440)
        .background(.black)
        .preferredColorScheme(.dark)
        .tint(Theme.violet)
        .onAppear {
            startChoices = refresh.choices
            startFolders = refresh.folders
            if refresh.githubConnected && refresh.listing == nil { refresh.loadListing() }
        }
        // However the sheet goes away: ticks are already saved, and this
        // applies them.
        .onDisappear {
            onDone(refresh.choices != startChoices || refresh.folders != startFolders)
        }
    }

    // MARK: Repos

    @ViewBuilder
    private var repoSection: some View {
        let listing = refresh.listing
        HStack(spacing: 10) {
            Text(listing.map { "\(refresh.accountName ?? $0.owner) · \(refresh.selectedCount) of \($0.repos.count) repos" }
                 ?? "\(refresh.accountName ?? "GitHub") · repos")
                .font(Theme.mono(11)).foregroundStyle(Theme.ink)
            Spacer()
            if listing != nil {
                Button("all") { refresh.setAll(true) }
                Button("none") { refresh.setAll(false) }
            }
            Button("reload") { refresh.loadListing() }
                .disabled(refresh.isListing)
                .help(refresh.publicOnly ? "lists again — one of GitHub's 60 requests an hour without a token" : "lists again")
        }
        .buttonStyle(.link)
        .font(Theme.mono(11))
        caption(refresh.publicOnly
                ? "unticked repos leave the saver at the next refresh"
                : "private repos stay off until you tick them · unticked repos leave the saver at the next refresh")

        if let error = refresh.listingError {
            Text(error)
                .font(Theme.mono(11)).foregroundStyle(Theme.alert)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let listing {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(listing.repos, id: \.name) { repo in row(repo) }
                }
                .padding(.vertical, 2)
            }
            .frame(height: min(280, CGFloat(listing.repos.count) * 21 + 6))
            if let note = listingNote(listing) { caption(note) }
        } else if refresh.isListing {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
                caption("listing your repos…")
            }
        }
    }

    private func listingNote(_ listing: CorpusStore.State.Listing) -> String? {
        var notes: [String] = []
        if listing.forks > 0 {
            notes.append("\(listing.forks) fork\(listing.forks == 1 ? "" : "s") not shown — a fork is mostly someone else's code")
        }
        if !listing.complete { notes.append("only the first 1,000 repos are listed") }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    private func row(_ repo: CorpusStore.State.Listing.Repo) -> some View {
        let bytes = repo.sizeKB * 1024
        let tooBig = bytes >= CorpusIngest.maxTarballBytes
        return Toggle(isOn: Binding(get: { refresh.isSelected(repo) },
                                    set: { refresh.setSelected(repo, $0) })) {
            HStack(spacing: 6) {
                Text(repo.name)
                    .font(Theme.mono(11)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                if repo.isPrivate {
                    Text("private")
                        .font(Theme.mono(9)).foregroundStyle(Theme.violetHot)
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.violet.opacity(0.6), lineWidth: 1))
                }
                Spacer(minLength: 8)
                Text(tooBig ? "\(FetchError.size(bytes)) · too big" : (bytes > 0 ? FetchError.size(bytes) : "empty"))
                    .font(Theme.mono(10))
                    .foregroundStyle(tooBig ? Theme.alert : Theme.dim)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(repo.isPrivate ? "\(repo.name), private" : repo.name)
        .help(tooBig ? "bigger than CodeSaver downloads (\(FetchError.size(CorpusIngest.maxTarballBytes))) — skipped even when ticked" : "")
    }

    // MARK: Folders

    @ViewBuilder
    private var folderSection: some View {
        eyebrow("FOLDERS ON THIS MAC")
        if refresh.folders.isEmpty {
            caption("none yet — add any folder of code, a checkout or a scratch directory")
        }
        ForEach(refresh.folders) { folder in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.displayPath)
                        .font(Theme.mono(11)).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                    if let problem = refresh.folderProblem(folder) {
                        Text("couldn't read it — \(problem)")
                            .font(Theme.mono(10)).foregroundStyle(Theme.alert)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button("Remove") { refresh.removeFolder(folder) }
                    .buttonStyle(.link)
                    .font(Theme.mono(11))
                    .help("stop showing this folder — it leaves the saver at the next refresh")
            }
        }
        Button("Add folder…") { refresh.chooseFolders() }
            .buttonStyle(.bordered)
            .controlSize(.small)
        caption("same filters as GitHub repos: source files only — no dependencies, build output, generated files or secrets")
    }

    // MARK: Helpers

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(10, .semibold))
            .tracking(3)
            .foregroundStyle(Theme.dim)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(10))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }
}
