import XCTest

final class NanoCADUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSampleRendersElevenFacesAndFaceHitProducesAReferenceChip() throws {
        let app = launchFreshSample()
        defer { attachScreenshot(app, named: "sample-face-selection-final") }
        attachScreenshot(app, named: "sample-eleven-rendered-faces")

        app.buttons["mode-face"].tap()
        let visibleFaces = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cad.face."))
        XCTAssertTrue(visibleFaces.firstMatch.waitForExistence(timeout: 5))
        let face = try XCTUnwrap(visibleFaces.allElementsBoundByIndex.first { $0.isHittable },
                                 "The rendered sample must expose a visible, hit-tested face.")
        let reference = String(face.identifier.dropFirst("cad.face.".count))
        XCTAssertFalse(reference.isEmpty)

        // This is a real SceneKit tap at an AX target's projected triangle interior.
        // The inspector is deliberately not involved in selecting the face.
        face.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForValue("11 faces, 1 selected", of: viewport(in: app))
        waitForValue("Selected", of: app.buttons["cad.face.\(reference)"])
        XCTAssertTrue(app.staticTexts["#\(reference)"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Remove precision-bracket.step#\(reference)"].exists)
        attachScreenshot(app, named: "face-hit-selected-with-reference-chip")

        app.buttons["Remove precision-bracket.step#\(reference)"].tap()
        waitForValue("11 faces, 0 selected", of: viewport(in: app))
        waitForValue("Not selected", of: app.buttons["cad.face.\(reference)"])
        XCTAssertFalse(app.staticTexts["#\(reference)"].exists)
    }

    @MainActor
    func testTopologySelectsBodiesFacesEdgesAndPointsAndCanClearThem() {
        let app = launchFreshSample()
        defer { attachScreenshot(app, named: "topology-selection-final") }
        app.buttons["topology"].tap()
        XCTAssertTrue(app.navigationBars["Topology"].waitForExistence(timeout: 3))

        for (category, reference) in [("Bodies", "o1"), ("Faces", "o1.f1"),
                                       ("Edges", "o1.e1"), ("Points", "o1.v1")] {
            app.segmentedControls.buttons[category].tap()
            let row = app.buttons["topology-\(reference)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            if !row.isHittable { app.swipeUp() }
            row.tap()
            waitForValue("Selected", of: row)
        }
        attachScreenshot(app, named: "topology-point-selected")
        app.navigationBars["Topology"].buttons["Done"].tap()
        waitForValue("11 faces, 4 selected", of: viewport(in: app))
        for reference in ["o1", "o1.f1", "o1.e1", "o1.v1"] {
            XCTAssertTrue(app.buttons["Remove precision-bracket.step#\(reference)"].exists,
                          "Every selected topology kind must reach the composer.")
        }
        attachScreenshot(app, named: "topology-four-references-in-composer")

        app.buttons["topology"].tap()
        app.navigationBars["Topology"].buttons["Clear"].tap()
        XCTAssertFalse(app.navigationBars["Topology"].buttons["Clear"].isEnabled)
        app.navigationBars["Topology"].buttons["Done"].tap()
        waitForValue("11 faces, 0 selected", of: viewport(in: app))
        XCTAssertFalse(app.scrollViews["reference-chips"].exists)
    }

    @MainActor
    func testRealPencilStrokeAndMarkupSurviveRelaunch() {
        let app = launchFreshSample()
        defer { attachScreenshot(app, named: "markup-persistence-final") }
        XCTAssertFalse(app.staticTexts["Markup"].exists)
        app.buttons["mode-draw"].tap()
        let canvas = app.descendants(matching: .any).matching(identifier: "drawingCanvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["fit-model"].isEnabled, "Drawing must lock the annotation camera.")

        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.43))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.57))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.staticTexts["Markup"].waitForExistence(timeout: 5),
                      "A PencilKit stroke, not entering drawing mode, must create the chip.")
        attachScreenshot(app, named: "actual-pencilkit-stroke")
        app.buttons["mode-orbit"].tap()
        XCTAssertTrue(app.staticTexts["Markup"].exists)

        app.terminate()
        // Reset belongs only on the first launch. This launch must load the saved review.
        app.launchArguments = localeArguments
        app.launch()
        waitForValue("11 faces, 0 selected", of: viewport(in: app))
        XCTAssertTrue(app.staticTexts["Markup"].waitForExistence(timeout: 5))
        app.buttons["mode-draw"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        attachScreenshot(app, named: "restored-pencilkit-stroke-after-relaunch")
        app.buttons["Clear drawing"].tap()
        waitForAbsence(of: app.staticTexts["Markup"])
    }

    @MainActor
    func testComposerReplacementKeepsNativeCaretInTheMiddleOfTheText() {
        let app = launchFreshSample()
        defer { attachScreenshot(app, named: "native-composer-selection") }
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("small steel plate")
        waitForValue("small steel plate", of: composer)

        // UITextView has zero horizontal inset and an eight-point top inset.
        // Select the first word. Avoid measurement tokens, which iOS selects as a unit.
        composer.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 6, dy: 18)).doubleTap()
        let selectionMenu = expectation(for: NSPredicate { _, _ in
            app.menuItems["Cut"].exists || app.buttons["Cut"].exists
        }, evaluatedWith: nil)
        wait(for: [selectionMenu], timeout: 3)
        composer.typeText("large")
        waitForValue("large steel plate", of: composer)
        composer.typeText("r")
        waitForValue("larger steel plate", of: composer)
        XCTAssertTrue(app.buttons["send"].isEnabled)
    }

    @MainActor
    func testLongComposerExpandsWithoutLosingItsText() {
        let app = launchFreshSample()
        defer { attachScreenshot(app, named: "long-composer-final") }
        let composer = app.textViews["composer"]
        let prompt = (1...8).map { "Constraint \($0): 12 mm." }.joined(separator: "\n")
        composer.tap()
        composer.typeText(prompt)
        waitForValue(prompt, of: composer)
        let collapsedHeight = composer.frame.height
        let expand = app.buttons["Expand message editor"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        attachScreenshot(app, named: "long-composer-before-expansion")
        expand.tap()

        let expandedEditor = app.textViews["Ask Nanocodex"]
        XCTAssertTrue(app.navigationBars["Describe your idea"].waitForExistence(timeout: 3))
        waitForValue(prompt, of: expandedEditor)
        XCTAssertGreaterThan(expandedEditor.frame.height, collapsedHeight)
        XCTAssertTrue(app.navigationBars["Describe your idea"].buttons["Send"].isEnabled)
        attachScreenshot(app, named: "expanded-native-composer")
        app.navigationBars["Describe your idea"].buttons["Done"].tap()
        waitForValue(prompt, of: composer)
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
    }

    @MainActor
    func testConnectionRequiresAnAccountKeyWithoutPrefillingCredentials() {
        let app = launchFreshSample()
        defer { attachScreenshot(app, named: "connection-final") }
        let connection = app.buttons.matching(NSPredicate(format: "label IN %@", ["Connect Astra", "Astra connected"])).firstMatch
        connection.tap()
        XCTAssertTrue(app.navigationBars["Connect"].waitForExistence(timeout: 3))
        let key = app.secureTextFields["nanocodex-api-key"]
        XCTAssertTrue(key.exists, "The account key must use a native secure field.")
        let initialValue = key.value as? String ?? ""
        XCTAssertTrue(initialValue.isEmpty || initialValue == "Account API key",
                      "Opening connection settings must never expose a saved credential.")
        XCTAssertTrue(app.textFields["nanocodex-origin"].exists)
        XCTAssertFalse(app.buttons["connect-account"].isEnabled)
        XCTAssertFalse(app.staticTexts["connection-error"].exists)
        attachScreenshot(app, named: "connection-without-credentials")

        key.tap()
        key.typeText("   ")
        XCTAssertFalse(app.buttons["connect-account"].isEnabled, "Whitespace is not an account key.")
        app.navigationBars["Connect"].buttons["Cancel"].tap()
        XCTAssertTrue(viewport(in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(app.secureTextFields["nanocodex-api-key"].exists)
    }

    private var localeArguments: [String] {
        ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    @MainActor
    private func launchFreshSample() -> XCUIApplication {
        let app = XCUIApplication()
        // The app must remove only its persisted workspace when this explicit flag is present.
        app.launchArguments = ["--uitesting-reset"] + localeArguments
        app.launch()
        let summary = viewport(in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        waitForValue("11 faces, 0 selected", of: summary)
        XCTAssertEqual(summary.label, "precision-bracket.step, 3D model")
        XCTAssertGreaterThan(summary.frame.width, 100)
        XCTAssertGreaterThan(summary.frame.height, 100)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        return app
    }

    @MainActor
    private func viewport(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "cad.viewport.summary").firstMatch
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Expected \(value), received \(String(describing: element.value))", file: file, line: line)
    }

    @MainActor
    private func waitForAbsence(of element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
