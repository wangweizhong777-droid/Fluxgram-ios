import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramUniversalVideoContent
import AccountContext
import UniversalMediaPlayer

private enum FluxgramShortVideoPlaybackStore {
    private static let keyPrefix = "com.fluxgram.ios.short-video-playback.v1."
    private static let lock = NSLock()
    private static let persistenceQueue = DispatchQueue(label: "com.fluxgram.ios.short-video-playback", qos: .utility)
    private static var loadedKeys = Set<String>()
    private static var cachedValues = [String: Double]()

    private static func key(for message: Message) -> String {
        return self.keyPrefix + "\(message.id.peerId.toInt64()):\(message.id.id)"
    }

    static func timestamp(for message: Message) -> Double? {
        let key = self.key(for: message)
        self.lock.lock()
        if self.loadedKeys.contains(key) {
            let value = self.cachedValues[key]
            self.lock.unlock()
            return value
        }
        let value = UserDefaults.standard.double(forKey: key)
        self.loadedKeys.insert(key)
        if value > 2.0, value.isFinite {
            self.cachedValues[key] = value
        }
        self.lock.unlock()
        return value > 2.0 ? value : nil
    }

    static func save(timestamp: Double, for message: Message, duration: Double) {
        let key = self.key(for: message)
        let value: Double?
        if !timestamp.isFinite || !duration.isFinite || timestamp <= 2.0 || timestamp >= duration - 2.0 {
            value = nil
        } else {
            value = timestamp
        }
        self.lock.lock()
        self.loadedKeys.insert(key)
        if let value {
            self.cachedValues[key] = value
        } else {
            self.cachedValues.removeValue(forKey: key)
        }
        self.lock.unlock()

        // Playback status arrives on the main queue. Keep disk I/O out of the
        // scrolling and player state path; the in-memory value is authoritative
        // for the current process.
        self.persistenceQueue.async {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

private final class FluxgramShortVideoCell: UICollectionViewCell {
    private let videoContainer = UIView()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private let positionLabel = UILabel()
    private let timeLabel = UILabel()
    private let muteButton = UIButton(type: .system)
    private let downloadButton = UIButton(type: .system)
    private let sourceButton = UIButton(type: .system)
    private let progressSlider = UISlider()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private var videoNode: UniversalVideoNode?
    private var statusDisposable = MetaDisposable()
    private var status: MediaPlayerStatus?
    private var message: Message?
    private var isActive = false
    private var isPlaybackRequested = false
    private var isSoundEnabled = true
    private var videoDimensions = CGSize(width: 1.0, height: 1.0)
    private var scrubStartTimestamp: Double?
    private var scrubTargetTimestamp: Double?
    private var resumeAfterScrub = false
    private var lastSavedTimestamp: Double = -1.0
    var downloadRequested: ((Message) -> Void)?
    var sourceMessageRequested: ((Message) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.contentView.backgroundColor = .black
        self.videoContainer.backgroundColor = .black
        self.videoContainer.clipsToBounds = false
        self.contentView.addSubview(self.videoContainer)

        self.positionLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13.0, weight: .medium)
        self.positionLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        self.positionLabel.textAlignment = .right
        self.contentView.addSubview(self.positionLabel)

        self.timeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13.0, weight: .medium)
        self.timeLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        self.timeLabel.textAlignment = .right
        self.timeLabel.text = "00:00 / 00:00"
        self.contentView.addSubview(self.timeLabel)

        self.titleLabel.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.titleLabel.textColor = .white
        self.titleLabel.numberOfLines = 1
        self.contentView.addSubview(self.titleLabel)

        self.captionLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
        self.captionLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        self.captionLabel.numberOfLines = 2
        self.contentView.addSubview(self.captionLabel)

        self.progressSlider.minimumTrackTintColor = .white
        self.progressSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.28)
        self.progressSlider.setThumbImage(FluxgramShortVideoCell.sliderThumbImage(), for: .normal)
        self.progressSlider.addTarget(self, action: #selector(self.sliderBegan), for: .touchDown)
        self.progressSlider.addTarget(self, action: #selector(self.sliderChanged), for: .valueChanged)
        self.progressSlider.addTarget(self, action: #selector(self.sliderEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        self.contentView.addSubview(self.progressSlider)

        self.muteButton.tintColor = .white
        self.muteButton.backgroundColor = UIColor.black.withAlphaComponent(0.34)
        self.muteButton.layer.cornerRadius = 20.0
        self.muteButton.addTarget(self, action: #selector(self.toggleSound), for: .touchUpInside)
        self.contentView.addSubview(self.muteButton)
        self.updateMuteIcon()

        self.downloadButton.tintColor = .white
        self.downloadButton.backgroundColor = UIColor.black.withAlphaComponent(0.34)
        self.downloadButton.layer.cornerRadius = 20.0
        self.downloadButton.setImage(UIImage(systemName: "arrow.down.to.line.compact"), for: .normal)
        self.downloadButton.accessibilityLabel = "下载到 NAS"
        self.downloadButton.addTarget(self, action: #selector(self.downloadPressed), for: .touchUpInside)
        self.contentView.addSubview(self.downloadButton)

        self.sourceButton.tintColor = .white
        self.sourceButton.backgroundColor = UIColor.black.withAlphaComponent(0.34)
        self.sourceButton.layer.cornerRadius = 20.0
        self.sourceButton.setImage(UIImage(systemName: "bubble.left.and.bubble.right.fill"), for: .normal)
        self.sourceButton.accessibilityLabel = "打开原消息"
        self.sourceButton.addTarget(self, action: #selector(self.sourceMessagePressed), for: .touchUpInside)
        self.contentView.addSubview(self.sourceButton)

        self.activityIndicator.color = .white
        self.activityIndicator.hidesWhenStopped = true
        self.contentView.addSubview(self.activityIndicator)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.savePlaybackPosition()
        self.statusDisposable.dispose()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.savePlaybackPosition()
        self.statusDisposable.set(nil)
        self.videoNode?.canAttachContent = false
        self.videoNode?.removeFromSupernode()
        self.videoNode?.view.removeFromSuperview()
        self.videoNode = nil
        self.status = nil
        self.message = nil
        self.isActive = false
        self.isPlaybackRequested = false
        self.isSoundEnabled = true
        self.videoDimensions = CGSize(width: 1.0, height: 1.0)
        self.scrubStartTimestamp = nil
        self.scrubTargetTimestamp = nil
        self.resumeAfterScrub = false
        self.lastSavedTimestamp = -1.0
        self.updateMuteIcon()
        self.activityIndicator.stopAnimating()
        self.progressSlider.value = 0.0
        self.timeLabel.text = "00:00 / 00:00"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.videoContainer.frame = self.contentView.bounds
        self.videoNode?.frame = self.videoContainer.bounds
        self.layoutVideoNode()

        let safeBottom = self.safeAreaInsets.bottom
        let bottom = self.contentView.bounds.height - safeBottom - 18.0
        self.progressSlider.frame = CGRect(x: 16.0, y: bottom - 18.0, width: self.contentView.bounds.width - 32.0, height: 22.0)
        self.captionLabel.frame = CGRect(x: 18.0, y: bottom - 72.0, width: self.contentView.bounds.width - 88.0, height: 40.0)
        self.titleLabel.frame = CGRect(x: 18.0, y: bottom - 98.0, width: self.contentView.bounds.width - 88.0, height: 22.0)
        self.positionLabel.frame = CGRect(x: 18.0, y: 66.0 + self.safeAreaInsets.top, width: 58.0, height: 18.0)
        self.timeLabel.frame = CGRect(x: self.contentView.bounds.width - 126.0, y: bottom - 41.0, width: 108.0, height: 18.0)
        self.muteButton.frame = CGRect(x: self.contentView.bounds.width - 58.0, y: 58.0 + self.safeAreaInsets.top, width: 40.0, height: 40.0)
        self.downloadButton.frame = CGRect(x: self.contentView.bounds.width - 58.0, y: 106.0 + self.safeAreaInsets.top, width: 40.0, height: 40.0)
        self.sourceButton.frame = CGRect(x: self.contentView.bounds.width - 58.0, y: 154.0 + self.safeAreaInsets.top, width: 40.0, height: 40.0)
        self.activityIndicator.center = CGPoint(x: self.contentView.bounds.midX, y: self.contentView.bounds.midY)
    }

    func configure(context: AccountContext, message: Message, position: Int, total: Int) {
        self.prepareForReuse()
        self.message = message
        self.positionLabel.text = "\(position + 1) / \(total)"
        self.titleLabel.text = message.effectiveAuthor.flatMap(EnginePeer.init)?.displayTitle(strings: context.sharedContext.currentPresentationData.with { $0 }.strings, displayOrder: context.sharedContext.currentPresentationData.with { $0 }.nameDisplayOrder) ?? "短视频"
        self.captionLabel.text = message.text.isEmpty ? "短视频流" : message.text

        guard let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first(where: { $0.isVideo || $0.isInstantVideo }) else {
            return
        }
        let resumeTimestamp = FluxgramShortVideoPlaybackStore.timestamp(for: message)
        let fileReference = FileMediaReference.message(message: MessageReference(message), media: file)
        let content: UniversalVideoContent
        if #available(iOS 13.0, *), NativeVideoContent.isHLSVideo(file: file) {
            content = HLSVideoContent(
                id: .message(message.stableId, file.fileId),
                userLocation: .peer(message.id.peerId),
                fileReference: fileReference,
                streamVideo: true,
                loopVideo: true,
                autoFetchFullSizeThumbnail: true,
                codecConfiguration: HLSCodecConfiguration(context: context)
            )
        } else {
            content = NativeVideoContent(
                id: .message(message.stableId, file.fileId),
                userLocation: .peer(message.id.peerId),
                fileReference: fileReference,
                streamVideo: .conservative,
                loopVideo: true,
                enableSound: true,
                fetchAutomatically: true,
                startTimestamp: resumeTimestamp,
                placeholderColor: .black,
                storeAfterDownload: nil
            )
        }
        // NativeVideoContent normalizes dimensions for videos whose rotation metadata differs from their preview.
        self.videoDimensions = content.dimensions
        let mediaManager = context.sharedContext.mediaManager
        let videoNode = UniversalVideoNode(
            context: context,
            postbox: context.account.postbox,
            audioSession: mediaManager.audioSession,
            manager: mediaManager.universalVideoManager,
            decoration: GalleryVideoDecoration(),
            content: content,
            priority: .gallery,
            autoplay: false,
            snapshotContentWhenGone: true
        )
        videoNode.backgroundColor = .black
        videoNode.frame = self.videoContainer.bounds
        self.videoContainer.addSubview(videoNode.view)
        self.videoNode = videoNode
        self.layoutVideoNode()
        videoNode.ownsContentNodeUpdated = { [weak self, weak videoNode] ownsContentNode in
            guard let self, let videoNode else {
                return
            }
            if ownsContentNode {
                self.startPlaybackIfReady(videoNode)
            } else if self.isActive {
                self.isPlaybackRequested = true
                self.activityIndicator.startAnimating()
            }
        }
        self.statusDisposable.set((videoNode.status |> deliverOnMainQueue).start(next: { [weak self] status in
            self?.updateStatus(status)
        }))
    }

    func setPlayback(active: Bool, preload: Bool) {
        let didChangeActiveState = self.isActive != active
        self.isActive = active
        guard let videoNode = self.videoNode else {
            return
        }
        videoNode.canAttachContent = active || preload
        if active {
            self.activityIndicator.startAnimating()
            if didChangeActiveState {
                self.isPlaybackRequested = true
            }
            self.startPlaybackIfReady(videoNode)
        } else {
            self.isPlaybackRequested = false
            videoNode.pause()
        }
    }

    private func startPlaybackIfReady(_ videoNode: UniversalVideoNode) {
        guard self.isActive, self.isPlaybackRequested, videoNode.ownsContentNode else {
            return
        }
        self.isPlaybackRequested = false
        videoNode.playOnceWithSound(playAndRecord: false, seek: .automatic, actionAtEnd: .loop)
    }

    func togglePlayPause() {
        self.videoNode?.togglePlayPause()
    }

    func beginHorizontalScrub() {
        self.beginScrub()
    }

    func canBeginHorizontalScrub() -> Bool {
        guard self.isActive, let status = self.status else {
            return false
        }
        return status.duration > 0.0
    }

    private func beginScrub() {
        guard let status = self.status, status.duration > 0.0 else {
            return
        }
        self.scrubStartTimestamp = status.timestamp
        self.scrubTargetTimestamp = status.timestamp
        self.resumeAfterScrub = status.status == .playing
        self.videoNode?.pause()
    }

    func scrub(translation: CGFloat, width: CGFloat) {
        guard let start = self.scrubStartTimestamp, let status = self.status, status.duration > 0.0 else {
            return
        }
        let timestamp = min(max(0.0, start + Double(translation / max(width, 1.0)) * status.duration), status.duration)
        self.scrubTargetTimestamp = timestamp
        self.progressSlider.setValue(Float(timestamp / status.duration), animated: false)
    }

    func endHorizontalScrub() {
        self.finishScrub()
    }

    private func finishScrub() {
        guard self.scrubStartTimestamp != nil else {
            return
        }
        let targetTimestamp = self.scrubTargetTimestamp
        let shouldResume = self.resumeAfterScrub
        self.scrubStartTimestamp = nil
        self.scrubTargetTimestamp = nil
        self.resumeAfterScrub = false
        if let targetTimestamp {
            self.videoNode?.seek(targetTimestamp)
        }
        if shouldResume {
            self.videoNode?.play()
        }
    }

    private func layoutVideoNode() {
        guard let videoNode = self.videoNode else {
            return
        }
        let containerSize = self.videoContainer.bounds.size
        guard containerSize.width > 0.0, containerSize.height > 0.0, self.videoDimensions.width > 0.0, self.videoDimensions.height > 0.0 else {
            return
        }
        let scale = min(containerSize.width / self.videoDimensions.width, containerSize.height / self.videoDimensions.height)
        let videoSize = CGSize(width: floor(self.videoDimensions.width * scale), height: floor(self.videoDimensions.height * scale))
        videoNode.frame = CGRect(
            x: floor((containerSize.width - videoSize.width) / 2.0),
            y: floor((containerSize.height - videoSize.height) / 2.0),
            width: videoSize.width,
            height: videoSize.height
        )
        videoNode.updateLayout(size: videoSize, actualSize: videoSize, transition: .immediate)
    }

    private func updateStatus(_ status: MediaPlayerStatus?) {
        self.status = status
        guard let status else {
            return
        }
        if status.dimensions.width > 0.0,
           status.dimensions.height > 0.0,
           status.dimensions != self.videoDimensions {
            self.videoDimensions = status.dimensions
            self.layoutVideoNode()
        }
        if status.duration > 0.0, !self.progressSlider.isTracking, self.scrubTargetTimestamp == nil {
            self.progressSlider.value = Float(status.timestamp / status.duration)
        }
        self.timeLabel.text = "\(self.timeString(status.timestamp)) / \(self.timeString(status.duration))"
        if case .buffering = status.status {
            if self.isActive {
                self.activityIndicator.startAnimating()
            }
        } else {
            self.activityIndicator.stopAnimating()
        }
        self.savePlaybackPosition()
    }

    private func savePlaybackPosition() {
        guard let message = self.message, let status = self.status, status.duration > 0.0 else {
            return
        }
        guard abs(status.timestamp - self.lastSavedTimestamp) >= 2.0 else {
            return
        }
        self.lastSavedTimestamp = status.timestamp
        FluxgramShortVideoPlaybackStore.save(timestamp: status.timestamp, for: message, duration: status.duration)
    }

    @objc private func toggleSound() {
        self.isSoundEnabled.toggle()
        self.videoNode?.setSoundEnabled(self.isSoundEnabled)
        self.updateMuteIcon()
    }

    @objc private func downloadPressed() {
        guard let message = self.message else {
            return
        }
        self.downloadRequested?(message)
    }

    @objc private func sourceMessagePressed() {
        guard let message = self.message else {
            return
        }
        self.sourceMessageRequested?(message)
    }

    private func timeString(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func updateMuteIcon() {
        let name = self.isSoundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"
        self.muteButton.setImage(UIImage(systemName: name), for: .normal)
    }

    @objc private func sliderBegan() {
        self.beginScrub()
    }

    @objc private func sliderChanged() {
        guard let status = self.status, status.duration > 0.0 else {
            return
        }
        if self.scrubStartTimestamp == nil {
            self.beginScrub()
        }
        self.scrubTargetTimestamp = Double(self.progressSlider.value) * status.duration
    }

    @objc private func sliderEnded() {
        self.finishScrub()
    }

    private static func sliderThumbImage() -> UIImage? {
        let size = CGSize(width: 11.0, height: 11.0)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }
}

public final class FluxgramShortVideoFeedController: ViewController, UICollectionViewDataSource, UICollectionViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let context: AccountContext
    private let messages: [EngineRawMessage]
    private let collectionView: UICollectionView
    private let backButton = UIButton(type: .system)
    private let horizontalPan = UIPanGestureRecognizer()
    private let tapGesture = UITapGestureRecognizer()
    private var currentIndex = 0
    private var didActivateInitialCell = false
    private var interactivePopGestureWasEnabled: Bool?
    private var prefetchDisposables = [MetaDisposable(), MetaDisposable(), MetaDisposable()]
    private var viewedIndexes = Set<Int>()
    public var downloadRequested: ((EngineRawMessage) -> Void)?
    public var sourceMessageRequested: ((EngineRawMessage) -> Void)?
    public var messageViewed: ((EngineRawMessage) -> Void)?

    public init(context: AccountContext, messages: [EngineRawMessage]) {
        self.context = context
        self.messages = messages
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0.0
        layout.minimumInteritemSpacing = 0.0
        self.collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .White
        self.isOpaqueWhenInOverlay = true
        self.blocksBackgroundWhenInOverlay = true
        self.prefersOnScreenNavigationHidden = true
        self.attemptNavigation = { _ in
            return false
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func loadDisplayNode() {
        let node = ASDisplayNode()
        node.backgroundColor = .black
        self.displayNode = node
        self.displayNodeDidLoad()
        self.displayNode.view.disablesInteractiveTransitionGestureRecognizer = true

        self.collectionView.backgroundColor = .black
        self.collectionView.isPagingEnabled = true
        self.collectionView.decelerationRate = .fast
        self.collectionView.showsVerticalScrollIndicator = false
        self.collectionView.showsHorizontalScrollIndicator = false
        self.collectionView.contentInsetAdjustmentBehavior = .never
        self.collectionView.isDirectionalLockEnabled = true
        self.collectionView.dataSource = self
        self.collectionView.delegate = self
        self.collectionView.register(FluxgramShortVideoCell.self, forCellWithReuseIdentifier: "FluxgramShortVideoCell")
        self.displayNode.view.addSubview(self.collectionView)

        self.backButton.tintColor = .white
        self.backButton.backgroundColor = UIColor.black.withAlphaComponent(0.34)
        self.backButton.layer.cornerRadius = 20.0
        self.backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        self.backButton.addTarget(self, action: #selector(self.dismissFeed), for: .touchUpInside)
        self.displayNode.view.addSubview(self.backButton)

        self.horizontalPan.addTarget(self, action: #selector(self.handleHorizontalPan(_:)))
        self.horizontalPan.delegate = self
        self.horizontalPan.cancelsTouchesInView = false
        self.horizontalPan.maximumNumberOfTouches = 1
        self.collectionView.addGestureRecognizer(self.horizontalPan)
        // Let the direction-gated scrub recognizer decide first. A vertical
        // swipe fails this recognizer immediately and continues into paging;
        // a horizontal swipe owns the touch without starving the collection view.
        self.collectionView.panGestureRecognizer.require(toFail: self.horizontalPan)

        self.tapGesture.addTarget(self, action: #selector(self.handleTap(_:)))
        self.tapGesture.delegate = self
        self.collectionView.addGestureRecognizer(self.tapGesture)
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.activateInitialCell()
        Queue.mainQueue().after(0.1) { [weak self] in
            self?.activateInitialCell()
        }
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let gesture = self.navigationController?.interactivePopGestureRecognizer {
            self.interactivePopGestureWasEnabled = gesture.isEnabled
            gesture.isEnabled = false
        }
        self.activateInitialCell()
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.restoreInteractivePopGesture()
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        for case let cell as FluxgramShortVideoCell in self.collectionView.visibleCells {
            cell.setPlayback(active: false, preload: false)
        }
    }

    deinit {
        for disposable in self.prefetchDisposables {
            disposable.dispose()
        }
        self.restoreInteractivePopGesture()
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.collectionView.frame = CGRect(origin: .zero, size: layout.size)
        if let flowLayout = self.collectionView.collectionViewLayout as? UICollectionViewFlowLayout, flowLayout.itemSize != layout.size {
            flowLayout.itemSize = layout.size
            flowLayout.invalidateLayout()
        }
        self.backButton.frame = CGRect(x: layout.safeInsets.left + 14.0, y: (layout.statusBarHeight ?? 0.0) + 14.0, width: 40.0, height: 40.0)
        self.activateInitialCell()
    }

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return self.messages.count
    }

    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "FluxgramShortVideoCell", for: indexPath) as! FluxgramShortVideoCell
        cell.configure(context: self.context, message: self.messages[indexPath.item], position: indexPath.item, total: self.messages.count)
        cell.downloadRequested = { [weak self] message in
            self?.downloadRequested?(message)
        }
        cell.sourceMessageRequested = { [weak self] message in
            self?.sourceMessageRequested?(message)
        }
        return cell
    }

    public func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let cell = cell as? FluxgramShortVideoCell {
            let distance = abs(indexPath.item - self.currentIndex)
            cell.setPlayback(active: distance == 0, preload: distance == 1)
        }
        self.updatePlayback()
    }

    private func activateInitialCell() {
        self.collectionView.layoutIfNeeded()
        if let cell = self.collectionView.cellForItem(at: IndexPath(item: self.currentIndex, section: 0)) as? FluxgramShortVideoCell {
            cell.setPlayback(active: true, preload: false)
            self.didActivateInitialCell = true
            self.markCurrentMessageViewed()
        }
        if self.didActivateInitialCell {
            self.prefetchNextVideos(around: self.currentIndex)
        }
        self.updatePlayback()
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.updateCurrentIndex()
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            self.updateCurrentIndex()
        }
    }

    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let pageHeight = max(self.collectionView.bounds.height, 1.0)
        let targetIndex = Int(round(targetContentOffset.pointee.y / pageHeight))
        let boundedIndex = min(max(targetIndex, 0), max(self.messages.count - 1, 0))
        self.prefetchNextVideos(around: boundedIndex)
    }

    private func updateCurrentIndex() {
        let pageHeight = max(self.collectionView.bounds.height, 1.0)
        let index = Int(round(self.collectionView.contentOffset.y / pageHeight))
        let boundedIndex = min(max(index, 0), max(self.messages.count - 1, 0))
        guard boundedIndex != self.currentIndex else {
            self.updatePlayback()
            return
        }
        self.currentIndex = boundedIndex
        self.prefetchNextVideos(around: boundedIndex)
        self.markCurrentMessageViewed()
        self.updatePlayback()
    }

    private func markCurrentMessageViewed() {
        guard self.currentIndex >= 0, self.currentIndex < self.messages.count,
              self.viewedIndexes.insert(self.currentIndex).inserted else {
            return
        }
        self.messageViewed?(self.messages[self.currentIndex])
    }

    private func prefetchNextVideos(around index: Int) {
        for disposable in self.prefetchDisposables {
            disposable.set(nil)
        }
        guard !self.messages.isEmpty else {
            return
        }

        // Warm the visible target as well as the next two pages. The first
        // page used to start only from the player itself, which made it the
        // one page most likely to show a black frame before its first decode.
        let offsets = [0, 1, 2]
        for (slot, offset) in offsets.enumerated() {
            let candidateIndex = index + offset
            guard candidateIndex >= 0, candidateIndex < self.messages.count else {
                continue
            }
            let message = self.messages[candidateIndex]
            guard let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first(where: { $0.isVideo || $0.isInstantVideo }) else {
                continue
            }
            let fileReference = FileMediaReference.message(message: MessageReference(message), media: file)
            self.prefetchDisposables[slot].set(
                preloadVideoResource(
                    postbox: self.context.account.postbox,
                    userLocation: .peer(message.id.peerId),
                    userContentType: MediaResourceUserContentType(file: file),
                    resourceReference: fileReference.resourceReference(file.resource),
                    duration: 4.0
                ).startStrict()
            )
        }
    }

    private func updatePlayback() {
        for case let cell as FluxgramShortVideoCell in self.collectionView.visibleCells {
            guard let indexPath = self.collectionView.indexPath(for: cell) else {
                continue
            }
            let distance = abs(indexPath.item - self.currentIndex)
            cell.setPlayback(active: distance == 0, preload: distance == 1)
        }
    }

    private func restoreInteractivePopGesture() {
        guard let wasEnabled = self.interactivePopGestureWasEnabled,
              let gesture = self.navigationController?.interactivePopGestureRecognizer else {
            return
        }
        gesture.isEnabled = wasEnabled
        self.interactivePopGestureWasEnabled = nil
    }

    @objc private func dismissFeed() {
        if let navigationController = self.navigationController {
            navigationController.popViewController(animated: true)
        } else {
            self.presentingViewController?.dismiss(animated: true)
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let indexPath = self.collectionView.indexPathForItem(at: gesture.location(in: self.collectionView)),
              indexPath.item == self.currentIndex,
              let cell = self.collectionView.cellForItem(at: indexPath) as? FluxgramShortVideoCell else {
            return
        }
        cell.togglePlayPause()
    }

    @objc private func handleHorizontalPan(_ gesture: UIPanGestureRecognizer) {
        guard let cell = self.collectionView.cellForItem(at: IndexPath(item: self.currentIndex, section: 0)) as? FluxgramShortVideoCell else {
            return
        }
        switch gesture.state {
        case .began:
            cell.beginHorizontalScrub()
        case .changed:
            cell.scrub(translation: gesture.translation(in: self.collectionView).x, width: self.collectionView.bounds.width)
        case .ended, .cancelled, .failed:
            cell.endHorizontalScrub()
        default:
            break
        }
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === self.horizontalPan {
            guard let cell = self.collectionView.cellForItem(at: IndexPath(item: self.currentIndex, section: 0)) as? FluxgramShortVideoCell,
                  cell.canBeginHorizontalScrub() else {
                return false
            }
            let translation = self.horizontalPan.velocity(in: self.collectionView)
            return abs(translation.x) > abs(translation.y) && abs(translation.x) > 8.0
        }
        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === self.tapGesture || gestureRecognizer === self.horizontalPan {
            var view: UIView? = touch.view
            while let current = view {
                if current is UIControl {
                    return false
                }
                view = current.superview
            }
        }
        return true
    }
}
