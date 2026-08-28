//
//  ChatMediaViewer.swift
//  Voiid
//
//  Full-screen media browsing inside a conversation — one UIKit controller, top to bottom.
//
//  ── WHY THIS IS NOT SwiftUI ─────────────────────────────────────────────────────
//  The first version was SwiftUI: a `TabView(.page)` whose pages each wrapped a zoomable
//  `UIScrollView`. It failed in three separate ways and each was a symptom of the same
//  mistake — layering SwiftUI over UIKit over SwiftUI:
//
//   * The TabView's selection is SwiftUI STATE, so every page change re-evaluated the view
//     tree. Any page reading that state got rebuilt mid-animation, and the selection
//     oscillated (measured: eight flips in four seconds) — on screen, a swipe that sticks.
//   * A TabView and a nested UIScrollView are TWO gesture systems arbitrating for one
//     horizontal drag, resolved by priority rather than intent.
//   * A `UIHostingController` sizes to its content's IDEAL size, and an image that has not
//     loaded has none — so pages collapsed to zero and rendered blank.
//
//  Apple's Photos is a single UIKit hierarchy: a paging scroll view whose pages are
//  themselves zoomable scroll views. UIKit already knows a pinch belongs to the page and a
//  horizontal drag to the pager, and paging is not a published state change at all. There
//  is nothing to lose across a boundary because there is no boundary.
//
//  SwiftUI's only job here is presenting this controller.
//

import SwiftUI
import UIKit
import AVKit

// MARK: - SwiftUI entry point

struct ChatMediaViewer: UIViewControllerRepresentable {
    let chatId: String
    let startMessageId: String
    var onJumpToMessage: (String) -> Void = { _ in }

    @EnvironmentObject private var chat: ChatStore
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MediaViewerController {
        let items = ChatMediaStore.items(chatId: chatId, from: chat)
        let vc = MediaViewerController(items: items, startId: startMessageId)
        vc.onClose = { dismiss() }
        vc.onJump = { id in dismiss(); onJumpToMessage(id) }
        return vc
    }

    func updateUIViewController(_ vc: MediaViewerController, context: Context) {}
}

// MARK: - The viewer

final class MediaViewerController: UIViewController {

    private let items: [ChatMediaItem]
    private var index: Int

    var onClose: () -> Void = {}
    var onJump: (String) -> Void = { _ in }

    /// THE pager. One horizontally-paging scroll view holding every page side by side —
    /// the same shape Photos uses, and the reason the gesture handoff is native.
    private let pager = UIScrollView()
    private var pages: [MediaPageView] = []
    private var chromeVisible = true

    private let topBar = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    /// The filmstrip: every photo and video in the chat, in the same chronological order as
    /// the pager. A collection view rather than a scroll view of tiles, so cells are reused
    /// and a chat with a thousand photos costs the same as one with ten.
    private var strip: UICollectionView!
    private static let thumbSide: CGFloat = 50
    private static let stripHeight: CGFloat = 74

    init(items: [ChatMediaItem], startId: String) {
        self.items = items
        self.index = items.firstIndex { $0.id == startId } ?? max(0, items.count - 1)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.showsVerticalScrollIndicator = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        pager.backgroundColor = .black
        view.addSubview(pager)

        for (i, item) in items.enumerated() {
            // Only the opened page pays the synchronous cache read — see MediaPageView.init.
            let page = MediaPageView(item: item, eager: i == index)
            page.onSingleTap = { [weak self] in self?.toggleChrome() }
            pager.addSubview(page)
            pages.append(page)
        }

        buildChrome()
        buildStrip()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // EVERY frame is set here, against real bounds. This is the one place that always
        // has them — which is exactly what the SwiftUI version could not guarantee.
        let size = view.bounds.size
        pager.frame = view.bounds
        for (i, page) in pages.enumerated() {
            page.frame = CGRect(x: CGFloat(i) * size.width, y: 0,
                                width: size.width, height: size.height)
        }
        pager.contentSize = CGSize(width: size.width * CGFloat(pages.count), height: size.height)
        // Only reposition when not mid-drag, or this fights the user's own scroll.
        if !pager.isDragging && !pager.isDecelerating {
            pager.contentOffset = CGPoint(x: CGFloat(index) * size.width, y: 0)
        }
        layoutChrome()
        layoutStrip()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pages.indices.contains(index) ? pages[index].load() : ()
        preload(around: index)
        updateChromeText()
        highlightStrip(animated: false)
    }

    override var prefersStatusBarHidden: Bool { !chromeVisible }

    // MARK: Chrome

    private func buildChrome() {
        topBar.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        view.addSubview(topBar)

        let back = UIButton(type: .system)
        back.setImage(UIImage(systemName: "chevron.left",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 17,
                                                                             weight: .semibold)),
                      for: .normal)
        back.tintColor = .white
        back.addAction(UIAction { [weak self] _ in self?.onClose() }, for: .touchUpInside)
        back.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(back)

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.75)

        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(stack)

        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            back.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -10),
            back.widthAnchor.constraint(equalToConstant: 44),
            back.heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 4),
            stack.centerYAnchor.constraint(equalTo: back.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: topBar.trailingAnchor, constant: -16),
        ])
    }

    private func layoutChrome() {
        let top = view.safeAreaInsets.top
        topBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: top + 54)
    }

    private func updateChromeText() {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        titleLabel.text = item.displayName
        subtitleLabel.text = VoiidDate.relative(item.sentAt)
    }

    private func toggleChrome() {
        chromeVisible.toggle()
        UIView.animate(withDuration: 0.2) {
            self.topBar.alpha = self.chromeVisible ? 1 : 0
            self.strip.alpha = self.chromeVisible ? 1 : 0
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }

    private func buildStrip() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: Self.thumbSide, height: Self.thumbSide)
        layout.minimumLineSpacing = 6

        strip = UICollectionView(frame: .zero, collectionViewLayout: layout)
        strip.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        strip.showsHorizontalScrollIndicator = false
        strip.dataSource = self
        strip.delegate = self
        strip.register(ThumbCell.self, forCellWithReuseIdentifier: "thumb")
        // The strip is pointless with one item — a single thumbnail of the photo already
        // filling the screen.
        strip.isHidden = items.count < 2
        view.addSubview(strip)
    }

    private func layoutStrip() {
        let bottom = view.safeAreaInsets.bottom
        let height = Self.stripHeight + bottom
        strip.frame = CGRect(x: 0, y: view.bounds.height - height,
                             width: view.bounds.width, height: height)
        // Half a screen either side, so the FIRST and LAST thumbnails can sit centred like
        // every other one rather than jamming against the edge.
        let sideInset = max(0, (view.bounds.width - Self.thumbSide) / 2)
        strip.contentInset = UIEdgeInsets(top: 12, left: sideInset,
                                          bottom: 12 + bottom, right: sideInset)
    }

    /// Centre the current thumbnail and refresh which one reads as active.
    private func highlightStrip(animated: Bool) {
        guard !strip.isHidden, items.indices.contains(index) else { return }
        strip.selectItem(at: IndexPath(item: index, section: 0), animated: animated,
                         scrollPosition: .centeredHorizontally)
        // `selectItem` moves the strip but does not redraw the cells, so the previously
        // active one would keep its ring.
        strip.visibleCells.compactMap { $0 as? ThumbCell }.forEach { cell in
            if let path = strip.indexPath(for: cell) {
                cell.setActive(path.item == index, animated: animated)
            }
        }
    }

    /// Decode the neighbours so a swipe lands on a photo rather than a spinner — but only
    /// the neighbours, so a long chat never decodes everything.
    private func preload(around i: Int) {
        // ±2, not ±1: a fast swipe can cross two pages before the previous one settles, and
        // a cached read costs a dictionary lookup or one small disk read. The bound still
        // matters — this is what stops a chat with 500 photos decoding all of them.
        for j in (i - 2)...(i + 2) where pages.indices.contains(j) {
            pages[j].load()
        }
    }
}

// MARK: - Filmstrip data

extension MediaViewerController: UICollectionViewDataSource, UICollectionViewDelegate {

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ cv: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "thumb", for: indexPath) as! ThumbCell
        cell.configure(with: items[indexPath.item])
        cell.setActive(indexPath.item == index, animated: false)
        return cell
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item != index else { return }
        index = indexPath.item
        // Not animated: a strip tap can jump a long way, and animating a hundred pages past
        // the user is slower and less legible than simply arriving.
        pager.setContentOffset(CGPoint(x: CGFloat(index) * view.bounds.width, y: 0),
                               animated: false)
        updateChromeText()
        preload(around: index)
        highlightStrip(animated: true)
    }
}

extension MediaViewerController: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // The strip is a scroll view too and shares this delegate — only the PAGER's
        // settling should change the page.
        guard scrollView === pager else { return }
        guard view.bounds.width > 0 else { return }
        let page = Int((scrollView.contentOffset.x / view.bounds.width).rounded())
        guard page != index, pages.indices.contains(page) else { return }
        index = page
        updateChromeText()
        preload(around: page)
        highlightStrip(animated: true)
    }
}

// MARK: - One page

/// A zoomable page. A scroll view whose only subview is the image — the standard shape, and
/// the reason the pager gets the drag at rest: a nested scroll view with nowhere to scroll
/// yields to its parent, which UIKit handles natively.
final class MediaPageView: UIScrollView {

    private let item: ChatMediaItem
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    /// Set in `init` when the cache answers, so `load()` knows there is nothing to fetch.
    private var loaded = false

    var onSingleTap: () -> Void = {}

    /// `eager` — read the cache synchronously during init.
    ///
    /// True only for the page being opened. That single read is what makes an
    /// already-decoded photo appear on the FIRST frame instead of after a spinner. Doing it
    /// for every page would move the same cost to launch: a chat with fifty photos would do
    /// fifty disk reads before anything is drawn.
    init(item: ChatMediaItem, eager: Bool = false) {
        self.item = item
        super.init(frame: .zero)

        minimumZoomScale = 1
        maximumZoomScale = 4
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        delegate = self
        bouncesZoom = true
        // At rest there is nothing to pan, so the drag belongs to the pager above.
        panGestureRecognizer.isEnabled = false

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        spinner.color = .white
        addSubview(spinner)

        // ── CACHED BYTES ARE SHOWN SYNCHRONOUSLY, DURING INIT ────────────────────
        //
        // The chat bubble already decoded this image, so `MediaCache` holds it in memory or
        // on disk. Waiting for `viewDidAppear` to call `load()` meant the viewer opened, put
        // up a spinner, and only THEN looked in a cache that could answer instantly — a
        // visible flash of loading for a photo the app already had.
        //
        // `MediaCache.image` reads memory, then disk, so this covers a cold launch too.
        // Only a genuine miss falls through to the async path and the spinner.
        if eager, let cached = MediaCache.shared.image(item.ref.mediaUrl) {
            imageView.image = cached
            loaded = true
        } else {
            spinner.startAnimating()
        }

        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)

        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        single.require(toFail: double)
        addGestureRecognizer(single)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Only while at rest: resizing a zoomed image would throw the user's zoom away on
        // every layout pass.
        if zoomScale <= 1.01 {
            imageView.frame = bounds
            contentSize = bounds.size
            contentInset = .zero
        }
    }

    /// Idempotent — the pager calls this for the current page and its neighbours, and a page
    /// may be a neighbour more than once.
    func load() {
        guard !loaded else { return }

        // THE CACHE FIRST, SYNCHRONOUSLY — for every page, not just the opened one.
        //
        // The cache check used to live here, and when the eager path was added to `init` it
        // was removed from this function entirely. That left NEIGHBOURS with no cache read
        // at all: every image except the one you opened went to the network, even though
        // the chat bubble had already decoded it to disk. That is why the first photo
        // appeared instantly and the rest did not.
        //
        // `MediaCache.image` reads memory then disk, so this is the same fast path the
        // opened page takes — it simply has to apply to all of them.
        if let cached = MediaCache.shared.image(item.ref.mediaUrl) {
            loaded = true
            show(cached)
            return
        }

        loaded = true
        Task { @MainActor in
            guard let data = try? await ChatEngine.shared.fetchMedia(item.ref),
                  let image = UIImage(data: data) else {
                loaded = false          // let a later swipe retry
                spinner.stopAnimating()
                return
            }
            MediaCache.shared.setData(data, item.ref.mediaUrl)
            MediaCache.shared.set(image, item.ref.mediaUrl)
            show(image)
        }
    }

    private func show(_ image: UIImage) {
        imageView.image = image
        spinner.stopAnimating()
        setNeedsLayout()
    }

    @objc private func handleSingleTap() { onSingleTap() }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            // Zoom TO THE TAP: double-tapping a face should bring that face closer, which is
            // the whole reason to tap a particular spot.
            let point = g.location(in: imageView)
            let side = bounds.width / 2.5
            zoom(to: CGRect(x: point.x - side / 2, y: point.y - side / 2,
                            width: side, height: side), animated: true)
        }
    }
}

extension MediaPageView: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // The pan follows the zoom: enabled only when there is somewhere to pan to, which is
        // what hands the drag back to the pager at rest.
        panGestureRecognizer.isEnabled = zoomScale > 1.01
        // Keep the image centred while it is smaller than the viewport.
        let x = max(0, (bounds.width - imageView.frame.width) / 2)
        let y = max(0, (bounds.height - imageView.frame.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }
}


// MARK: - A filmstrip cell

private final class ThumbCell: UICollectionViewCell {

    private let imageView = UIImageView()
    private let ring = CALayer()
    private let videoMark = UILabel()
    /// The outgoing accent underline — the ONLY sender distinction in the strip. Anything
    /// more would start grouping a stream that is deliberately one chronological run.
    private let outgoingBar = UIView()
    private var itemId: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = 6
        contentView.backgroundColor = UIColor.white.withAlphaComponent(0.12)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)

        videoMark.font = .systemFont(ofSize: 8, weight: .semibold)
        videoMark.textColor = .white
        videoMark.layer.shadowOpacity = 0.6
        videoMark.layer.shadowRadius = 2
        videoMark.layer.shadowOffset = .zero
        contentView.addSubview(videoMark)

        outgoingBar.backgroundColor = UIColor(VoiidColor.accent)
        contentView.addSubview(outgoingBar)

        contentView.layer.borderColor = UIColor.white.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
        outgoingBar.frame = CGRect(x: 0, y: contentView.bounds.height - 2,
                                   width: contentView.bounds.width, height: 2)
        videoMark.sizeToFit()
        videoMark.frame.origin = CGPoint(x: contentView.bounds.width - videoMark.bounds.width - 3,
                                         y: contentView.bounds.height - videoMark.bounds.height - 3)
    }

    func configure(with item: ChatMediaItem) {
        itemId = item.id
        imageView.image = nil
        videoMark.text = item.type == .video ? (item.durationLabel ?? "▶") : nil
        videoMark.isHidden = item.type != .video
        outgoingBar.isHidden = !item.isOutgoing

        Task { @MainActor in
            let image = await ChatMediaThumbnails.shared.thumbnail(for: item, side: 50)
            // The cell may have been reused for a different item while the decode ran.
            guard itemId == item.id else { return }
            imageView.image = image
        }
    }

    func setActive(_ active: Bool, animated: Bool) {
        let apply = {
            self.contentView.layer.borderWidth = active ? 2 : 0
            self.transform = active ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
        }
        animated ? UIView.animate(withDuration: 0.2, animations: apply) : apply()
    }
}
