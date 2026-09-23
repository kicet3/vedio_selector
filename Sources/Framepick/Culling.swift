import SwiftUI
import FramepickCore

enum PhotoRejectionFilter: String, CaseIterable, Identifiable {
    case all = "제외 표시 포함", accepted = "제외 숨기기", rejected = "제외만 보기"
    var id: Self { self }
}

enum PhotoSortOrder: String, CaseIterable, Identifiable {
    case automatic = "기본 순서", name = "파일 이름순", newest = "최근 추가순", rating = "별점 높은순"
    var id: Self { self }
}

@MainActor
extension AppModel {
    var comparisonPhotos: [PhotoRecord] {
        comparisonPhotoIDs.compactMap { id in availablePhotos.first { $0.id == id } }
    }

    var hasCullingFilters: Bool { minimumRating > 0 || rejectionFilter != .all }

    func applyCulling(to photos: [PhotoRecord]) -> [PhotoRecord] {
        let filtered = photos.filter {
            max(0, min(5, $0.rating ?? 0)) >= minimumRating &&
            (rejectionFilter == .all || ($0.isRejected == true) == (rejectionFilter == .rejected))
        }
        switch photoSortOrder {
        case .automatic:
            return selectedFolderID == nil ? Array(filtered.reversed()) : filtered.sorted(by: photoNamePrecedes)
        case .name:
            return filtered.sorted(by: photoNamePrecedes)
        case .newest:
            return filtered.sorted {
                $0.addedAt == $1.addedAt ? photoNamePrecedes($0, $1) : $0.addedAt > $1.addedAt
            }
        case .rating:
            return filtered.sorted {
                let left = max(0, min(5, $0.rating ?? 0)), right = max(0, min(5, $1.rating ?? 0))
                return left == right ? photoNamePrecedes($0, $1) : left > right
            }
        }
    }

    private func photoNamePrecedes(_ left: PhotoRecord, _ right: PhotoRecord) -> Bool {
        let result = (left.relativePath ?? left.displayName).localizedStandardCompare(right.relativePath ?? right.displayName)
        return result == .orderedSame ? left.id.uuidString < right.id.uuidString : result == .orderedAscending
    }

    func setPhotoRating(_ rating: Int, ids: Set<UUID>? = nil) {
        guard libraryReady else { return }
        let targets = ids ?? selectedPhotos
        guard !targets.isEmpty else { return }
        for index in library.photos.indices where targets.contains(library.photos[index].id) {
            library.photos[index].rating = max(0, min(5, rating))
        }
        finishCullingChange()
    }

    func setPhotosRejected(_ rejected: Bool, ids: Set<UUID>? = nil) {
        guard libraryReady else { return }
        let targets = ids ?? selectedPhotos
        guard !targets.isEmpty else { return }
        for index in library.photos.indices where targets.contains(library.photos[index].id) {
            library.photos[index].isRejected = rejected
        }
        finishCullingChange()
    }

    func toggleSelectedRejection() {
        let photos = library.photos.filter { selectedPhotos.contains($0.id) }
        guard !photos.isEmpty else { return }
        setPhotosRejected(!photos.allSatisfy { $0.isRejected == true })
    }

    private func finishCullingChange() {
        // Culling only changes local library metadata, never source image bytes.
        selectedPhotos.formIntersection(Set(visiblePhotos.map(\.id)))
        reconcilePhotoFocus()
        persist()
    }

    func togglePhotoSelection(_ id: UUID) {
        if selectedPhotos.contains(id) { selectedPhotos.remove(id) } else { selectedPhotos.insert(id) }
    }

    func resetCullingFilters() { minimumRating = 0; rejectionFilter = .all }

    func startPhotoComparison() {
        let photos = visiblePhotos.filter { selectedPhotos.contains($0.id) }
        guard photos.count == 2 else { return }
        comparisonPhotoIDs = photos.map(\.id)
        focusedPhotoID = nil
    }

    func stopPhotoComparison() { comparisonPhotoIDs = [] }
}

struct PhotoRatingControl: View {
    let rating: Int
    let onChange: (Int) -> Void
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { value in
                Button { onChange(value == rating ? 0 : value) } label: {
                    Image(systemName: value <= rating ? "star.fill" : "star")
                        .font(.system(size: 11)).foregroundStyle(value <= rating ? Color.orange : Color.secondary)
                        .frame(width: 18, height: 22)
                }
                .buttonStyle(.plain)
                .help(value == rating ? "별점 해제" : "별점 \(value)개")
                .accessibilityLabel(value == rating ? "별점 해제" : "별점 \(value)개 설정")
            }
        }.accessibilityElement(children: .contain)
    }
}

struct PhotoComparisonView: View {
    @EnvironmentObject var model: AppModel
    let photos: [PhotoRecord]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: model.stopPhotoComparison) { Label("사진 목록", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Text("두 장 비교").fontWeight(.semibold)
                Spacer()
                Text("각 사진을 따로 확대해서 선명도를 확인하세요").foregroundStyle(.secondary)
            }.font(.system(size: 11)).padding(.horizontal, 16).frame(height: 44)
            HStack(spacing: 1) {
                ForEach(photos) { photo in ComparisonPhotoPanel(photo: photo) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(Palette.background)
    }
}

private struct ComparisonPhotoPanel: View {
    @EnvironmentObject var model: AppModel
    let photo: PhotoRecord
    @StateObject private var zoom = ImageZoom()
    var body: some View {
        VStack(spacing: 0) {
            ZoomableAsyncImage(identity: photo.imageIdentity, zoom: zoom) {
                try await PhotoRenderer.shared.image(url: model.disk.url(for: photo), maxPixelSize: 0)
            }
            .overlay(alignment: .topLeading) {
                Text(photo.displayName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .foregroundStyle(.white).padding(10).background(.black.opacity(0.5), in: Capsule()).padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 5) {
                ZoomControls(zoom: zoom, compact: true)
                HStack(spacing: 6) {
                    PhotoRatingControl(rating: photo.rating ?? 0) { model.setPhotoRating($0, ids: [photo.id]) }
                    Spacer(minLength: 4)
                    IconButton(symbol: photo.isFavorite ? "heart.fill" : "heart", label: "좋아요", active: photo.isFavorite) { model.toggleFavorite(photo.id) }
                    IconButton(symbol: photo.isRejected == true ? "xmark.circle.fill" : "xmark.circle", label: photo.isRejected == true ? "제외 취소" : "제외 표시", active: photo.isRejected == true) {
                        model.setPhotosRejected(photo.isRejected != true, ids: [photo.id])
                    }
                    IconButton(symbol: "slider.horizontal.3", label: "사진 편집") { model.editingPhoto = photo }
                }
            }.padding(10)
        }.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }
}
