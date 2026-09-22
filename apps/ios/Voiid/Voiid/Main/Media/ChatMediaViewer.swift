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
import Photos
import UniformTypeIdentifiers

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

    func updateUIViewController(_ vc: MediaViewerController, context: Context) {
        vc.updateItems(ChatMediaStore.items(chatId: chatId, from: chat))
    }

    static func dismantleUIViewController(_ vc: MediaViewerController, coordinator: ()) {
        vc.shutdown()
    }
}

// MARK: - The viewer

final class MediaViewerController: UIViewController, UIGestureRecognizerDelegate {

    private var items: [ChatMediaItem]
    private var index: Int

    var onClose: () -> Void = {}
    var onJump: (String) -> Void = { _ in }

    /// THE pager. One horizontally-paging scroll view holding every page side by side —
    /// the same shape Photos uses, and the reason the gesture handoff is native.
    private let pager = UIScrollView()
    private var pages: [MediaPageView] = []
    private var chromeVisible = true

    private let topBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let footer = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let captionLabel = UILabel()
    private let countLabel = UILabel()
    private let actions = UIStackView()
    private var actionButtons: [UIButton] = []
    private var exporting = false
    private var backgroundObserver: NSObjectProtocol?
    private var emptyLabel: UILabel?
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    /// The filmstrip: every photo and video in the chat, in the same chronological order as
    /// the pager. A collection view rather than a scroll view of tiles, so cells are reused
    /// and a chat with a thousand photos costs the same as one with ten.
    private var strip: UICollectionView!
    private static let thumbSide: CGFloat = 48
    private static let stripHeight: CGFloat = 66

    init(items: [ChatMediaItem], startId: String) {
        self.items = items
        self.index = items.firstIndex { $0.id == startId } ?? max(0, items.count - 1)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(VoiidColor.background)
        view.tintColor = UIColor(VoiidColor.accentInk)

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.showsVerticalScrollIndicator = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        pager.backgroundColor = .black
        view.addSubview(pager)
        let dismissPan = UIPanGestureRecognizer(target: self, action: #selector(dragToClose(_:)))
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.delegate = self
        pager.addGestureRecognizer(dismissPan)
        pager.panGestureRecognizer.require(toFail: dismissPan)

        buildPages()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pages.forEach { $0.pause() } }
        }

        buildChrome()
        buildStrip()
        updateChromeText()
        if items.isEmpty {
            let empty = UILabel()
            empty.text = "No media available"
            empty.textColor = UIColor(VoiidColor.textPrimary)
            empty.font = .voiidRounded(ofSize: 17)
            empty.textAlignment = .center
            empty.frame = view.bounds
            empty.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pager.addSubview(empty)
            emptyLabel = empty
            actionButtons.forEach { $0.isEnabled = false }
        }
        // UIKit scroll views do not inherit the SwiftUI app's scroll-edge style.
        if #available(iOS 26.0, *) {
            pager.topEdgeEffect.style = .soft
            strip.topEdgeEffect.style = .soft
            for page in pages {
                page.topEdgeEffect.style = .soft
            }
        }
    }

    private func buildPages() {
        for (i, item) in items.enumerated() {
            // Only the opened page pays the synchronous cache read — see MediaPageView.init.
            let page = MediaPageView(item: item, eager: i == index)
            page.onSingleTap = { [weak self] in self?.toggleChrome() }
            pager.addSubview(page)
            if let player = page.playerController {
                addChild(player)
                page.installPlayer()
                player.didMove(toParent: self)
            }
            pages.append(page)
        }

    }

    func shutdown() {
        pages.forEach { $0.unload() }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
    }

    func updateItems(_ updated: [ChatMediaItem]) {
        guard items != updated else { return }
        let selectedID = items.indices.contains(index) ? items[index].id : nil
        items = updated
        index = selectedID.flatMap { id in updated.firstIndex { $0.id == id } } ?? max(0, min(index, updated.count - 1))
        guard isViewLoaded else { return }
        for page in pages {
            page.unload()
            page.playerController?.willMove(toParent: nil)
            page.removeFromSuperview()
            page.playerController?.removeFromParent()
        }
        pages.removeAll()
        emptyLabel?.removeFromSuperview()
        emptyLabel = nil
        guard !items.isEmpty else { onClose(); return }
        buildPages()
        strip.reloadData()
        updateChromeText()
        view.setNeedsLayout()
        preload(around: index)
        highlightStrip(animated: false)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              pages.indices.contains(index), pages[index].zoomScale <= 1.01 else { return false }
        let velocity = pan.velocity(in: view)
        return velocity.y > 0 && velocity.y > abs(velocity.x) * 1.2
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target: UIView? = touch.view
        while let current = target {
            if current is UIControl { return false }
            target = current.superview
        }
        return true
    }

    @objc private func dragToClose(_ gesture: UIPanGestureRecognizer) {
        let distance = max(0, gesture.translation(in: view).y)
        let progress = min(1, distance / max(1, view.bounds.height * 0.45))
        switch gesture.state {
        case .changed:
            pager.transform = CGAffineTransform(translationX: 0, y: distance)
            topBar.alpha = (chromeVisible ? 1 : 0) * (1 - progress)
            footer.alpha = (chromeVisible ? 1 : 0) * (1 - progress)
        case .ended, .cancelled, .failed:
            if gesture.state == .ended && (distance > 120 || (distance > 24 && gesture.velocity(in: view).y > 850)) {
                onClose()
            } else {
                UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.25,
                               delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                    self.pager.transform = .identity
                    self.topBar.alpha = self.chromeVisible ? 1 : 0
                    self.footer.alpha = self.chromeVisible ? 1 : 0
                }
            }
        default: break
        }
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
        for page in pages {
            page.mediaInsets = chromeVisible
                ? UIEdgeInsets(top: topBar.frame.maxY + 8, left: 0,
                               bottom: view.bounds.height - footer.frame.minY + 8, right: 0)
                : .zero
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pages.indices.contains(index) ? pages[index].load() : ()
        preload(around: index)
        updateChromeText()
        highlightStrip(animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pages.forEach { $0.pause() }
    }

    override func accessibilityPerformEscape() -> Bool {
        onClose()
        return true
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .default }
    override var prefersStatusBarHidden: Bool { !chromeVisible }

    // MARK: Chrome

    private func buildChrome() {
        for panel in [topBar, footer] {
            panel.layer.cornerRadius = 22
            panel.clipsToBounds = true
            if UIAccessibility.isReduceTransparencyEnabled {
                panel.effect = nil
                panel.backgroundColor = UIColor(VoiidColor.surfaceCard)
            }
            view.addSubview(panel)
        }
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = UIColor(VoiidColor.textPrimary)
        close.accessibilityLabel = "Close gallery"
        close.addAction(UIAction { [weak self] _ in self?.onClose() }, for: .touchUpInside)
        close.frame = CGRect(x: 4, y: 10, width: 44, height: 44)
        topBar.contentView.addSubview(close)

        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .voiidRounded(ofSize: 16, weight: .semibold), maximumPointSize: 22)
        subtitleLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .voiidRounded(ofSize: 12), maximumPointSize: 16)
        titleLabel.textColor = UIColor(VoiidColor.textPrimary)
        subtitleLabel.textColor = UIColor(VoiidColor.textSecondary)
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(stack)
        countLabel.font = .voiidRounded(ofSize: 12, weight: .medium)
        countLabel.textColor = UIColor(VoiidColor.textSecondary)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        topBar.contentView.addSubview(countLabel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: topBar.contentView.leadingAnchor, constant: 52),
            stack.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -12),
            countLabel.trailingAnchor.constraint(equalTo: topBar.contentView.trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
        ])
        captionLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .voiidRounded(ofSize: 14), maximumPointSize: 22)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = UIColor(VoiidColor.textPrimary)
        captionLabel.numberOfLines = 2
        captionLabel.isUserInteractionEnabled = true
        captionLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showCaption)))
        captionLabel.accessibilityTraits = .button
        captionLabel.accessibilityHint = "Show full caption"
        footer.contentView.addSubview(captionLabel)
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        footer.contentView.addSubview(actions)
        for (title, symbol, handler) in [
            ("Share", "square.and.arrow.up", { [weak self] in self?.export(save: false) }),
            ("Save", "arrow.down.to.line", { [weak self] in self?.export(save: true) }),
            ("Show in chat", "bubble.left", { [weak self] in self?.jumpToCurrent() })
        ] {
            var configuration = UIButton.Configuration.plain()
            configuration.title = title
            configuration.image = UIImage(systemName: symbol)
            configuration.imagePlacement = .top
            configuration.imagePadding = 5
            configuration.baseForegroundColor = UIColor(VoiidColor.textPrimary)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes
                result.font = UIFont.voiidRounded(ofSize: 11, weight: .medium)
                return result
            }
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in handler() })
            button.accessibilityLabel = title
            actions.addArrangedSubview(button)
            actionButtons.append(button)
        }
    }

    private func layoutChrome() {
        let insets = view.safeAreaInsets
        let width = min(600, view.bounds.width - insets.left - insets.right - 24)
        topBar.frame = CGRect(x: (view.bounds.width - width) / 2, y: insets.top + 6, width: width, height: 64)
        let compact = view.bounds.height < 500
        strip?.isHidden = items.count < 2 || compact
        let captionHeight: CGFloat = !compact && captionLabel.text?.isEmpty == false
            ? min(64, captionLabel.sizeThatFits(CGSize(width: width - 32, height: 80)).height) + 16 : 0
        let stripHeight: CGFloat = items.count > 1 && !compact ? Self.stripHeight : 0
        let height = captionHeight + stripHeight + 62
        footer.frame = CGRect(x: (view.bounds.width - width) / 2,
                              y: view.bounds.height - insets.bottom - height - 8, width: width, height: height)
        captionLabel.frame = CGRect(x: 16, y: 8, width: width - 32, height: max(0, captionHeight - 16))
        captionLabel.isHidden = captionHeight == 0
        actions.frame = CGRect(x: 8, y: height - 62, width: width - 16, height: 56)
    }

    private func updateChromeText() {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        titleLabel.text = item.displayName
        subtitleLabel.text = item.sentAt.formatted(date: .abbreviated, time: .shortened)
        countLabel.text = "\(index + 1) of \(items.count)"
        captionLabel.text = item.caption
        pages.enumerated().forEach { if $0.offset != index { $0.element.pause() } }
        view.setNeedsLayout()
    }

    @objc private func showCaption() {
        guard let caption = items.indices.contains(index) ? items[index].caption : nil else { return }
        showNotice("Caption", caption)
    }

    private func jumpToCurrent() {
        guard items.indices.contains(index) else { return }
        onJump(items[index].id)
    }

    private func showNotice(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func export(save: Bool) {
        guard !exporting, items.indices.contains(index) else { return }
        let item = items[index]
        let account = TokenStore.shared.userId
        exporting = true
        actionButtons.forEach { $0.isEnabled = false }
        let button = actionButtons[save ? 1 : 0]
        button.configuration?.showsActivityIndicator = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.exporting = false
                self.actionButtons.forEach { $0.isEnabled = true }
                button.configuration?.showsActivityIndicator = false
            }
            do {
                let data: Data
                if let cached = MediaCache.shared.data(item.ref.mediaUrl) { data = cached }
                else { data = try await ChatEngine.shared.fetchMedia(item.ref) }
                guard account == TokenStore.shared.userId, self.view.window != nil else { return }
                MediaCache.shared.setData(data, item.ref.mediaUrl)
                guard let base = MediaCache.shared.fileURL(item.ref.mediaUrl) else { throw CocoaError(.fileWriteUnknown) }
                let ext = UTType(mimeType: item.ref.mime)?.preferredFilenameExtension ?? (item.type == .video ? "mp4" : "jpg")
                let url = base.appendingPathExtension(ext)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                if save {
                    let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    guard account == TokenStore.shared.userId, self.view.window != nil else { return }
                    guard permission == .authorized || permission == .limited else {
                        self.showNotice("Photo access needed", "Allow Voiid to add photos in Settings, or use Share to save this file elsewhere.")
                        return
                    }
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: item.type == .video ? .video : .photo, fileURL: url, options: nil)
                    }
                    guard account == TokenStore.shared.userId, self.view.window != nil else { return }
                    self.showNotice("Saved", "Added to your photo library.")
                } else {
                    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    sheet.popoverPresentationController?.sourceView = button
                    sheet.popoverPresentationController?.sourceRect = button.bounds
                    self.present(sheet, animated: true)
                }
            } catch {
                guard account == TokenStore.shared.userId, self.view.window != nil else { return }
                self.showNotice(save ? "Couldn’t save media" : "Couldn’t share media", "Please try again. Check your connection if this item hasn’t downloaded yet.")
            }
        }
    }

    private func toggleChrome() {
        chromeVisible.toggle()
        topBar.accessibilityElementsHidden = !chromeVisible
        footer.accessibilityElementsHidden = !chromeVisible
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) {
            self.topBar.alpha = self.chromeVisible ? 1 : 0
            self.footer.alpha = self.chromeVisible ? 1 : 0
            self.setNeedsStatusBarAppearanceUpdate()
            self.view.setNeedsLayout()
        }
    }

    private func buildStrip() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: Self.thumbSide, height: Self.thumbSide)
        layout.minimumLineSpacing = 6

        strip = UICollectionView(frame: .zero, collectionViewLayout: layout)
        strip.backgroundColor = .clear
        strip.showsHorizontalScrollIndicator = false
        strip.dataSource = self
        strip.delegate = self
        strip.register(ThumbCell.self, forCellWithReuseIdentifier: "thumb")
        // The strip is pointless with one item — a single thumbnail of the photo already
        // filling the screen.
        strip.isHidden = items.count < 2
        footer.contentView.addSubview(strip)
    }

    private func layoutStrip() {
        let captionHeight = captionLabel.isHidden ? 0 : captionLabel.frame.maxY + 8
        strip.frame = CGRect(x: 0, y: captionHeight, width: footer.bounds.width, height: Self.stripHeight)
        let sideInset = max(0, (footer.bounds.width - Self.thumbSide) / 2)
        strip.contentInset = UIEdgeInsets(top: 9, left: sideInset, bottom: 9, right: sideInset)
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
        for (j, page) in pages.enumerated() {
            if abs(j - i) <= 2 { page.load() }
            else { page.unload() }
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
    private var loadTask: Task<Void, Never>?
    private let retryButton = UIButton(type: .system)
    let playerController: AVPlayerViewController?
    var mediaInsets: UIEdgeInsets = .zero {
        didSet { if oldValue != mediaInsets { setNeedsLayout() } }
    }

    var onSingleTap: () -> Void = {}

    /// `eager` — read the cache synchronously during init.
    ///
    /// True only for the page being opened. That single read is what makes an
    /// already-decoded photo appear on the FIRST frame instead of after a spinner. Doing it
    /// for every page would move the same cost to launch: a chat with fifty photos would do
    /// fifty disk reads before anything is drawn.
    init(item: ChatMediaItem, eager: Bool = false) {
        self.item = item
        self.playerController = item.type == .video ? AVPlayerViewController() : nil
        super.init(frame: .zero)

        minimumZoomScale = 1
        maximumZoomScale = item.type == .video ? 1 : 4
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

        spinner.color = UIColor(VoiidColor.textPrimary)
        addSubview(spinner)
        var retry = UIButton.Configuration.tinted()
        retry.title = "Couldn’t load media · Retry"
        retry.image = UIImage(systemName: "arrow.clockwise")
        retry.imagePadding = 8
        retry.baseForegroundColor = UIColor(VoiidColor.textPrimary)
        retry.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = UIFont.voiidRounded(ofSize: 14, weight: .medium)
            return result
        }
        retryButton.configuration = retry
        retryButton.isHidden = true
        retryButton.addAction(UIAction { [weak self] _ in self?.load() }, for: .touchUpInside)
        addSubview(retryButton)
        imageView.accessibilityLabel = item.caption ?? "Photo from \(item.displayName)"
        imageView.isAccessibilityElement = true

        // ── CACHED BYTES ARE SHOWN SYNCHRONOUSLY, DURING INIT ────────────────────
        //
        // The chat bubble already decoded this image, so `MediaCache` holds it in memory or
        // on disk. Waiting for `viewDidAppear` to call `load()` meant the viewer opened, put
        // up a spinner, and only THEN looked in a cache that could answer instantly — a
        // visible flash of loading for a photo the app already had.
        //
        // `MediaCache.image` reads memory, then disk, so this covers a cold launch too.
        // Only a genuine miss falls through to the async path and the spinner.
        if eager, item.type == .image, let cached = MediaCache.shared.image(item.ref.mediaUrl) {
            imageView.image = cached
            loaded = true
        } else {
            spinner.startAnimating()
        }

        guard item.type == .image else { return }
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
        let visible = bounds.inset(by: mediaInsets)
        spinner.center = CGPoint(x: visible.midX, y: visible.midY)
        retryButton.frame = CGRect(x: 20, y: visible.midY - 26, width: max(0, bounds.width - 40), height: 52)
        playerController?.view.frame = visible
        // Only while at rest: resizing a zoomed image would throw the user's zoom away on
        // every layout pass.
        if zoomScale <= 1.01 {
            imageView.frame = visible
            contentSize = bounds.size
            contentInset = .zero
        }
    }

    func installPlayer() {
        guard let playerController else { return }
        insertSubview(playerController.view, belowSubview: spinner)
        playerController.view.isHidden = true
        playerController.view.backgroundColor = .clear
        playerController.showsPlaybackControls = true
    }

    func pause() { playerController?.player?.pause() }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        pause()
        playerController?.player = nil
        playerController?.view.isHidden = true
        imageView.image = nil
        setZoomScale(1, animated: false)
        loaded = false
    }

    func load() {
        guard !loaded else { return }
        retryButton.isHidden = true
        if item.type == .image, let cached = MediaCache.shared.image(item.ref.mediaUrl) {
            loaded = true
            show(cached)
            return
        }
        loaded = true
        spinner.startAnimating()
        let account = TokenStore.shared.userId
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data: Data
                if let cached = MediaCache.shared.data(item.ref.mediaUrl) { data = cached }
                else { data = try await ChatEngine.shared.fetchMedia(item.ref) }
                try Task.checkCancellation()
                guard account == TokenStore.shared.userId else { return }
                MediaCache.shared.setData(data, item.ref.mediaUrl)
                if item.type == .video {
                    guard let base = MediaCache.shared.fileURL(item.ref.mediaUrl) else { throw CocoaError(.fileWriteUnknown) }
                    let ext = UTType(mimeType: item.ref.mime)?.preferredFilenameExtension ?? "mp4"
                    let url = base.appendingPathExtension(ext)
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    let asset = AVURLAsset(url: url)
                    guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadCorruptFile) }
                    try Task.checkCancellation()
                    guard account == TokenStore.shared.userId else { return }
                    playerController?.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    playerController?.view.isHidden = false
                    spinner.stopAnimating()
                } else {
                    guard let image = MediaCache.shared.image(item.ref.mediaUrl) else { throw CocoaError(.fileReadCorruptFile) }
                    show(image)
                }
            } catch {
                guard !Task.isCancelled, account == TokenStore.shared.userId else { return }
                loaded = false
                spinner.stopAnimating()
                retryButton.isHidden = false
            }
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
            setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            // Zoom TO THE TAP: double-tapping a face should bring that face closer, which is
            // the whole reason to tap a particular spot.
            let point = g.location(in: imageView)
            let side = bounds.width / 2.5
            zoom(to: CGRect(x: point.x - side / 2, y: point.y - side / 2,
                            width: side, height: side), animated: !UIAccessibility.isReduceMotionEnabled)
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
        contentView.backgroundColor = UIColor(VoiidColor.surfaceRaised)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)

        videoMark.font = .voiidRounded(ofSize: 8, weight: .semibold)
        videoMark.textColor = .white
        videoMark.layer.shadowOpacity = 0.6
        videoMark.layer.shadowRadius = 2
        videoMark.layer.shadowOffset = .zero
        contentView.addSubview(videoMark)

        outgoingBar.backgroundColor = UIColor(VoiidColor.accent)
        contentView.addSubview(outgoingBar)

        contentView.layer.borderColor = UIColor(VoiidColor.accentInk).cgColor
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
        accessibilityLabel = "\(item.type == .video ? "Video" : "Photo") from \(item.displayName)"
        isAccessibilityElement = true
        accessibilityTraits = .button
        itemId = item.id
        imageView.image = nil
        videoMark.text = item.type == .video ? (item.durationLabel ?? "▶") : nil
        videoMark.isHidden = item.type != .video
        outgoingBar.isHidden = !item.isOutgoing

        Task { @MainActor in
            let image = await ChatMediaThumbnails.shared.thumbnail(for: item, side: 50,
                                                                   displayScale: traitCollection.displayScale)
            // The cell may have been reused for a different item while the decode ran.
            guard itemId == item.id else { return }
            imageView.image = image
        }
    }

    func setActive(_ active: Bool, animated: Bool) {
        accessibilityTraits = active ? [.button, .selected] : .button
        let apply = {
            self.contentView.layer.borderWidth = active ? 2 : 0
            self.transform = active ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
        }
        animated && !UIAccessibility.isReduceMotionEnabled ? UIView.animate(withDuration: 0.2, animations: apply) : apply()
    }
}
