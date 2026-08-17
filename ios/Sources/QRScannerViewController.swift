import AVFoundation
import UIKit

/// Full-screen QR scanner for Mac pairing: point the phone at the code on
/// the Mac's Settings ▸ Mobile tab and the ws:// address lands without any
/// typing. The first QR that decodes wins — a haptic fires, the owner's
/// `onCode` runs, and the sheet dismisses itself. Camera-less environments
/// (the simulator) get an explanatory label instead of a dead preview.
final class QRScannerViewController: UIViewController {
    /// Called once with the decoded payload, before dismissal.
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = localized("Scan QR Code")
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
        )

        let output = AVCaptureMetadataOutput()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output)
        else {
            showUnavailableHint()
            return
        }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview

        // startRunning blocks while the pipeline spins up — off the main
        // thread, per the AVFoundation docs.
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    private func showUnavailableHint() {
        let label = UILabel()
        label.text = localized("Camera unavailable.\nType the address instead.")
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
    }
}

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from _: AVCaptureConnection
    ) {
        guard !handled,
              let qr = metadataObjects
              .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
              .first(where: { $0.type == .qr }),
              let value = qr.stringValue
        else { return }
        handled = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode?(value)
        dismiss(animated: true)
    }
}
