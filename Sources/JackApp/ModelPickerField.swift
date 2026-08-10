import SwiftUI

/// Subsequence scorer behind the model picker's search field. Typing "g31fl"
/// should surface "google/gemini-3.1-flash-lite", which a `contains` filter
/// never will.
enum FuzzyMatch {

    /// Higher is better. `nil` when `query` is not a subsequence of `candidate`.
    /// An empty query matches everything at score 0.
    static func score(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }

        let needle = Array(query.lowercased())
        let haystack = Array(candidate.lowercased())
        guard needle.count <= haystack.count else { return nil }

        var total = 0
        var needleIndex = 0
        var previousMatch: Int?

        for (index, character) in haystack.enumerated() {
            guard needleIndex < needle.count, character == needle[needleIndex] else { continue }

            var points = 1
            if let previousMatch, previousMatch == index - 1 {
                points += 8 // runs of adjacent characters are the strongest signal
            }
            if index == 0 {
                points += 6
            } else if !haystack[index - 1].isLetter && !haystack[index - 1].isNumber {
                points += 4 // start of a word/segment: the "f" in "…-flash-lite"
            }
            total += points

            previousMatch = index
            needleIndex += 1
        }

        guard needleIndex == needle.count else { return nil }
        // Shorter candidates win ties, so "gemini-3.1-flash-lite" outranks
        // "gemini-3.1-flash-lite-image-preview" for the same query.
        return total * 100 - haystack.count
    }

    /// Best score across a model's display name and its id.
    static func score(query: String, model: OpenRouterModelInfo) -> Int? {
        let byName = score(query: query, candidate: model.name)
        let byId = score(query: query, candidate: model.id)
        switch (byName, byId) {
        case let (name?, id?): return max(name, id)
        case let (name?, nil): return name
        case let (nil, id?): return id
        default: return nil
        }
    }

    /// Models matching `query`, best first. Ties fall back to name order so the
    /// list doesn't reshuffle between keystrokes.
    static func rank(query: String, models: [OpenRouterModelInfo]) -> [OpenRouterModelInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return models }

        return models
            .compactMap { model -> (OpenRouterModelInfo, Int)? in
                score(query: trimmed, model: model).map { (model, $0) }
            }
            .sorted {
                $0.1 == $1.1
                    ? $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
                    : $0.1 > $1.1
            }
            .map(\.0)
    }
}

/// Combobox for choosing an OpenRouter model: one control that opens a
/// searchable, keyboard-navigable list. Replaces the old split of a menu plus a
/// detached search field, where you had to type in one place to change what a
/// different control showed.
struct ModelPickerField: View {
    let icon: String
    let title: String
    let models: [OpenRouterModelInfo]
    @Binding var selection: String

    @State private var isPresented = false
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    // Arrow keys scroll the list under a stationary cursor, which fires
    // `onHover` on whatever row slides beneath it and yanks the highlight
    // straight back. Hover only counts once the pointer has physically moved.
    @State private var pointerLocation: CGPoint?
    @State private var pointerIsLive = false

    private var matches: [OpenRouterModelInfo] {
        FuzzyMatch.rank(query: query, models: models)
    }

    private var selectedModel: OpenRouterModelInfo? {
        models.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(selection)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)

                Button {
                    open()
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedModel?.name ?? selection)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 260, alignment: .trailing)
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    picker
                }
            }

            // A model id that isn't in the catalog 404s at request time, which
            // would otherwise only show up as a silent cleanup failure.
            if !models.isEmpty, selectedModel == nil {
                Label("Not in OpenRouter's catalog — requests will fail. Pick another.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Popover

    private var picker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Search models…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    // Typing reshuffles the list under the cursor, so the same
                    // hover suppression applies: the top match stays highlighted.
                    .onChange(of: query) { _, _ in
                        pointerIsLive = false
                        highlighted = 0
                    }
                    .onKeyPress(.downArrow) { move(by: 1) }
                    .onKeyPress(.upArrow) { move(by: -1) }
                    .onKeyPress(.return) { commitHighlighted() }
                    .onKeyPress(.escape) { isPresented = false; return .handled }

                if !query.isEmpty {
                    Button {
                        query = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if models.isEmpty {
                message("No models loaded — add your OpenRouter key, then hit Refresh Models.")
            } else if matches.isEmpty {
                message("No model matches “\(query)”.")
            } else {
                results
            }
        }
        .frame(width: 400)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, model in
                        row(model, isHighlighted: index == highlighted)
                            .id(model.id)
                            .contentShape(.rect)
                            .onTapGesture { commit(model.id) }
                            .onHover { if $0, pointerIsLive { highlighted = index } }
                    }
                }
                .padding(4)
                .onContinuousHover(coordinateSpace: .global) { phase in
                    switch phase {
                    case let .active(location):
                        if let previous = pointerLocation,
                           hypot(location.x - previous.x, location.y - previous.y) > 2 {
                            pointerIsLive = true
                        }
                        pointerLocation = location
                    case .ended:
                        pointerIsLive = false
                        pointerLocation = nil
                    }
                }
            }
            .frame(height: 300)
            .onChange(of: highlighted) { _, index in
                guard matches.indices.contains(index) else { return }
                withAnimation(.linear(duration: 0.08)) {
                    proxy.scrollTo(matches[index].id, anchor: .center)
                }
            }
        }
    }

    private func row(_ model: OpenRouterModelInfo, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .opacity(model.id == selection ? 1 : 0)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                    .lineLimit(1)
                Text(model.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isHighlighted ? .secondary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if model.isFree {
                badge("free")
            }
            if let context = model.contextLength, context > 0 {
                badge(contextLabel(context))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.18) : .clear)
        )
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.primary.opacity(0.07))
            )
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 24)
    }

    private func contextLabel(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return "\(tokens / 1_000_000)M" }
        if tokens >= 1_000 { return "\(tokens / 1_000)K" }
        return "\(tokens)"
    }

    // MARK: - Behaviour

    private func open() {
        query = ""
        // Open on the current selection rather than the top of the catalog.
        highlighted = models.firstIndex { $0.id == selection } ?? 0
        pointerIsLive = false
        pointerLocation = nil
        isPresented = true
        searchFocused = true
    }

    private func move(by delta: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        pointerIsLive = false // keyboard takes over until the mouse moves again
        highlighted = min(max(highlighted + delta, 0), matches.count - 1)
        return .handled
    }

    private func commitHighlighted() -> KeyPress.Result {
        guard matches.indices.contains(highlighted) else { return .ignored }
        commit(matches[highlighted].id)
        return .handled
    }

    private func commit(_ id: String) {
        selection = id
        isPresented = false
    }
}
