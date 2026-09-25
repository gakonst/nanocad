import XCTest
import WebKit
@testable import NanoCAD

@MainActor
final class ConnectWebViewTests: XCTestCase, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var ready: XCTestExpectation?
    private var document: XCTestExpectation?
    private var frame: XCTestExpectation?
    private var web: WKWebView?
    private var dialog: WKWebView?

    func testPublicConnectDialogLoadsInNativeWebView() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.add(self, name: "nanocadConnect")
        let url = try XCTUnwrap(Bundle.main.url(forResource: "connect", withExtension: "js"))
        let script = "window.nanoCADConnectConfiguration={attemptID:'test-attempt',conversationID:'9d0e2677-2acd-4e77-af0b-adf848328e73'};\n" + (try String(contentsOf: url, encoding: .utf8))
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        ready = expectation(description: "public SDK starts from the bundled native document")
        document = expectation(description: "expected main document origin")
        frame = expectation(description: "existing hosted Connect dialog loads successfully")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        web = view; view.navigationDelegate = self; view.uiDelegate = self
        view.loadHTMLString(ConnectAuthorization.documentHTML, baseURL: ConnectConfiguration.documentURL)
        await fulfillment(of: [ready!, document!, frame!], timeout: 35)
        try await Task.sleep(for: .seconds(10))
        view.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "nanocadConnect")
        web = nil; dialog = nil
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "error" { XCTFail("Connect SDK failure: \(body["code"] ?? "unknown")"); return }
        guard body["type"] as? String == "ready" else { return }
        XCTAssertEqual(body["origin"] as? String, ConnectConfiguration.appOrigin)
        XCTAssertEqual(body["attemptID"] as? String, "test-attempt")
        XCTAssertTrue(message.frameInfo.isMainFrame)
        XCTAssertEqual(message.frameInfo.securityOrigin.protocol, "https")
        XCTAssertEqual(message.frameInfo.securityOrigin.host, "nanocodex.gakonst.workers.dev")
        ready?.fulfill(); ready = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        XCTAssertEqual(webView.url, ConnectConfiguration.documentURL)
        document?.fulfill(); document = nil
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        XCTAssertEqual(navigationAction.request.url?.host, "nanocodex.gakonst.workers.dev")
        XCTAssertTrue(["/connect-dialog", "/connect-dialog/"].contains(navigationAction.request.url?.path ?? ""))
        configuration.userContentController = WKUserContentController()
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.navigationDelegate = self
        dialog = child
        return child
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if webView === dialog, navigationResponse.isForMainFrame, navigationResponse.response.url?.path.hasPrefix("/connect-dialog") == true,
           let response = navigationResponse.response as? HTTPURLResponse {
            XCTAssertEqual(response.statusCode, 200)
            frame?.fulfill(); frame = nil
        }
        return .allow
    }
}
