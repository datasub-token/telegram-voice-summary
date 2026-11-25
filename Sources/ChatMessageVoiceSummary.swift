import Foundation
import UIKit
import Display
import AppBundle
import SwiftSignalKit
import TelegramCore
import AccountContext
import ComponentFlow
import LottieAnimationComponent
import ChatMessageItemCommon

/// AI Summary for voice messages: a long voice message can be summarized the way a long text message is. The summary is
/// a few points under the waveform, each led by the moment of the voice it comes from; Telegram turns those timecodes into
/// links that play the voice from there.
public final class VoiceSummaryStore {
    public enum State: Equatable {
        case collapsed
        case inProgress
        case shown
    }

    public struct Point: Equatable {
        public let time: Double
        public let text: String

        public init(time: Double, text: String) {
            self.time = time
            self.text = text
        }
    }

    private struct Entry {
        var state: State = .collapsed
        var points: [Point]?
    }

    public static let shared = VoiceSummaryStore()

    /// Voices shorter than this are quick to listen to and get no summary button.
    public static let minimumDuration: Int32 = 30

    /// The text attribute that marks a timecode in a summary (its value is the time in seconds, an `NSNumber`).
    public static let timecodeAttribute = NSAttributedString.Key("VoiceSummaryTimecode")

    // laid out off the main thread, changed on it
    private let entries = Atomic<[EngineMessage.Id: Entry]>(value: [:])

    public func state(_ id: EngineMessage.Id) -> State {
        return self.entries.with { $0[id]?.state ?? .collapsed }
    }

    public func isShown(_ id: EngineMessage.Id) -> Bool {
        return self.state(id) == .shown
    }

    public func points(_ id: EngineMessage.Id) -> [Point]? {
        return self.entries.with { $0[id]?.points }
    }

    public func update(_ id: EngineMessage.Id, state: State, points: [Point]? = nil) {
        let _ = self.entries.modify { current in
            var current = current
            var entry = current[id] ?? Entry()
            entry.state = state
            if let points {
                entry.points = points
            }
            current[id] = entry
            return current
        }
    }
}

/// Makes the points. A production version would get them from the server with the voice's transcription, the way
/// `messages.summarizeText` summarizes a text message. Here they are made on the device from Telegram's own voice-to-text:
/// the sentence that opens each third of the transcription, at the moment it starts (estimated from where it stands in
/// the text).
enum VoiceSummarizer {
    static func summarize(context: AccountContext, messageId: EngineMessage.Id, duration: Double) -> Signal<[VoiceSummaryStore.Point]?, NoError> {
        let transcription: Signal<String?, NoError> = context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
        |> mapToSignal { message -> Signal<String?, NoError> in
            guard let message else {
                return .single(nil)
            }
            if let text = transcriptionText(message) {
                return .single(text)
            }
            // not transcribed yet: Telegram's voice-to-text first
            return context.engine.messages.transcribeAudio(messageId: messageId)
            |> mapToSignal { _ -> Signal<String?, NoError> in
                return context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
                |> map { message -> String? in
                    return message.flatMap(transcriptionText)
                }
            }
        }
        return transcription
        |> mapToSignal { text -> Signal<[VoiceSummaryStore.Point]?, NoError> in
            guard let text else {
                return .single(nil)
            }
            // the summary comes back like an answer, a moment after the listening ends
            return .single(points(transcription: text, duration: duration))
            |> delay(1.2, queue: Queue.mainQueue())
        }
    }

    private static func transcriptionText(_ message: EngineMessage) -> String? {
        if case let .success(text, _) = transcribedText(message: message), !text.isEmpty {
            return text
        }
        return nil
    }

    static func points(transcription: String, duration: Double) -> [VoiceSummaryStore.Point] {
        let text = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return []
        }
        // the sentences, each with where it starts in the text
        var sentences: [(start: Int, text: String)] = []
        let characters = Array(text)
        var start = 0
        for i in 0 ..< characters.count {
            let isEnd = ".!?…".contains(characters[i]) && (i + 1 == characters.count || characters[i + 1] == " " || characters[i + 1] == "\n")
            if isEnd || i + 1 == characters.count {
                let sentence = String(characters[start ... i]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append((start, sentence))
                }
                start = i + 1
            }
        }
        guard !sentences.isEmpty else {
            return []
        }
        // the one that opens each third
        var picked: [Int] = []
        for third in 0 ..< 3 {
            let from = characters.count * third / 3
            if let index = sentences.firstIndex(where: { $0.start >= from }), !picked.contains(index) {
                picked.append(index)
            }
        }
        if picked.isEmpty {
            picked = [0]
        }
        return picked.map { index in
            let sentence = sentences[index]
            let time = max(0.0, min(duration - 1.0, (duration * Double(sentence.start) / Double(characters.count)).rounded(.down)))
            return VoiceSummaryStore.Point(time: time, text: shortened(sentence.text, to: 44))
        }
    }

    /// A point is one line: cut at a word, with an ellipsis.
    private static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else {
            return text
        }
        var result = ""
        for word in text.split(separator: " ") {
            if result.count + word.count + 1 > limit - 1 {
                break
            }
            result += result.isEmpty ? String(word) : " " + word
        }
        return (result.isEmpty ? String(text.prefix(limit - 1)) : result) + "…"
    }
}

/// The summary button in a voice message's row, right of the transcribe button and drawn like it (30 × 30, radius 10, the
/// bubble's accent at 10 %). It carries AI Summary's own icons — summary before, original after — and its two blinking
/// stars (`ChatMessageShareButton`); while the voice is being summarized the transcribe button's progress ring runs round it.
final class VoiceSummaryButtonView: HighlightTrackingButton {
    private let backgroundLayer: SimpleLayer
    private let starsContainer: UIView
    private var starViews: [UIImageView] = []
    private let iconView: UIImageView
    private var progressView: ComponentHostView<Empty>?

    private var currentState: VoiceSummaryStore.State?
    private var currentColor: UIColor?

    var pressed: (() -> Void)?

    override init(frame: CGRect) {
        self.backgroundLayer = SimpleLayer()
        self.starsContainer = UIView()
        self.iconView = UIImageView()

        super.init(frame: frame)

        self.backgroundLayer.masksToBounds = true
        self.backgroundLayer.cornerRadius = 10.0
        self.layer.addSublayer(self.backgroundLayer)

        self.starsContainer.isUserInteractionEnabled = false
        self.starsContainer.clipsToBounds = true
        self.starsContainer.layer.cornerRadius = 10.0
        self.addSubview(self.starsContainer)

        self.iconView.isUserInteractionEnabled = false
        self.addSubview(self.iconView)

        self.accessibilityLabel = "AI Summary"
        self.addTarget(self, action: #selector(self.pressedEvent), for: .touchUpInside)

        // the finger dims the icon; letting go brings it back over 0.2 s (ChatMessageShareButton)
        self.highligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            if highlighted {
                self.iconView.layer.removeAnimation(forKey: "opacity")
                self.iconView.alpha = 0.4
            } else {
                self.iconView.alpha = 1.0
                self.iconView.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func pressedEvent() {
        self.pressed?()
    }

    func update(foregroundColor: UIColor, backgroundColor: UIColor, state: VoiceSummaryStore.State, animated: Bool) {
        let size = CGSize(width: 30.0, height: 30.0)
        self.backgroundLayer.frame = CGRect(origin: CGPoint(), size: size)
        self.backgroundLayer.backgroundColor = backgroundColor.cgColor
        self.starsContainer.frame = CGRect(origin: CGPoint(), size: size)

        if self.currentColor != foregroundColor {
            self.currentColor = foregroundColor
            self.updateStars(color: foregroundColor)
            self.currentState = nil
        }

        let showsSummary = state != .collapsed
        let previousShowsSummary = self.currentState.flatMap { $0 != .collapsed }
        if previousShowsSummary != showsSummary {
            let image = generateTintedImage(image: UIImage(bundleImageName: showsSummary ? "Chat/Message/ExpandIcon" : "Chat/Message/CollapseIcon"), color: foregroundColor)
            if animated, previousShowsSummary != nil, let snapshot = self.iconView.snapshotView(afterScreenUpdates: false) {
                // the old icon shrinks away as the new one grows in, 0.25 s each (ChatMessageShareButton)
                snapshot.frame = self.iconView.frame
                self.insertSubview(snapshot, aboveSubview: self.iconView)
                snapshot.layer.animateScale(from: 1.0, to: 0.01, duration: 0.25, removeOnCompletion: false, completion: { [weak snapshot] _ in
                    snapshot?.removeFromSuperview()
                })
                self.iconView.layer.animateScale(from: 0.01, to: 1.0, duration: 0.25)
            }
            self.iconView.image = image
        }
        if let image = self.iconView.image {
            self.iconView.frame = CGRect(origin: CGPoint(x: floor((size.width - image.size.width) / 2.0), y: floor((size.height - image.size.height) / 2.0)), size: image.size)
        }

        // the transcribe button's progress: its Lottie, looping over the button grown by 1 (AudioTranscriptionButtonComponent)
        if state == .inProgress {
            let progressView: ComponentHostView<Empty>
            if let current = self.progressView {
                progressView = current
            } else {
                progressView = ComponentHostView<Empty>()
                progressView.isUserInteractionEnabled = false
                self.progressView = progressView
                self.addSubview(progressView)
                if animated {
                    progressView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15)
                }
            }
            let progressFrame = CGRect(origin: CGPoint(), size: size).insetBy(dx: -1.0, dy: -1.0)
            let _ = progressView.update(
                transition: .immediate,
                component: AnyComponent(LottieAnimationComponent(
                    animation: LottieAnimationComponent.AnimationItem(
                        name: "voicets_progress",
                        mode: .animating(loop: true)
                    ),
                    colors: [
                        "Rectangle 60.Rectangle 60.Stroke 1": foregroundColor
                    ],
                    size: progressFrame.size
                )),
                environment: {},
                containerSize: progressFrame.size
            )
            progressView.frame = progressFrame
        } else if let progressView = self.progressView {
            self.progressView = nil
            if animated {
                progressView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false, completion: { [weak progressView] _ in
                    progressView?.removeFromSuperview()
                })
            } else {
                progressView.removeFromSuperview()
            }
        }

        self.currentState = state
    }

    /// Two 10-pt stars at 50 % in the corners, each 1 → 1 → 0.55 at key times 0 / 0.1 / 1 over 0.9 s, auto-reversed, for
    /// ever; the lower one 0.9 s later (ChatMessageShareButton's `StarsView`).
    private func updateStars(color: UIColor) {
        for view in self.starViews {
            view.removeFromSuperview()
        }
        self.starViews.removeAll()
        guard let image = generateTintedImage(image: UIImage(bundleImageName: "Settings/Storage/ParticleStar"), color: color) else {
            return
        }
        for (index, center) in [CGPoint(x: 9.0, y: 9.0), CGPoint(x: 21.0, y: 21.0)].enumerated() {
            let view = UIImageView(image: image)
            view.alpha = 0.5
            view.frame = CGRect(origin: CGPoint(x: center.x - 5.0, y: center.y - 5.0), size: CGSize(width: 10.0, height: 10.0))
            self.starsContainer.addSubview(view)
            self.starViews.append(view)

            let animation = CAKeyframeAnimation(keyPath: "transform.scale")
            animation.values = [1.0 as NSNumber, 1.0 as NSNumber, 0.55 as NSNumber]
            animation.keyTimes = [0.0 as NSNumber, 0.1 as NSNumber, 1.0 as NSNumber]
            animation.duration = 0.9
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.beginTime = view.layer.convertTime(CACurrentMediaTime(), from: nil) + Double(index) * 0.9
            animation.isRemovedOnCompletion = false
            view.layer.add(animation, forKey: "blink")
        }
    }
}
