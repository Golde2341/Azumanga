import SwiftUI

/// Browse/search across enabled sources, with dynamic filters.
struct BrowseView: View {
    @Environment(DiscoveryModel.self) private var model
    @Environment(LibraryModel.self) private var library
    @Environment(SettingsStore.self) private var settings

    @State private var searchText = ""
    @State private var showFilters = false

    var body: some View {
        @Bindable var model = model

        Group {
            if model.isLoading && visibleResults.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = model.errorMessage, visibleResults.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await model.loadFirstPage() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if visibleResults.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text(noResultsDescription)
                )
            } else {
                ScrollView {
                    MangaGrid(
                        items: visibleResults,
                        favoriteIds: favoriteIds,
                        progressLabel: { _ in nil },
                        isLoadingMore: model.isLoadingMore,
                        onReachEnd: { Task { await model.loadNextPage() } }
                    )
                }
            }
        }
        .navigationTitle("Browse")
        .searchable(text: $searchText, prompt: "Search manga")
        .onSubmit(of: .search) {
            Task { await model.search(query: searchText) }
        }
        .task(id: searchText) {
            let text = searchText
            if text.isEmpty && model.mode != .search { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.search(query: text)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showFilters) {
            FilterSheet(model: model)
        }
        .task {
            await model.refreshSources()
            if model.results.isEmpty {
                await model.loadFirstPage()
            }
        }
        .navigationDestination(for: Manga.self) { manga in
            MangaDetailView(manga: manga)
        }
        .onChange(of: settings.mangaDexConfiguration) { _, _ in
            Task {
                await model.refreshSources()
            }
        }
    }

    private var favoriteIds: Set<String> {
        Set(library.entries.filter(\.isFavorite).map(\.key))
    }

    private var visibleResults: [Manga] {
        guard settings.hideNSFWResults else { return model.results }
        return model.results.filter { !$0.isNSFW }
    }

    private var noResultsDescription: String {
        if settings.hideNSFWResults {
            return "No non-NSFW results. You can change this in Settings → Sources."
        }
        return searchText.isEmpty
            ? "Nothing to show for this source yet."
            : "No manga matched “\(searchText)”."
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: Binding(
                get: { model.mode == .search ? .popular : model.mode },
                set: { newValue in
                    model.mode = newValue
                    Task { await model.loadFirstPage() }
                }
            )) {
                ForEach([DiscoveryModel.Mode.popular, .latest], id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }

        ToolbarItem(placement: .automatic) {
            Picker("Source", selection: Binding(
                get: { model.selectedSourceId ?? "" },
                set: { newValue in Task { await model.selectSource(newValue) } }
            )) {
                ForEach(model.sourcePicker) { source in
                    Text(source.name).tag(source.id)
                }
            }
            .frame(minWidth: 140)
        }

        ToolbarItem(placement: .automatic) {
            Button {
                showFilters = true
            } label: {
                Label("Filters", systemImage: model.filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .disabled(model.filterDescriptors.isEmpty)
        }

        ToolbarItem(placement: .automatic) {
            Button {
                Task { await model.loadFirstPage() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }
}

/// Filter editor generated from the source's filter descriptors.
private struct FilterSheet: View {
    let model: DiscoveryModel
    @Environment(\.dismiss) private var dismiss

    @State private var text: [String: String] = [:]
    @State private var toggles: [String: Bool] = [:]
    @State private var selections: [String: String] = [:]
    @State private var multiSelections: [String: Set<String>] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(model.filterDescriptors) { filter in
                    switch filter.kind {
                    case .text:
                        TextField(filter.name, text: Binding(
                            get: { text[filter.id] ?? "" },
                            set: { text[filter.id] = $0 }
                        ))
                    case .toggle:
                        Toggle(filter.name, isOn: Binding(
                            get: { toggles[filter.id] ?? false },
                            set: { toggles[filter.id] = $0 }
                        ))
                    case .select(let options):
                        Picker(filter.name, selection: Binding(
                            get: { selections[filter.id] ?? "" },
                            set: { selections[filter.id] = $0 }
                        )) {
                            ForEach(options) { option in
                                Text(option.name).tag(option.id)
                            }
                        }
                    case .multiSelect(let options):
                        Section(filter.name) {
                            ForEach(options) { option in
                                Toggle(option.name, isOn: Binding(
                                    get: { multiSelections[filter.id, default: []].contains(option.id) },
                                    set: { isOn in
                                        var set = multiSelections[filter.id, default: []]
                                        if isOn { set.insert(option.id) } else { set.remove(option.id) }
                                        multiSelections[filter.id] = set
                                    }
                                ))
                            }
                        }
                    case .group:
                        EmptyView()
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Clear") {
                    text = [:]
                    toggles = [:]
                    selections = [:]
                    multiSelections = [:]
                    Task { await model.clearFilters() }
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    Task { await apply() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 380, height: 460)
        .onAppear(perform: loadCurrent)
    }

    private func loadCurrent() {
        for value in model.filters {
            switch value.kind {
            case .text(let string): text[value.filterId] = string
            case .toggle(let bool): toggles[value.filterId] = bool
            case .select(let string): selections[value.filterId] = string
            case .multiSelect(let strings): multiSelections[value.filterId] = Set(strings)
            }
        }
    }

    private func apply() async {
        for filter in model.filterDescriptors {
            switch filter.kind {
            case .text:
                if let value = text[filter.id], !value.isEmpty {
                    await model.setFilter(id: filter.id, value: .text(value))
                }
            case .toggle:
                if toggles[filter.id] == true {
                    await model.setFilter(id: filter.id, value: .toggle(true))
                }
            case .select:
                if let value = selections[filter.id], !value.isEmpty {
                    await model.setFilter(id: filter.id, value: .select(value))
                }
            case .multiSelect:
                if let values = multiSelections[filter.id], !values.isEmpty {
                    await model.setFilter(id: filter.id, value: .multiSelect(Array(values).sorted()))
                }
            case .group:
                break
            }
        }
        await model.loadFirstPage()
    }
}
