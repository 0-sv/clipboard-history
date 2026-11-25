import ClipHistoryCore
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @FocusState private var searchFocused: Bool

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 300)
                Divider()
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search clipboard history", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
            Text("\(model.totalCount) items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.items) { item in
                        row(item)
                            .id(item.id)
                            .onAppear { model.loadMoreIfNeeded(after: item) }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .overlay {
                if model.items.isEmpty {
                    Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ item: ClipItem) -> some View {
        let selected = item.id == model.selectedID
        return HStack(spacing: 8) {
            Image(systemName: icon(for: item))
                .frame(width: 18)
                .foregroundStyle(selected ? .white : .secondary)
            Text(title(for: item))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(selected ? .white : .primary)
            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(selected ? .white : .orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
        // A count-2 onTapGesture ahead of the single tap delays every click by the double-click interval.
        .onTapGesture { model.select(item.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.select(item.id)
            model.pasteSelected()
        })
    }

    @ViewBuilder
    private var preview: some View {
        if let item = model.selectedItem {
            VStack(spacing: 0) {
                Group {
                    if item.kind == .image, let image = model.previewImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                    } else {
                        ScrollView {
                            Text(model.previewText)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Text(item.appName ?? "Unknown app")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
                    Text(Self.relativeFormatter.localizedString(for: item.usedAt, relativeTo: Date()))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        } else {
            Color.clear
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("↩ Paste")
            Text("⌘P Pin")
            Text("⌘⌫ Delete")
            Text("esc Close")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func icon(for item: ClipItem) -> String {
        switch item.kind {
        case .text: return item.preview.hasPrefix("http://") || item.preview.hasPrefix("https://") ? "link" : "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    private func title(for item: ClipItem) -> String {
        switch item.kind {
        case .file:
            let paths = item.preview.split(separator: "\n")
            let name = paths.first.map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? ""
            return paths.count > 1 ? "\(name) + \(paths.count - 1) more" : name
        case .text, .image:
            return item.preview
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ⏎ ")
        }
    }
}
