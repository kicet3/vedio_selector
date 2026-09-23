import SwiftUI
import FramepickCore

enum Palette {
    static let sidebar = Color(red: 0.09, green: 0.145, blue: 0.22)
    static let canvas = Color(red: 0.09, green: 0.13, blue: 0.18)
    static let background = Color(red: 0.96, green: 0.97, blue: 0.985)
    static let accent = Color(red: 0.21, green: 0.47, blue: 0.83)
    static let rose = Color(red: 0.79, green: 0.31, blue: 0.45)
    static let ink = Color(red: 0.13, green: 0.18, blue: 0.25)
}

struct ActionButton: View {
    let title: String
    let symbol: String
    var prominent = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 13).padding(.vertical, 9)
                .foregroundStyle(prominent ? .white : Palette.ink)
                .background(prominent ? Palette.accent : .white, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(prominent ? .clear : .black.opacity(0.1)))
        }.buttonStyle(.plain)
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 30)
                .foregroundStyle(active ? Palette.rose : Palette.ink)
                .background(active ? Palette.rose.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct AsyncMediaImage: View {
    let identity: String
    var fill = false
    var quiet = false
    let load: () async throws -> CGImage
    @State private var image: CGImage?
    @State private var failure: String?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1).resizable()
                        .aspectRatio(contentMode: fill ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let failure {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.title3)
                        if !quiet { Text(failure).font(.caption).multilineTextAlignment(.center).lineLimit(3).padding(12) }
                    }.foregroundStyle(.secondary).help(failure)
                } else { ProgressView().controlSize(.small) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: identity) {
            image = nil; failure = nil
            do {
                let result = try await load()
                try Task.checkCancellation()
                image = result
            } catch is CancellationError {} catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

struct EmptyPanel: View {
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String
    var action: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 42, weight: .ultraLight)).foregroundStyle(Palette.accent)
                .frame(width: 90, height: 90).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))
            Text(title).font(.system(size: 23, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            ActionButton(title: actionTitle, symbol: "plus", prominent: true, action: action).padding(.top, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}
