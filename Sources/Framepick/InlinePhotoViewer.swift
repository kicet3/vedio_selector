import SwiftUI
import FramepickCore

struct InlinePhotoViewer: View {
    @EnvironmentObject var model: AppModel
    let photo: PhotoRecord
    @StateObject private var zoom = ImageZoom()
    @State private var listPage = 0
    private let pageSize = 120
    private var pageCount: Int { max(1, (model.visiblePhotos.count + pageSize - 1) / pageSize) }
    private var pagePhotos: [PhotoRecord] { Array(model.visiblePhotos.dropFirst(listPage * pageSize).prefix(pageSize)) }
    var body: some View {
        HSplitView {
            ZoomableAsyncImage(identity: photo.imageIdentity, zoom: zoom) {
                try await PhotoRenderer.shared.image(url: model.disk.url(for: photo), maxPixelSize: 0)
            }
            .overlay(alignment: .topLeading) {
                Text(photo.displayName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule()).padding(14).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    Text(notice).font(.system(size: 11)).padding(10).background(.regularMaterial, in: Capsule()).padding(14)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            photoSidebar.frame(minWidth: 244, idealWidth: 278, maxWidth: 340, maxHeight: .infinity)
        }
        .onAppear { listPage = model.focusedPhotoPosition / pageSize }
        .onChange(of: photo.id) { _, _ in listPage = model.focusedPhotoPosition / pageSize }
    }

    private var photoSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("사진 리스트").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    IconButton(symbol: "square.grid.2x2", label: "전체 사진 그리드로 돌아가기 (Esc)", action: model.showPhotoGrid)
                }
                Text(model.selectedFolder?.name ?? model.page.rawValue).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("사진 이름으로 검색", text: $model.search).textFieldStyle(.plain).font(.system(size: 11))
                }.padding(8).background(.white, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text("\(model.visiblePhotos.count)장").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if model.page != .favorites {
                        Button { model.favoritesOnly.toggle() } label: {
                            Label("좋아요만", systemImage: model.favoritesOnly ? "heart.fill" : "heart")
                                .font(.system(size: 11)).foregroundStyle(model.favoritesOnly ? Palette.rose : .secondary)
                        }.buttonStyle(.plain)
                    }
                }
                if pageCount > 1 {
                    HStack {
                        IconButton(symbol: "chevron.left", label: "이전 사진 페이지") { listPage -= 1 }.disabled(listPage == 0)
                        Spacer()
                        Text("\(listPage + 1) / \(pageCount)").font(.system(size: 10)).monospacedDigit()
                        Spacer()
                        IconButton(symbol: "chevron.right", label: "다음 사진 페이지") { listPage += 1 }.disabled(listPage + 1 >= pageCount)
                    }
                }
            }.padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 15) {
                        ForEach(pagePhotos) { photo in PhotoTile(photo: photo, inSidebar: true).id(photo.id) }
                    }.frame(maxWidth: .infinity).padding(10)
                }
                .onChange(of: photo.id) { _, id in proxy.scrollTo(id, anchor: .center) }
                .onChange(of: listPage) { _, _ in if let first = pagePhotos.first { proxy.scrollTo(first.id, anchor: .top) } }
            }
            Divider()
            VStack(spacing: 9) {
                HStack {
                    IconButton(symbol: "chevron.left", label: "이전 사진 (←)") { model.stepPhoto(-1) }.disabled(model.focusedPhotoPosition == 0)
                    Spacer()
                    Text("\(model.focusedPhotoPosition + 1) / \(model.visiblePhotos.count)").font(.system(size: 11)).monospacedDigit()
                    Spacer()
                    IconButton(symbol: "chevron.right", label: "다음 사진 (→)") { model.stepPhoto(1) }.disabled(model.focusedPhotoPosition + 1 >= model.visiblePhotos.count)
                }
                ZoomControls(zoom: zoom, compact: true)
                HStack {
                    PhotoRatingControl(rating: photo.rating ?? 0) { model.setPhotoRating($0, ids: [photo.id]) }
                    Spacer()
                    IconButton(symbol: photo.isRejected == true ? "xmark.circle.fill" : "xmark.circle", label: "제외 표시 (X)", active: photo.isRejected == true) {
                        model.setPhotosRejected(photo.isRejected != true, ids: [photo.id])
                    }
                }
                HStack {
                    Button("세로 맞춤", action: zoom.fitHeight).buttonStyle(.borderless).font(.system(size: 10))
                    Spacer()
                    IconButton(symbol: photo.isFavorite ? "heart.fill" : "heart", label: "현재 사진 좋아요 (L)", active: photo.isFavorite) { model.toggleFavorite(photo.id) }
                    ActionButton(title: "편집", symbol: "slider.horizontal.3") { model.editingPhoto = photo }
                }
                if model.selectedPhotos.count > 1 {
                    HStack {
                        Text("\(model.selectedPhotos.count)장 선택됨").font(.system(size: 10)).foregroundStyle(Palette.accent)
                        Spacer()
                        Button("선택 해제") { model.selectedPhotos.removeAll() }.buttonStyle(.plain).font(.system(size: 10))
                    }
                }
                HStack(spacing: 6) {
                    ActionButton(title: "저장", symbol: "square.and.arrow.down", action: model.exportSelection).disabled(model.isExporting || model.exportPhotos.isEmpty)
                    Spacer(minLength: 0)
                    ActionButton(title: "\(model.airDropPhotos.count)장 AirDrop", symbol: "airplayaudio", prominent: true, action: model.airDropFavorites)
                        .disabled(model.isExporting || model.airDropPhotos.isEmpty)
                }
            }.padding(12)
        }.background(Palette.background)
    }
}
