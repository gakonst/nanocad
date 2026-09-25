import SwiftUI
import WebKit
import CryptoKit
import Foundation
import UIKit

struct NanocodexConnectGrant: Codable, Equatable, Sendable {
    var appID: String
    var appOrigin: String
    var grantID: String
    var agentID: String
    var token: String
    var expiresAt: Double
    var conversationID: String
    var toolCatalogDigest: String
    var sandboxExecution: Bool? = nil
}

enum ConnectConfiguration {
    static let appID = "com.gakonst.nanocad"
    static let appOrigin = "https://nanocodex.gakonst.workers.dev"
    static let apiOrigin = "https://nanocodex-connect-api.gakonst.workers.dev"
    static let documentURL = URL(string: appOrigin + "/nanocad-native/")!

    static func catalogDigest() throws -> String {
        guard let url = Bundle.main.url(forResource: "connect-tool-catalog", withExtension: "json"),
              let array = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else {
            throw ConnectError.invalidCatalog
        }
        let entries = try array.map { entry -> String in
            String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }.sorted()
        let data = Data(("nanocodex-app-tool-catalog-v1\0[" + entries.joined(separator: ",") + "]").utf8)
        return "0x" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ grant: NanocodexConnectGrant, requireActive: Bool = true) throws {
        guard grant.appID == appID, grant.appOrigin == appOrigin,
              grant.grantID.range(of: "^0x[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
              grant.agentID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              grant.token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              UUID(uuidString: grant.conversationID) != nil,
              grant.toolCatalogDigest == (try catalogDigest()), grant.expiresAt.isFinite else {
            throw ConnectError.invalidCallback
        }
        if requireActive && grant.expiresAt <= Date().timeIntervalSince1970 { throw ConnectError.expired }
    }
}

enum ConnectError: LocalizedError {
    case invalidCallback, invalidCatalog, expired, unavailable, executionApprovalRequired
    var errorDescription: String? {
        switch self {
        case .invalidCallback: "The Connect response could not be verified. Please connect again."
        case .invalidCatalog: "The CAD connection tools are missing from this build."
        case .expired: "Your Nanocodex connection has expired. Connect again to continue."
        case .executionApprovalRequired: "Reconnect Nanocodex to continue creating."
        case .unavailable: "The secure sign-in sheet could not open. Please try again."
        }
    }
}

/// Embeds the existing public Connect dialog exactly as the web demos do.
/// The bridge can only return this attempt's scoped grant from the bundled main document.
@MainActor
final class ConnectAuthorization: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    private var webView: WKWebView?
    private var dialogView: WKWebView?
    private var controller: UINavigationController?
    private var completion: CheckedContinuation<NanocodexCredentials, any Error>?
    private var attemptID: String?
    private var conversationID: String?

    func connect(conversationID requestedConversationID: String? = nil) async throws -> NanocodexCredentials {
        guard completion == nil,
              let resource = Bundle.main.url(forResource: "connect", withExtension: "js") else { throw ConnectError.unavailable }
        let script = try String(contentsOf: resource, encoding: .utf8)
        let attempt = UUID().uuidString.lowercased()
        let conversation = (requestedConversationID ?? UUID().uuidString).lowercased()
        guard UUID(uuidString: conversation) != nil else { throw ConnectError.invalidCallback }
        let values = try JSONSerialization.data(withJSONObject: ["attemptID": attempt, "conversationID": conversation])
        let bootstrap = "window.nanoCADConnectConfiguration=" + String(decoding: values, as: UTF8.self) + ";\n" + script
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation; attemptID = attempt; conversationID = conversation
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .default()
                config.preferences.javaScriptCanOpenWindowsAutomatically = true
                config.userContentController.add(self, name: "nanocadConnect")
                config.userContentController.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
                let web = WKWebView(frame: .zero, configuration: config)
                web.navigationDelegate = self; web.uiDelegate = self
                web.isOpaque = false; web.backgroundColor = .systemBackground
                let page = UIViewController()
                page.view = web; page.title = "Nanocodex Connect"
                page.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
                let controller = UINavigationController(rootViewController: page)
                controller.modalPresentationStyle = .pageSheet
                controller.presentationController?.delegate = self
                controller.sheetPresentationController?.detents = [.large()]
                self.webView = web; self.controller = controller
                guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
                      var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
                    finish(.failure(ConnectError.unavailable)); return
                }
                while let next = presenter.presentedViewController { presenter = next }
                presenter.present(controller, animated: true)
                web.loadHTMLString(Self.documentHTML, baseURL: ConnectConfiguration.documentURL)
                if Task.isCancelled { cancel() }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nanocadConnect", message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "nanocodex.gakonst.workers.dev",
              let body = message.body as? [String: Any], body["attemptID"] as? String == attemptID else { return }
        do {
            switch body["type"] as? String {
            case "connected":
                guard let value = body["credentials"] as? [String: Any],
                      value["origin"] as? String == ConnectConfiguration.apiOrigin,
                      value["conversationID"] as? String == conversationID else { throw ConnectError.invalidCallback }
                let grant = try JSONDecoder().decode(NanocodexConnectGrant.self, from: JSONSerialization.data(withJSONObject: value))
                finish(.success(try NanocodexCredentials(connect: grant)))
            case "error": finish(.failure(ConnectError.invalidCallback))
            case "ready": break
            default: throw ConnectError.invalidCallback
            }
        } catch { finish(.failure(error)) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The bundled SDK is the only main-frame document allowed to use the native bridge.
        if webView === self.webView, navigationAction.targetFrame?.isMainFrame == true {
            let url = navigationAction.request.url
            return url == ConnectConfiguration.documentURL || url?.absoluteString == "about:blank" ? .allow : .cancel
        } else { return .allow }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === self.webView, dialogView == nil, navigationAction.targetFrame == nil,
              let url = navigationAction.request.url, url.scheme == "https",
              url.host == "nanocodex.gakonst.workers.dev", ["/connect-dialog", "/connect-dialog/"].contains(url.path) else { return nil }
        // The SDK keeps window.opener for its standard postMessage protocol.
        // Only the bundled parent owns the native credential bridge.
        configuration.userContentController = WKUserContentController()
        let dialog = WKWebView(frame: .zero, configuration: configuration)
        dialog.navigationDelegate = self; dialog.uiDelegate = self
        dialog.isOpaque = false; dialog.backgroundColor = .systemBackground
        dialogView = dialog
        controller?.topViewController?.view = dialog
        return dialog
    }
    func webViewDidClose(_ webView: WKWebView) {
        guard webView === dialogView else { return }
        dialogView?.stopLoading(); dialogView = nil
        if let parent = self.webView { controller?.topViewController?.view = parent }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(ConnectError.unavailable))
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { cancel() }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<NanocodexCredentials, any Error>) {
        let pending = completion
        completion = nil; attemptID = nil; conversationID = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "nanocadConnect")
        webView?.stopLoading(); webView = nil
        dialogView?.stopLoading(); dialogView = nil
        controller?.dismiss(animated: true); controller = nil
        pending?.resume(with: result)
    }
    static let documentHTML = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><style>html,body{margin:0;background:#161616;color:#aaa;font:16px -apple-system;height:100%}p{text-align:center;padding-top:40vh}dialog{border-radius:24px}dialog::backdrop{background:#161616}iframe{border-radius:24px}</style></head><body><p>Opening Nanocodex Connect…</p></body></html>
    """
}
