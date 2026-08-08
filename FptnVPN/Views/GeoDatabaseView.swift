/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

// MARK: - Verdict presentation

private extension GeoVerdict {
    /// Drawn from the app's own palette rather than a new one: teal is already
    /// the accent, and the violet is the background hue lifted into the
    /// foreground. Red is reserved for the one verdict that destroys traffic.
    var tint: Color {
        switch self {
        case .direct: Color.appAccent
        case .fptn:   Color(red: 0.58, green: 0.40, blue: 0.98)
        case .block:  Color.appError
        }
    }
}

/// The verdict, set as a small tracked-out label rather than a filled pill.
/// Pills on every row would make the list read as a wall of badges; this keeps
/// the addresses the loudest thing on screen, which is what people scan.
private struct GeoVerdictLabel: View {
    let verdict: GeoVerdict

    var body: some View {
        Text(verdict.displayName.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(verdict.tint)
    }
}

// MARK: - Coverage bar

/// How much address space a rule claims, as a bar.
///
/// This is the one piece of ornament on the screen, and it earns its place: a
/// routing table is a set of ranges, and "/18 versus /32" is the difference
/// between sixteen thousand addresses and one. The number alone does not carry
/// that at a glance; a width does.
private struct GeoCoverageBar: View {
    let weight: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.appSeparator.opacity(0.35))
                Capsule()
                    .fill(tint.opacity(0.8))
                    // A /32 would otherwise be invisible; floor it at a tick so
                    // "smallest possible range" still reads as a mark.
                    .frame(width: max(2, proxy.size.width * weight))
            }
        }
        .frame(width: 46, height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Root

struct GeoDatabaseView: View {
    @StateObject private var store = GeoDatabaseStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch store.state {
                case .absent:
                    GeoEmptyStateView(isBusy: false) { Task { await store.download() } }
                case .downloading:
                    GeoProgressView(message: "Downloading from \(GeoDatabaseSource.attribution)…")
                case .parsing:
                    GeoProgressView(message: "Reading the routing lists…")
                case .failed(let message):
                    GeoFailureView(message: message) { Task { await store.download() } }
                case .ready(let database):
                    GeoLoadedView(database: database, store: store)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Geo Database")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.appAccent)
                }
            }
        }
        .task {
            // Only reads what is already on disk. Downloading is always the
            // person's decision — this is half a megabyte over someone's
            // mobile data.
            if store.state.database == nil { await store.loadStored() }
        }
    }
}

// MARK: - Empty state

private struct GeoEmptyStateView: View {
    let isBusy: Bool
    let onDownload: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No routing lists yet")
                        .font(.title3.bold())
                        .foregroundStyle(Color.appPrimaryText)
                    Text("""
                        Two files describe which traffic can skip the FPTN server: \
                        a table of IP ranges and a table of domain rules. Together \
                        they are about 490 KB.
                        """)
                        .font(.subheadline)
                        .foregroundStyle(Color.appSecondaryText)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(GeoDataKind.allCases, id: \.self) { kind in
                        HStack(spacing: 10) {
                            Text(kind.fileName)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Color.appPrimaryText)
                            Spacer(minLength: 8)
                            Text(kind.displayName)
                                .font(.caption)
                                .foregroundStyle(Color.appSecondaryText)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                Button(action: onDownload) {
                    Text("Download database")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.appAccent, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(Color.black)
                }
                .disabled(isBusy)

                GeoAttributionNote()
            }
            .padding(20)
        }
    }
}

private struct GeoProgressView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(Color.appAccent)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.appSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GeoFailureView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The database could not be loaded")
                .font(.headline)
                .foregroundStyle(Color.appPrimaryText)
            // The parser reports byte offsets and HTTP codes; passing them
            // through verbatim is more use than "something went wrong".
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color.appSecondaryText)
            Button("Try again", action: onRetry)
                .foregroundStyle(Color.appAccent)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}

/// Says whose lists these are. Shown in both the empty and loaded states —
/// the rules encode a particular view of what should bypass a VPN, and that
/// view belongs to someone.
private struct GeoAttributionNote: View {
    var body: some View {
        Text("Lists are compiled and published by the \(GeoDatabaseSource.attribution) project. FPTN downloads them unmodified.")
            .font(.caption)
            .foregroundStyle(Color.appSecondaryText)
    }
}

// MARK: - Loaded

private struct GeoLoadedView: View {
    let database: GeoDatabase
    @ObservedObject var store: GeoDatabaseStore

    @State private var kind: GeoDataKind = .geoip
    @State private var query: String = ""

    private var groups: [GeoGroup] {
        kind == .geoip ? database.ip.groups : database.site.groups
    }

    /// Three IP groups all marked Direct looks like a mistake until you know
    /// they belong to different profiles, so the screen says so rather than
    /// leaving the reader to wonder.
    private var groupsFooter: String {
        switch kind {
        case .geoip:
            "These groups are alternatives, not layers. DIRECT is the broad Russian and Belarusian set; WHITELIST is the narrow curated one, used when everything else goes through the server; PRIVATE is local address space that must never be tunnelled."
        case .geosite:
            "Verdicts follow the publisher's own routing profile. Some are deliberate rather than obvious: games and Twitch go direct because they waste server traffic and misbehave through a proxy."
        }
    }

    var body: some View {
        List {
            Section {
                GeoLookupField(query: $query)
                if !query.isEmpty {
                    GeoLookupResult(database: database, query: query)
                }
            } header: {
                Text("Look up")
                    .foregroundStyle(Color.appAccent)
            } footer: {
                Text("Type an IP address or a domain to see which rule claims it.")
                    .foregroundStyle(Color.appSecondaryText)
            }
            .listRowBackground(Color.appSurface)

            Section {
                Picker("Table", selection: $kind) {
                    Text("IP ranges").tag(GeoDataKind.geoip)
                    Text("Domains").tag(GeoDataKind.geosite)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            .listRowBackground(Color.clear)

            Section {
                ForEach(groups) { group in
                    NavigationLink {
                        GeoGroupDetailView(database: database, kind: kind, group: group)
                    } label: {
                        GeoGroupRow(group: group)
                    }
                }
            } header: {
                Text("\(groups.count) groups · \(formatted(kind == .geoip ? database.ip.ruleCount : database.site.ruleCount)) rules")
                    .foregroundStyle(Color.appAccent)
            } footer: {
                Text(groupsFooter)
                    .foregroundStyle(Color.appSecondaryText)
            }
            .listRowBackground(Color.appSurface)

            GeoProvenanceSection(database: database, store: store)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
    }
}

private struct GeoGroupRow: View {
    let group: GeoGroup

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Color.appPrimaryText)
                GeoVerdictLabel(verdict: group.verdict)
            }
            Spacer(minLength: 8)
            Text(formatted(group.entryCount))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Color.appSecondaryText)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Lookup

private struct GeoLookupField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.magnifyingglass")
                .foregroundStyle(Color.appSecondaryText)
            TextField("77.88.55.60 or example.com", text: $query)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Color.appPrimaryText)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.appSecondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
    }
}

/// The answer to "what happens to this?", in the routing table's own terms.
///
/// This is the reason the screen exists. A text filter would tell you a string
/// appears somewhere in 42,000 rows; a lookup tells you which single rule wins
/// and why — which for overlapping data is a different, and much more useful,
/// answer.
private struct GeoLookupResult: View {
    let database: GeoDatabase
    let query: String

    var body: some View {
        if let address = GeoAddress(text: query) {
            if let rule = database.ip.longestPrefixMatch(address) {
                resolved(
                    group: database.ip.groups[rule.groupIndex],
                    via: rule.displayText,
                    note: "longest matching prefix"
                )
            } else {
                unresolved("No IP range claims this address.")
            }
        } else if looksLikeDomain {
            if let rule = database.site.bestMatch(for: query) {
                resolved(
                    group: database.site.groups[rule.groupIndex],
                    via: rule.value,
                    note: rule.kind.displayName + (rule.kind.isSupportedByEngine ? "" : " · not supported by the engine yet")
                )
            } else {
                unresolved("No domain rule matches this name.")
            }
        } else {
            unresolved("Enter an IP address or a domain name.")
        }
    }

    private var looksLikeDomain: Bool {
        query.contains(".") && !query.hasSuffix(".")
    }

    private func resolved(group: GeoGroup, via: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                GeoVerdictLabel(verdict: group.verdict)
                Text(group.name)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Color.appPrimaryText)
            }
            Text(group.verdict.explanation)
                .font(.caption)
                .foregroundStyle(Color.appSecondaryText)
            HStack(spacing: 6) {
                Text("via")
                    .font(.caption2)
                    .foregroundStyle(Color.appSecondaryText)
                Text(via)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.appPrimaryText)
                Text("·")
                    .foregroundStyle(Color.appSecondaryText)
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Color.appSecondaryText)
            }
        }
        .padding(.vertical, 4)
    }

    private func unresolved(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(Color.appSecondaryText)
            .padding(.vertical, 4)
    }
}

// MARK: - Group detail

/// One group's entries — a window onto them, not all of them.
///
/// The largest group holds 35,656 ranges. Rendering all of them is possible but
/// pointless: nobody learns anything by scrolling to range 20,000, and the list
/// stops being readable long before that. So the view shows a bounded sample
/// and says plainly how much it is not showing; narrowing is done by filtering,
/// and answering "what happens to this address" is done by the lookup on the
/// previous screen, which is the question the data actually exists to answer.
private struct GeoGroupDetailView: View {
    let database: GeoDatabase
    let kind: GeoDataKind
    let group: GeoGroup

    /// Enough to see the shape of a group and spot a malformed decode; far
    /// below the point where a list becomes a scroll endurance test.
    private static let renderLimit = 300

    @State private var rows: [Row] = []
    @State private var filter: String = ""
    @State private var isBuilding = true

    struct Row: Identifiable, Sendable {
        let id: Int
        let text: String
        let detail: String
        let weight: Double
    }

    private var matches: [Row] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { $0.text.contains(needle) }
    }

    var body: some View {
        let matches = matches
        let shown = Array(matches.prefix(Self.renderLimit))
        let hidden = matches.count - shown.count

        List {
            Section {
                if isBuilding {
                    ProgressView().tint(Color.appAccent)
                } else if matches.isEmpty {
                    Text("Nothing in \(group.name) matches “\(filter)”.")
                        .font(.footnote)
                        .foregroundStyle(Color.appSecondaryText)
                }
                ForEach(shown) { row in
                    HStack(spacing: 10) {
                        Text(row.text)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Color.appPrimaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if kind == .geoip {
                            GeoCoverageBar(weight: row.weight, tint: group.verdict.tint)
                        } else {
                            Text(row.detail)
                                .font(.caption2)
                                .foregroundStyle(Color.appSecondaryText)
                        }
                    }
                    .padding(.vertical, 1)
                }
            } header: {
                HStack {
                    GeoVerdictLabel(verdict: group.verdict)
                    Spacer()
                    Text(countSummary(shown: shown.count, matching: matches.count))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.appSecondaryText)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if hidden > 0 {
                        Text("\(formatted(hidden)) more not shown. Filter to narrow the list, or use Look up to resolve one address.")
                            .foregroundStyle(Color.appSecondaryText)
                    }
                    if kind == .geoip {
                        Text("The bar shows how much of the address space each range covers.")
                            .foregroundStyle(Color.appSecondaryText)
                    }
                }
            }
            .listRowBackground(Color.appSurface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .searchable(text: $filter, prompt: "Filter \(group.name)")
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: group.index) {
            // Off the main actor: formatting tens of thousands of addresses is
            // fast but not free, and it has no business blocking the push
            // animation.
            let database = database
            let kind = kind
            let index = group.index
            let built = await Task.detached(priority: .userInitiated) {
                Self.makeRows(database: database, kind: kind, groupIndex: index)
            }.value
            rows = built
            isBuilding = false
        }
    }

    private func countSummary(shown: Int, matching: Int) -> String {
        if matching == rows.count {
            return shown == matching
                ? "\(formatted(matching))"
                : "\(formatted(shown)) of \(formatted(matching))"
        }
        return "\(formatted(shown)) of \(formatted(matching)) matching"
    }

    private nonisolated static func makeRows(
        database: GeoDatabase,
        kind: GeoDataKind,
        groupIndex: Int
    ) -> [Row] {
        switch kind {
        case .geoip:
            return database.ip.rules
                .filter { $0.groupIndex == groupIndex }
                .map { Row(id: $0.id, text: $0.displayText, detail: "", weight: $0.coverageWeight) }
        case .geosite:
            return database.site.rules
                .filter { $0.groupIndex == groupIndex }
                .map { Row(id: $0.id, text: $0.value, detail: $0.kind.displayName, weight: 0) }
        }
    }
}

// MARK: - Provenance

private struct GeoProvenanceSection: View {
    let database: GeoDatabase
    @ObservedObject var store: GeoDatabaseStore

    @State private var showDeleteConfirmation = false

    var body: some View {
        Section {
            row("Fetched", database.newestFetchDate.formatted(date: .abbreviated, time: .shortened))
            row(GeoDataKind.geoip.fileName, "\(byteText(database.ipProvenance.byteCount)) · \(database.ipProvenance.shortHash)")
            row(GeoDataKind.geosite.fileName, "\(byteText(database.siteProvenance.byteCount)) · \(database.siteProvenance.shortHash)")
            row("Decoded", "\(formatted(database.totalRuleCount)) rules in \(parseText)")

            Button {
                Task { await store.download() }
            } label: {
                Text("Update from \(GeoDatabaseSource.attribution)")
                    .foregroundStyle(Color.appAccent)
            }
            .disabled(store.state.isBusy)

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Text("Delete database")
            }
            .disabled(store.state.isBusy)
            .confirmationDialog(
                "Delete the downloaded routing lists?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { store.removeStored() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Both files are removed from this device. You can download them again at any time.")
            }
        } header: {
            Text("Source")
                .foregroundStyle(Color.appAccent)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                GeoAttributionNote()
                // Stated plainly. The screen shows verdicts, and it would be
                // easy to read them as describing what the tunnel is doing.
                Text("Reference only. Split routing still uses its built-in test policy — these lists are not applied to traffic yet.")
                    .foregroundStyle(Color.appWarning)
            }
        }
        .listRowBackground(Color.appSurface)
    }

    private var parseText: String {
        let millis = Double(database.parseDuration.components.attoseconds) / 1e15
            + Double(database.parseDuration.components.seconds) * 1000
        return millis < 1 ? "under a millisecond" : String(format: "%.0f ms", millis)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Color.appPrimaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Color.appSecondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func byteText(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - Helpers

private func formatted(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
}
