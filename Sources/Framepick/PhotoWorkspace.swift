import SwiftUI
import FramepickCore

struct PhotoWorkspace: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if model.comparisonPhotos.count == 2 { PhotoComparisonView(photos: model.comparisonPhotos) }
            else if let photo = model.focusedPhoto { InlinePhotoViewer(photo: photo) }
            else { gallery }
        }
        .onChange(of: model.search) { _, _ in model.selectedPhotos.removeAll(); model.reconcilePhotoFocus() }
        .onChange(of: model.favoritesOnly) { _, _ in model.selectedPhotos.removeAll(); model.reconcilePhotoFocus() }
        .onChange(of: model.minimumRating) { _, _ in reconcileFilters() }
        .onChange(of: model.rejectionFilter) { _, _ in reconcileFilters() }
    }
    private var gallery: some View {
        VStack(spacing: 0) {
            toolbar
            cullingToolbar
            if let folder = model.selectedFolder {
                HStack {
                    Image(systemName: "folder").foregroundStyle(Palette.accent)
                    Text(folder.path).lineLimit(1).truncationMode(.middle).help(folder.path)
                    Spacer()
                    if folder.includesSubfolders { Text("하위 폴더 포함").foregroundStyle(.tertiary) }
                    IconButton(symbol: "arrow.clockwise", label: "폴더 새로고침", action: model.refreshFolder).disabled(model.isImporting)
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 6)
            }
            if !model.folderVideos.isEmpty && !model.favoritesOnly { folderVideos }
            if model.visiblePhotos.isEmpty {
                if model.hasCullingFilters {
                    EmptyPanel(symbol: "line.3.horizontal.decrease.circle", title: "선택 조건에 맞는 사진이 없습니다", detail: "별점과 제외 표시 조건을 바꿔보세요.", actionTitle: "셀렉 필터 초기화", action: model.resetCullingFilters)
                } else if !model.search.isEmpty {
                    EmptyPanel(symbol: "magnifyingglass", title: "검색 결과가 없습니다", detail: "다른 파일 이름으로 검색해 보세요.", actionTitle: "검색 지우기") { model.search = "" }
                } else if model.page == .favorites || model.favoritesOnly {
                    EmptyPanel(symbol: "heart", title: "좋아하는 순간을 골라보세요", detail: "사진의 하트를 누르거나, 동영상에서 L 키를 눌러보세요.\n좋아요한 사진은 이곳에 모입니다.", actionTitle: "모든 사진 보기") { model.navigate(to: .photos) }
                } else {
                    EmptyPanel(symbol: "folder.badge.plus", title: model.selectedFolder == nil ? "사진이 있는 폴더를 열어보세요" : "이 폴더에는 표시할 사진이 없어요", detail: "폴더의 사진을 한눈에 보고, 좋아요로 골라보세요.\n선택한 사진은 회전·자르기·밝기 조절도 할 수 있어요.", actionTitle: "폴더 열기", action: model.chooseFolder)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: model.thumbnailSize, maximum: model.thumbnailSize + 70), spacing: 16)], spacing: 20) {
                        ForEach(model.visiblePhotos) { photo in PhotoTile(photo: photo) }
                    }.padding(24)
                }
            }
            footer
        }
    }
    private func reconcileFilters() {
        model.selectedPhotos.formIntersection(Set(model.visiblePhotos.map(\.id)))
        model.reconcilePhotoFocus()
    }
    private var cullingToolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Menu {
                    Button("모든 별점") { model.minimumRating = 0 }
                    ForEach(1...5, id: \.self) { rating in
                        Button("\(rating)★ 이상") { model.minimumRating = rating }
                    }
                } label: {
                    Label(model.minimumRating == 0 ? "모든 별점" : "\(model.minimumRating)★ 이상", systemImage: "star")
                }.menuStyle(.borderlessButton).fixedSize()
                Picker("제외 표시 필터", selection: $model.rejectionFilter) {
                    ForEach(PhotoRejectionFilter.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 128)
                Picker("정렬", selection: $model.photoSortOrder) {
                    ForEach(PhotoSortOrder.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 118)
                Spacer(minLength: 4)
                Menu {
                    Menu("별점 지정") {
                        Button("별점 해제") { model.setPhotoRating(0) }
                        ForEach(1...5, id: \.self) { rating in
                            Button(String(repeating: "★", count: rating)) { model.setPhotoRating(rating) }
                        }
                    }
                    Button("제외 표시") { model.setPhotosRejected(true) }
                    Button("제외 취소") { model.setPhotosRejected(false) }
                    Divider()
                    Button("복사한 보정 적용", action: model.batchApplyCopiedAdjustments)
                        .disabled(model.copiedAdjustments == nil || model.isBatchEditing)
                } label: { Label("선택 사진 작업", systemImage: "checklist") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(model.selectedPhotos.isEmpty)
                Button(action: model.startPhotoComparison) { Label("두 장 비교", systemImage: "rectangle.split.2x1") }
                    .buttonStyle(.borderless).disabled(model.selectedPhotos.count != 2)
                    .help("사진 왼쪽 위 선택 버튼으로 두 장을 고르세요. ⌘ 또는 ⇧ 클릭으로도 선택할 수 있습니다.")
            }
            if model.isBatchEditing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.batchProgress).lineLimit(1)
                    Spacer()
                    Button("중단", action: model.cancelBatchEdits).buttonStyle(.borderless)
                }
            }
        }.font(.system(size: 11)).padding(.horizontal, 24).padding(.bottom, 12)
    }
    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("사진 이름으로 검색", text: $model.search).textFieldStyle(.plain).font(.system(size: 11))
            }.padding(9).frame(width: 200).background(.white, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.08)))
            Spacer(minLength: 0)
            if model.page != .favorites {
                Button { model.favoritesOnly.toggle() } label: {
                    Label("좋아요만", systemImage: model.favoritesOnly ? "heart.fill" : "heart")
                        .font(.system(size: 11)).foregroundStyle(model.favoritesOnly ? Palette.rose : .secondary)
                }.buttonStyle(.plain)
            }
            IconButton(symbol: "slider.horizontal.3", label: "선택한 사진 편집", action: model.editSelection).disabled(model.selectedPhotos.count != 1)
            if !model.selectedPhotos.isEmpty {
                IconButton(symbol: "heart", label: "선택한 사진 좋아요 변경", action: model.toggleSelectedFavorites)
            }
            ActionButton(title: "폴더에 저장", symbol: "square.and.arrow.down", action: model.exportSelection)
                .disabled(model.exportPhotos.isEmpty || model.isExporting)
            ActionButton(title: "\(model.airDropPhotos.count)장 AirDrop", symbol: "airplayaudio", prominent: true, action: model.airDropFavorites)
                .disabled(model.airDropPhotos.isEmpty || model.isExporting)
                .help("좋아요한 사진을 AirDrop으로 보냅니다. 여러 장을 선택하면 그중 좋아요한 사진만 보냅니다.")
        }.padding(.horizontal, 24).padding(.vertical, 17)
    }
    private var folderVideos: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(model.folderVideos) { video in
                    Button { model.openVideo(video) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(video.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text("동영상 프레임 열기").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }.padding(12).frame(width: 200, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 24).padding(.vertical, 8)
        }.scrollIndicators(.hidden).frame(height: 76)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(model.visiblePhotos.count)장의 사진").fontWeight(.medium)
            if !model.selectedPhotos.isEmpty {
                Text("\(model.selectedPhotos.count)장 선택됨").foregroundStyle(Palette.accent)
                Button("선택 해제") { model.selectedPhotos.removeAll() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            Button("모두 선택", action: model.selectAllPhotos).buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.visiblePhotos.isEmpty)
            Image(systemName: "square.grid.3x3").foregroundStyle(.secondary).padding(.leading, 10)
            Slider(value: $model.thumbnailSize, in: 140...280).frame(width: 90).accessibilityLabel("사진 크기")
            if model.isExporting { ProgressView().controlSize(.small) }
        }.font(.system(size: 11)).padding(.horizontal, 24).frame(height: 44)
    }
}

struct PhotoTile: View {
    @EnvironmentObject var model: AppModel
    let photo: PhotoRecord
    var inSidebar = false
    private var selected: Bool { model.selectedPhotos.contains(photo.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                Palette.canvas
                AsyncMediaImage(identity: photo.imageIdentity, quiet: true) {
                    try await PhotoRenderer.shared.image(url: model.disk.url(for: photo), maxPixelSize: 640)
                }
                Button { model.toggleFavorite(photo.id) } label: {
                    Image(systemName: photo.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(photo.isFavorite ? Palette.rose : .white)
                        .frame(width: 31, height: 31).background(.black.opacity(0.45), in: Circle())
                }.buttonStyle(.plain).help(photo.isFavorite ? "좋아요 취소" : "좋아요").accessibilityLabel("\(photo.displayName) \(photo.isFavorite ? "좋아요 취소" : "좋아요")").padding(9)
            }.frame(height: inSidebar ? 140 : model.thumbnailSize * 0.73).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Palette.accent : .black.opacity(0.05), lineWidth: selected ? 3 : 1))
                .overlay(alignment: .topLeading) {
                    Button { model.togglePhotoSelection(photo.id) } label: {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 31, height: 31).background(selected ? Palette.accent : .black.opacity(0.45), in: Circle())
                    }.buttonStyle(.plain).padding(9).help(selected ? "선택 해제" : "사진 선택")
                        .accessibilityLabel("\(photo.displayName) \(selected ? "선택 해제" : "선택")")
                }
                .overlay(alignment: .bottomTrailing) {
                    if photo.isRejected == true {
                        Label("제외", systemImage: "xmark.circle.fill").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 5)
                            .background(.black.opacity(0.65), in: Capsule()).padding(8).allowsHitTesting(false)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(photo.displayName).font(.system(size: 11, weight: .medium)).lineLimit(1).foregroundStyle(Palette.ink)
                HStack(spacing: 4) {
                    Image(systemName: photo.videoID == nil ? "photo" : "film")
                    Text(photo.editedFromID != nil ? "편집한 복사본" : photo.timestamp?.label ?? photo.relativePath ?? "가져온 사진").lineLimit(1)
                    Spacer()
                    Text(URL(fileURLWithPath: photo.filename).pathExtension.uppercased())
                }.font(.system(size: 9)).foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    PhotoRatingControl(rating: photo.rating ?? 0) { model.setPhotoRating($0, ids: [photo.id]) }
                    Spacer(minLength: 0)
                    Button { model.setPhotosRejected(photo.isRejected != true, ids: [photo.id]) } label: {
                        Image(systemName: photo.isRejected == true ? "xmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(photo.isRejected == true ? Palette.rose : .secondary)
                    }.buttonStyle(.plain).help(photo.isRejected == true ? "제외 취소" : "제외 표시 (파일은 삭제되지 않습니다)")
                }
            }.padding(.horizontal, 2)
        }.contentShape(Rectangle())
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) { model.togglePhotoSelection(photo.id) }
                else { model.selectPhoto(photo.id, extending: false) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("크게 보기")) { model.selectPhoto(photo.id, extending: false) }
            .contextMenu {
                Button("크게 보기") { model.selectPhoto(photo.id, extending: false) }
                Button("사진 편집") { model.editingPhoto = photo }
                Button(photo.isFavorite ? "좋아요 취소" : "좋아요") { model.toggleFavorite(photo.id) }
                Menu("별점") {
                    Button("별점 해제") { model.setPhotoRating(0, ids: [photo.id]) }
                    ForEach(1...5, id: \.self) { rating in
                        Button(String(repeating: "★", count: rating)) { model.setPhotoRating(rating, ids: [photo.id]) }
                    }
                }
                Button(photo.isRejected == true ? "제외 취소" : "제외 표시") { model.setPhotosRejected(photo.isRejected != true, ids: [photo.id]) }
                Divider()
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([model.disk.url(for: photo)]) }
            }
    }
}
