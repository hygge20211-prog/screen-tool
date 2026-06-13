import UIKit

class ScreenshotCell: UICollectionViewCell {
    static let reuseId = "ScreenshotCell"

    private let imageView = UIImageView()
    private let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    private let dateLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        clipsToBounds = true
        backgroundColor = .secondarySystemGroupedBackground

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        dateLabel.font = .systemFont(ofSize: 9)
        dateLabel.textColor = .white
        dateLabel.textAlignment = .center
        dateLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dateLabel)

        checkmark.tintColor = .systemBlue
        checkmark.backgroundColor = .white
        checkmark.layer.cornerRadius = 11
        checkmark.clipsToBounds = true
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.isHidden = true
        contentView.addSubview(checkmark)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            dateLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dateLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dateLabel.heightAnchor.constraint(equalToConstant: 18),

            checkmark.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            checkmark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            checkmark.widthAnchor.constraint(equalToConstant: 22),
            checkmark.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with screenshot: Screenshot, selected: Bool) {
        imageView.image = FileStorageManager.shared.load(fileName: screenshot.fileName)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        dateLabel.text = formatter.string(from: screenshot.createdAt)
        checkmark.isHidden = !selected
        contentView.layer.borderWidth = selected ? 2.5 : 0
        contentView.layer.borderColor = UIColor.systemBlue.cgColor
    }
}
