import UIKit

// MARK: - CrosshairView

class CrosshairView: UIView {

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        isUserInteractionEnabled = false
        backgroundColor = .clear
        setupLayers()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupLayers() {
        let size: CGFloat = 60
        let center = CGPoint(x: size / 2, y: size / 2)
        let lineLength: CGFloat = 12
        let gap: CGFloat = 6

        let path = UIBezierPath()

        // Top line
        path.move(to: CGPoint(x: center.x, y: center.y - gap - lineLength))
        path.addLine(to: CGPoint(x: center.x, y: center.y - gap))
        // Bottom line
        path.move(to: CGPoint(x: center.x, y: center.y + gap))
        path.addLine(to: CGPoint(x: center.x, y: center.y + gap + lineLength))
        // Left line
        path.move(to: CGPoint(x: center.x - gap - lineLength, y: center.y))
        path.addLine(to: CGPoint(x: center.x - gap, y: center.y))
        // Right line
        path.move(to: CGPoint(x: center.x + gap, y: center.y))
        path.addLine(to: CGPoint(x: center.x + gap + lineLength, y: center.y))

        // Center dot
        path.append(UIBezierPath(
            arcCenter: center,
            radius: 2.5,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: true
        ))

        // Shadow layer
        let shadowLayer = CAShapeLayer()
        shadowLayer.path = path.cgPath
        shadowLayer.strokeColor = UIColor.black.withAlphaComponent(0.4).cgColor
        shadowLayer.fillColor = UIColor.black.withAlphaComponent(0.4).cgColor
        shadowLayer.lineWidth = 3.5
        shadowLayer.lineCap = .round
        layer.addSublayer(shadowLayer)

        // Main layer
        let shapeLayer = CAShapeLayer()
        shapeLayer.path = path.cgPath
        shapeLayer.strokeColor = UIColor.white.cgColor
        shapeLayer.fillColor = UIColor.white.cgColor
        shapeLayer.lineWidth = 2.0
        shapeLayer.lineCap = .round
        layer.addSublayer(shapeLayer)
    }
}

// MARK: - ScanProgressView

class ScanProgressView: UIView {

    private var bars: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 40, height: 24))
        isUserInteractionEnabled = false
        backgroundColor = .clear
        setupBars()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupBars() {
        let barWidth: CGFloat = 8
        let barSpacing: CGFloat = 4
        let heights: [CGFloat] = [8, 14, 20]

        for i in 0..<3 {
            let bar = UIView()
            bar.backgroundColor = UIColor.white.withAlphaComponent(0.3)
            bar.layer.cornerRadius = 2
            let x = CGFloat(i) * (barWidth + barSpacing)
            let h = heights[i]
            bar.frame = CGRect(x: x, y: bounds.height - h, width: barWidth, height: h)
            addSubview(bar)
            bars.append(bar)
        }
    }

    func updateProgress(meshCount: Int, vertexCount: Int = 0, isStable: Bool = false, isReady: Bool = false) {
        let bar1Active = meshCount >= 1
        let bar2Active = vertexCount >= 300
        let bar3Active = isStable && isReady

        let cyanColor = UIColor(red: 0.0, green: 0.85, blue: 0.85, alpha: 0.9)
        let greenColor = UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.9)
        let inactiveColor = UIColor.white.withAlphaComponent(0.3)

        let active = [bar1Active, bar2Active, bar3Active]
        let allReady = bar1Active && bar2Active && bar3Active

        for (i, bar) in bars.enumerated() {
            if active[i] {
                bar.backgroundColor = allReady ? greenColor : cyanColor
            } else {
                bar.backgroundColor = inactiveColor
            }
        }
    }
}

// MARK: - ScanStepIndicator

/// Two-step progress indicator: "Top" and "Side" with connecting line.
class ScanStepIndicator: UIView {

    private let step1Circle = UIView()
    private let step2Circle = UIView()
    private let step1Label = UILabel()
    private let step2Label = UILabel()
    private let connectorLine = UIView()
    private let circleSize: CGFloat = 24

    private let activeColor = UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)
    private let currentColor = UIColor(red: 0.0, green: 0.85, blue: 0.85, alpha: 1.0)
    private let inactiveColor = UIColor.white.withAlphaComponent(0.3)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Connector line between circles
        connectorLine.backgroundColor = inactiveColor
        connectorLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(connectorLine)

        // Step 1 circle
        step1Circle.backgroundColor = currentColor
        step1Circle.layer.cornerRadius = circleSize / 2
        step1Circle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(step1Circle)

        // Step 2 circle
        step2Circle.backgroundColor = inactiveColor
        step2Circle.layer.cornerRadius = circleSize / 2
        step2Circle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(step2Circle)

        // Labels
        for label in [step1Label, step2Label] {
            label.font = UIFont.systemFont(ofSize: 9, weight: .bold)
            label.textColor = .white
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        step1Label.text = "1"
        step2Label.text = "2"

        NSLayoutConstraint.activate([
            step1Circle.leadingAnchor.constraint(equalTo: leadingAnchor),
            step1Circle.centerYAnchor.constraint(equalTo: centerYAnchor),
            step1Circle.widthAnchor.constraint(equalToConstant: circleSize),
            step1Circle.heightAnchor.constraint(equalToConstant: circleSize),

            connectorLine.leadingAnchor.constraint(equalTo: step1Circle.trailingAnchor),
            connectorLine.trailingAnchor.constraint(equalTo: step2Circle.leadingAnchor),
            connectorLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            connectorLine.heightAnchor.constraint(equalToConstant: 2),
            connectorLine.widthAnchor.constraint(equalToConstant: 16),

            step2Circle.leadingAnchor.constraint(equalTo: connectorLine.trailingAnchor),
            step2Circle.centerYAnchor.constraint(equalTo: centerYAnchor),
            step2Circle.widthAnchor.constraint(equalToConstant: circleSize),
            step2Circle.heightAnchor.constraint(equalToConstant: circleSize),

            step1Label.centerXAnchor.constraint(equalTo: step1Circle.centerXAnchor),
            step1Label.centerYAnchor.constraint(equalTo: step1Circle.centerYAnchor),
            step2Label.centerXAnchor.constraint(equalTo: step2Circle.centerXAnchor),
            step2Label.centerYAnchor.constraint(equalTo: step2Circle.centerYAnchor),
        ])
    }

    func setStep(_ step: Int) {
        UIView.animate(withDuration: 0.25) {
            switch step {
            case 1:
                self.step1Circle.backgroundColor = self.currentColor
                self.step2Circle.backgroundColor = self.inactiveColor
                self.connectorLine.backgroundColor = self.inactiveColor
            case 2:
                self.step1Circle.backgroundColor = self.activeColor
                self.step2Circle.backgroundColor = self.currentColor
                self.connectorLine.backgroundColor = self.activeColor
            default:
                self.step1Circle.backgroundColor = self.activeColor
                self.step2Circle.backgroundColor = self.activeColor
                self.connectorLine.backgroundColor = self.activeColor
            }
        }
    }
}

