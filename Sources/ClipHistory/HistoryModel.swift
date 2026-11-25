import AppKit
import ClipHistoryCore

final class HistoryModel: ObservableObject {
    static let pageSize = 100
    static let previewTextLength = 20_000

    @Published var query = "" {
        didSet { if query != oldValue { reload() } }
    }
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var selectedID: Int64?
    @Published private(set) var previewText = ""
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var totalCount = 0
    @Published private(set) var focusToken = 0

    var onPaste: ((ClipItem) -> Void)?
    var onClose: (() -> Void)?

    private let store: Store
    private var reachedEnd = false

    init(store: Store) {
        self.store = store
    }

    var selectedItem: ClipItem? {
        items.first { $0.id == selectedID }
    }

    func prepareForDisplay() {
        if query.isEmpty { reload() } else { query = "" }
        focusToken += 1
    }

    func reload(keepSelection: Bool = false) {
        let previous = selectedID
        items = (try? store.search(query, limit: Self.pageSize)) ?? []
        reachedEnd = items.count < Self.pageSize
        totalCount = (try? store.count()) ?? 0
        if keepSelection, let previous, items.contains(where: { $0.id == previous }) {
            select(previous)
        } else {
            select(items.first?.id)
        }
    }

    func loadMoreIfNeeded(after item: ClipItem) {
        guard !reachedEnd, item.id == items.last?.id else { return }
        let more = (try? store.search(query, limit: Self.pageSize, offset: items.count)) ?? []
        reachedEnd = more.count < Self.pageSize
        items += more
    }

    func select(_ id: Int64?) {
        guard id != selectedID || id == nil else { return }
        selectedID = id
        previewImage = nil
        previewText = ""
        guard let item = selectedItem else { return }
        if item.kind == .image {
            previewImage = item.imagePath.flatMap(NSImage.init(contentsOfFile:))
        } else {
            previewText = (try? store.fullText(id: item.id, maxLength: Self.previewTextLength)) ?? item.preview
        }
    }

    func pasteSelected() {
        if let item = selectedItem { onPaste?(item) }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch (Int(event.keyCode), command) {
        case (125, false): moveSelection(by: 1)
        case (126, false): moveSelection(by: -1)
        case (36, false), (76, false): pasteSelected()
        case (53, false): if query.isEmpty { onClose?() } else { query = "" }
        case (51, true): deleteSelected()
        case (35, true): togglePinSelected()
        default: return false
        }
        return true
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), items.count - 1)
        select(items[next].id)
        loadMoreIfNeeded(after: items[next])
    }

    private func deleteSelected() {
        guard let index = items.firstIndex(where: { $0.id == selectedID }) else { return }
        try? store.delete(id: items[index].id)
        items.remove(at: index)
        totalCount = (try? store.count()) ?? 0
        select(items.isEmpty ? nil : items[min(index, items.count - 1)].id)
    }

    private func togglePinSelected() {
        guard let id = selectedID else { return }
        try? store.togglePin(id: id)
        reload(keepSelection: true)
    }
}
