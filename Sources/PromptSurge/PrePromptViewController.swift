import UIKit

final class PrePromptViewController: UIViewController, UIGestureRecognizerDelegate {
    private let promptResponse: PromptResponse
    private let onAccept: () -> Void
    private let onDismiss: () -> Void

    private let cardView = UIView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let textStack = UIStackView()
    private let headerImageView = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let positiveButton = UIButton(type: .system)
    private let negativeButton = UIButton(type: .system)

    private var imageHeightConstraint: NSLayoutConstraint?

    /// The image is decorative. It must never delay or block the dialog, so it gets its own
    /// short-timeout session rather than the shared one.
    private lazy var imageSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    init(promptResponse: PromptResponse, onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.promptResponse = promptResponse
        self.onAccept = onAccept
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupBackground()
        setupCard()
    }

    private func setupBackground() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapDismiss))
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    /// Only taps on the scrim dismiss. Without this, a tap anywhere on the card itself — the
    /// title, the body, the header image — counted as a dismissal.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return !cardView.bounds.contains(touch.location(in: cardView))
    }

    private func setupCard() {
        let theme = promptResponse.theme
        let text = promptResponse.text

        let backgroundColor = color(theme?.backgroundColor) ?? .systemBackground
        let textColor       = color(theme?.textColor) ?? .label
        let accentColor     = color(theme?.accentColor) ?? .systemBlue
        // `buttonTextColor` is a foreground colour: it is the label on top of the accent fill,
        // never a background. Painting a button's background with it is what made the dismiss
        // button invisible on Unity.
        let buttonTextColor = color(theme?.buttonTextColor) ?? .white

        cardView.backgroundColor = backgroundColor
        cardView.layer.cornerRadius = 16
        cardView.layer.masksToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.isUserInteractionEnabled = true
        view.addSubview(cardView)

        // Header image — initially zero height, expands after the image loads.
        headerImageView.contentMode = .scaleAspectFill
        headerImageView.clipsToBounds = true
        let imageHeight = headerImageView.heightAnchor.constraint(equalToConstant: 0)
        imageHeight.isActive = true
        imageHeightConstraint = imageHeight

        titleLabel.text = text.title
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = textColor
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center

        bodyLabel.text = text.body
        bodyLabel.font = .systemFont(ofSize: 15)
        bodyLabel.textColor = textColor
        bodyLabel.numberOfLines = 0
        bodyLabel.textAlignment = .center

        textStack.axis = .vertical
        textStack.spacing = 12
        textStack.isLayoutMarginsRelativeArrangement = true
        textStack.layoutMargins = UIEdgeInsets(top: 24, left: 20, bottom: 0, right: 20)
        [titleLabel, bodyLabel].forEach { textStack.addArrangedSubview($0) }

        contentStack.axis = .vertical
        contentStack.spacing = 0
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        [headerImageView, textStack].forEach { contentStack.addArrangedSubview($0) }

        // Long localized copy on a small device used to push the buttons off screen, because
        // nothing here scrolled and nothing capped the card's height.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.addSubview(contentStack)
        cardView.addSubview(scrollView)

        // Confirm: filled in the accent colour, label in the button text colour.
        stylePrimaryButton(positiveButton, title: text.positiveButton, fill: accentColor, label: buttonTextColor)
        positiveButton.addTarget(self, action: #selector(didTapAccept), for: .touchUpInside)

        // Dismiss: outlined, label in the accent colour. Matches the Android dialog.
        styleSecondaryButton(negativeButton, title: text.negativeButton, label: accentColor)
        negativeButton.addTarget(self, action: #selector(didTapDismiss), for: .touchUpInside)

        // Negative (dismiss) on the left, positive (accept) on the right.
        let buttonStack = UIStackView(arrangedSubviews: [negativeButton, positiveButton])
        buttonStack.axis = .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 12
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(buttonStack)

        // The card hugs its content, but never grows past 90% of the safe area — past that the
        // scroll view takes over.
        let hugContent = scrollView.heightAnchor.constraint(equalTo: contentStack.heightAnchor)
        hugContent.priority = .defaultHigh

        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cardView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.85),
            cardView.heightAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor,
                multiplier: 0.9
            ),

            scrollView.topAnchor.constraint(equalTo: cardView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            hugContent,

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            buttonStack.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 24),
            buttonStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            buttonStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            buttonStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -20),
            buttonStack.heightAnchor.constraint(equalToConstant: 44),
        ])

        loadHeaderImage()
    }

    private func loadHeaderImage() {
        guard let urlString = promptResponse.imageUrl, let url = URL(string: urlString) else { return }
        imageSession.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                PSLog.info("Header image not loaded, showing the dialog without it: \(error.localizedDescription)")
                return
            }
            guard let data, let image = UIImage(data: data) else {
                PSLog.info("Header image at \(url.absoluteString) was not a decodable image; showing the dialog without it.")
                return
            }
            DispatchQueue.main.async {
                self.headerImageView.image = image
                // Set image height proportional to width (max 160 pt).
                let cardWidth = self.view.bounds.width * 0.85
                let ratio = image.size.height / max(image.size.width, 1)
                self.imageHeightConstraint?.constant = min(cardWidth * ratio, 160)
                UIView.animate(withDuration: 0.2) {
                    self.view.layoutIfNeeded()
                }
            }
        }.resume()
    }

    // MARK: - Actions

    @objc private func didTapAccept() {
        // `SKStoreReviewController` is fired by PromptSurge in the `onAccept` handler, once, and
        // after this controller is off screen. It used to be requested here as well, which meant
        // two requests per confirmation.
        dismiss(animated: true, completion: onAccept)
    }

    @objc private func didTapDismiss() {
        dismiss(animated: true, completion: onDismiss)
    }

    // MARK: - Styling

    private func stylePrimaryButton(_ button: UIButton, title: String, fill: UIColor, label: UIColor) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(label, for: .normal)
        button.tintColor = label
        button.backgroundColor = fill
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.layer.cornerRadius = 10
        button.layer.masksToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func styleSecondaryButton(_ button: UIButton, title: String, label: UIColor) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(label, for: .normal)
        button.tintColor = label
        button.backgroundColor = .clear
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.layer.cornerRadius = 10
        button.layer.borderWidth = 1
        button.layer.borderColor = label.withAlphaComponent(0.4).cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func color(_ hex: String?) -> UIColor? {
        guard let hex = hex else { return nil }
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = UInt64(trimmed, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
