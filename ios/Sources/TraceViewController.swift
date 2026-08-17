import UIKit
import WebKit

/// A full-screen sheet that renders an agent session's transcript as an in-app
/// HTML trace — the dashboard-over-conversation the Mac's Info pane shows,
/// rendered on the Mac (`SessionTraceRenderer`) and handed over the companion
/// socket. The phone only displays it: a `WKWebView`, a spinner until the
/// document lands, and a Done button.
final class TraceViewController: UIViewController {
    private let webView = WKWebView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = localized("Trajectory")
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismissSelf)
        )

        // The trace paints its own themed background; let it own the whole page
        // rather than flashing the system background behind a transparent body.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()
    }

    /// Load the rendered trace document once it arrives from the Mac.
    func load(html: String) {
        spinner.stopAnimating()
        webView.loadHTMLString(html, baseURL: nil)
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }
}
