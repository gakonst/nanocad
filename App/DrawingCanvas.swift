import PencilKit
import SwiftUI
import Observation

@MainActor @Observable
final class DrawingController {
    let canvas = PKCanvasView()
    var strokeCount = 0
    var referenceImage: UIImage? { didSet { referenceImageData = referenceImage?.pngData() } }
    private(set) var referenceImageData: Data?
    var color: UIColor = .systemOrange
    var isEraser = false
    var onChange: (() -> Void)?
    init() {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.tool = PKInkingTool(.pen, color: color, width: 4)
        canvas.accessibilityLabel = "Draw on model"
        canvas.accessibilityIdentifier = "drawingCanvas"
    }
    func setEraser(_ value: Bool) {
        isEraser = value
        canvas.tool = value ? PKEraserTool(.vector) : PKInkingTool(.pen, color: color, width: 4)
    }
    func setColor(_ value: UIColor) { color = value; setEraser(false) }
    func undo() { canvas.undoManager?.undo(); changed() }
    func redo() { canvas.undoManager?.redo(); changed() }
    func clear() { canvas.drawing = PKDrawing(); changed() }
    func load(_ data: Data?, image: Data? = nil) {
        referenceImage = image.flatMap(UIImage.init(data:))
        canvas.drawing = data.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        canvas.undoManager?.removeAllActions()
        strokeCount = canvas.drawing.strokes.count
    }
    func changed() { strokeCount = canvas.drawing.strokes.count; onChange?() }
    func composite(on fallback: UIImage) -> UIImage {
        let image = referenceImage ?? fallback
        let size = image.size
        let drawing = canvas.drawing.image(from: CGRect(origin: .zero, size: image.size), scale: image.scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
            drawing.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

struct DrawingReviewLayer: View {
    var controller: DrawingController
    var body: some View {
        GeometryReader { geometry in
            if let image = controller.referenceImage {
                let size = image.size
                let scale = min(geometry.size.width / max(1, size.width), geometry.size.height / max(1, size.height))
                ZStack {
                    Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                    DrawingCanvas(controller: controller, active: true)
                        .frame(width: size.width, height: size.height)
                }
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }.background(Color(red: 0.075, green: 0.10, blue: 0.135))
    }
}

struct DrawingCanvas: UIViewRepresentable {
    var controller: DrawingController
    var active: Bool
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeUIView(context: Context) -> PKCanvasView {
        controller.canvas.delegate = context.coordinator
        return controller.canvas
    }
    func updateUIView(_ view: PKCanvasView, context: Context) { view.isUserInteractionEnabled = active }
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let controller: DrawingController
        init(_ controller: DrawingController) { self.controller = controller }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { controller.changed() }
    }
}

struct DrawingTools: View {
    var controller: DrawingController
    var body: some View {
        HStack(spacing: 0) {
            Button { controller.setEraser(false) } label: { Image(systemName: "pencil.tip") }
                .tint(controller.isEraser ? .secondary : .orange)
                .accessibilityLabel("Pen")
            Button { controller.setEraser(true) } label: { Image(systemName: "eraser") }
                .tint(controller.isEraser ? .orange : .secondary)
                .accessibilityLabel("Eraser")
            Divider().frame(height: 22)
            ForEach([UIColor.systemOrange, .systemTeal], id: \.self) { color in
                Button { controller.setColor(color) } label: {
                    Circle().fill(Color(uiColor: color)).frame(width: 18, height: 18)
                        .padding(4).overlay(Circle().stroke(Color.primary.opacity(controller.color == color ? 0.8 : 0), lineWidth: 1))
                }.accessibilityLabel(color == .systemOrange ? "Orange ink" : color == .systemTeal ? "Teal ink" : "Pink ink")
            }
            Divider().frame(height: 22)
            Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }.accessibilityLabel("Undo drawing")
            Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward") }.accessibilityLabel("Redo drawing")
            Button(role: .destructive) { controller.clear() } label: { Image(systemName: "trash") }.accessibilityLabel("Clear drawing")
        }
        .buttonStyle(DrawingToolButtonStyle()).font(.body)
        .frame(minHeight: 44)
        .padding(.horizontal, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct DrawingToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.5 : 1)
    }
}
