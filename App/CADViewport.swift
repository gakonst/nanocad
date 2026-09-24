import SwiftUI
import SceneKit
import simd
import Observation

/// CAD references in `selection` are document IDs, never tessellation triangle indices.
enum ViewportMode: String, CaseIterable, Identifiable, Sendable {
    case orbit, face, edge, vertex, draw
    var id: Self { self }
}

/// A portable annotation camera. Transform values are column-major, in document millimetres.
struct ViewportCameraState: Codable, Equatable, Sendable {
    var transform: [Float]
    var target: [Float]
    var orthographicScale: Double
}

/// Retain with `@State` (or `@StateObject`) in the editor. Snapshot contains the CAD view only;
/// the editor can composite its PencilKit drawing over this image.
@Observable @MainActor
final class ViewportController: ObservableObject {
    @ObservationIgnored fileprivate weak var coordinator: CADViewport.Coordinator?
    @ObservationIgnored private var pendingCamera: ViewportCameraState?

    var cameraState: ViewportCameraState? { coordinator?.captureCamera() ?? pendingCamera }

    func snapshot() -> UIImage? {
        guard let view = coordinator?.view, !view.bounds.isEmpty else { return nil }
        view.layoutIfNeeded()
        return view.snapshot()
    }

    func restoreCamera(_ state: ViewportCameraState) {
        pendingCamera = state
        coordinator?.restoreCamera(state)
    }

    /// Version 1 payload: version, 16 transform floats, 3 target floats, zoom.
    /// All 21 values are needed to restore screen-space PencilKit annotations.
    func captureCamera() -> [Float] {
        guard let state = cameraState else { return [] }
        return [1] + state.transform + state.target + [Float(state.orthographicScale)]
    }

    func restoreCamera(_ values: [Float]) {
        guard values.count == 21, values[0] == 1, values.allSatisfy(\.isFinite) else { return }
        restoreCamera(ViewportCameraState(transform: Array(values[1...16]),
                                          target: Array(values[17...19]),
                                          orthographicScale: Double(values[20])))
    }

    func fit() { coordinator?.fitToModel() }
    func fitToModel() { fit() }

    fileprivate func attach(_ coordinator: CADViewport.Coordinator) {
        self.coordinator = coordinator
        if let pendingCamera { coordinator.restoreCamera(pendingCamera) }
    }
}

/// One-finger orbit, two-finger pan, pinch zoom. A tap toggles the chosen entity.
/// `draw` disables every recognizer so a parent PencilKit overlay owns the touches.
struct CADViewport: UIViewRepresentable {
    let document: CADDocument
    var mode: ViewportMode
    @Binding var selection: Set<String>
    var resetToken: Int = 0
    var controller: ViewportController? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = CADSceneView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        context.coordinator.install(in: view)
        context.coordinator.update(self)
        controller?.attach(context.coordinator)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.update(self)
        if controller?.coordinator !== context.coordinator {
            controller?.attach(context.coordinator)
        }
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        (uiView as? CADSceneView)?.onLayout = nil
        uiView.scene = nil
        coordinator.view = nil
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        fileprivate weak var view: SCNView?
        private var parent: CADViewport
        private let scene = SCNScene()
        private let modelRoot = SCNNode()
        private let faceRoot = SCNNode()
        private let edgeRoot = SCNNode()
        private let vertexRoot = SCNNode()
        private let cameraNode = SCNNode()
        private var faceNodes: [String: SCNNode] = [:]
        private var edgeNodes: [String: SCNNode] = [:]
        private var vertexNodes: [String: SCNNode] = [:]
        private var faceSamples: [String: [SIMD3<Float>]] = [:]
        private var edges: [(id: String, points: [SIMD3<Float>])] = []
        private var vertices: [(id: String, point: SIMD3<Float>)] = []
        private var loadedRevision: String?
        private var loadedName: String?
        private var lastResetToken: Int?
        private var lastSelection: Set<String> = []
        private var lastMode: ViewportMode?
        private var recognizers: [UIGestureRecognizer] = []
        private var target = SIMD3<Float>(repeating: 0)
        private var modelCenter = SIMD3<Float>(repeating: 0)
        private var modelRadius: Float = 1
        private var distance: Float = 4
        private var yaw: Float = .pi / 4
        private var pitch: Float = 0.6154797
        private var needsInitialFit = true
        private var deferredCamera: ViewportCameraState?
        private var previousSize = CGSize.zero
        private var faceAccessibility: [CADReferenceAccessibilityElement] = []

        private static let faceMask = 1 << 1
        private static let edgeMask = 1 << 2
        private static let vertexMask = 1 << 3
        private let bodyColor = UIColor(red: 0.48, green: 0.61, blue: 0.70, alpha: 1)
        private let lineColor = UIColor(red: 0.08, green: 0.15, blue: 0.20, alpha: 1)
        private let selectedFaceColor = UIColor(red: 0.21, green: 0.85, blue: 0.65, alpha: 1)
        private let selectedLineColor = UIColor(red: 0.27, green: 0.95, blue: 0.95, alpha: 1)

        init(_ parent: CADViewport) { self.parent = parent }

        fileprivate func install(in view: CADSceneView) {
            self.view = view
            view.scene = scene
            view.backgroundColor = UIColor(red: 0.075, green: 0.10, blue: 0.135, alpha: 1)
            scene.background.contents = view.backgroundColor
            view.isOpaque = true
            view.antialiasingMode = .multisampling4X
            view.autoenablesDefaultLighting = false
            view.allowsCameraControl = false
            view.isPlaying = false
            view.rendersContinuously = false
            view.preferredFramesPerSecond = 60
            view.isJitteringEnabled = false
            view.accessibilityIdentifier = "cad.viewport"
            view.accessibilityLabel = "CAD model viewport"
            view.isAccessibilityElement = false
            view.accessibilityTraits = [.allowsDirectInteraction]
            view.onLayout = { [weak self] in self?.layoutChanged() }

            scene.rootNode.addChildNode(modelRoot)
            modelRoot.addChildNode(faceRoot)
            modelRoot.addChildNode(edgeRoot)
            modelRoot.addChildNode(vertexRoot)
            let camera = SCNCamera()
            camera.usesOrthographicProjection = true
            camera.projectionDirection = .vertical
            camera.wantsHDR = false
            camera.wantsExposureAdaptation = false
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)
            view.pointOfView = cameraNode

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.color = UIColor(red: 0.78, green: 0.86, blue: 1, alpha: 1)
            ambient.light?.intensity = 450
            scene.rootNode.addChildNode(ambient)
            addLight(euler: SCNVector3(-0.6, -0.55, 0), intensity: 1_050, color: .white)
            addLight(euler: SCNVector3(0.4, 2.5, 0), intensity: 500,
                     color: UIColor(red: 0.57, green: 0.75, blue: 1, alpha: 1))

            let orbit = UIPanGestureRecognizer(target: self, action: #selector(orbit(_:)))
            orbit.minimumNumberOfTouches = 1
            orbit.maximumNumberOfTouches = 1
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            tap.require(toFail: orbit)
            recognizers = [orbit, pan, pinch, tap]
            for recognizer in recognizers {
                recognizer.delegate = self
                // Pencil input belongs to the annotation overlay.
                recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                view.addGestureRecognizer(recognizer)
            }
        }

        private func addLight(euler: SCNVector3, intensity: CGFloat, color: UIColor) {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = .directional
            node.light?.intensity = intensity
            node.light?.color = color
            node.eulerAngles = euler
            // Camera-relative illumination makes the model readable while orbiting.
            cameraNode.addChildNode(node)
        }

        func update(_ parent: CADViewport) {
            self.parent = parent
            let changedDocument = loadedRevision != parent.document.revision || loadedName != parent.document.name
            if changedDocument {
                loadedRevision = parent.document.revision
                loadedName = parent.document.name
                rebuildModel(parent.document)
            }
            let changedMode = lastMode != parent.mode
            if changedMode {
                lastMode = parent.mode
                for recognizer in recognizers { recognizer.isEnabled = parent.mode != .draw }
                vertexRoot.isHidden = parent.mode != .vertex && vertexNodes.keys.allSatisfy { !parent.selection.contains($0) }
                view?.accessibilityHint = modeAccessibilityHint
                refreshAccessibility()
            }
            if changedDocument || changedMode || lastSelection != parent.selection {
                lastSelection = parent.selection
                applySelection()
            }
            if lastResetToken != parent.resetToken, parent.mode != .draw {
                lastResetToken = parent.resetToken
                fitToModel()
            }
        }

        private var modeAccessibilityHint: String {
            switch parent.mode {
            case .draw: "Drawing mode. The camera is locked."
            case .orbit: "Drag to orbit. Pinch to zoom. Drag with two fingers to pan."
            case .face: "Tap a face to toggle selection. Drag to orbit."
            case .edge: "Tap near an edge to toggle selection. Drag to orbit."
            case .vertex: "Tap near a vertex to toggle selection. Drag to orbit."
            }
        }

        private func rebuildModel(_ document: CADDocument) {
            for root in [faceRoot, edgeRoot, vertexRoot] {
                root.childNodes.forEach { $0.removeFromParentNode() }
            }
            faceNodes.removeAll(keepingCapacity: true)
            edgeNodes.removeAll(keepingCapacity: true)
            vertexNodes.removeAll(keepingCapacity: true)
            faceSamples.removeAll(keepingCapacity: true)
            edges.removeAll(keepingCapacity: true)
            vertices.removeAll(keepingCapacity: true)
            var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            var hasBounds = false
            func include(_ point: SIMD3<Float>) {
                minimum = simd_min(minimum, point)
                maximum = simd_max(maximum, point)
                hasBounds = true
            }

            for face in document.faces {
                let points = Self.points(face.positions)
                guard !points.isEmpty, face.positions.count % 3 == 0,
                      points.count == face.positions.count / 3,
                      !face.indices.isEmpty, face.indices.count % 3 == 0,
                      face.indices.allSatisfy({ Int($0) < points.count }) else { continue }
                let positions = SCNGeometrySource(vertices: points.map(Self.vector))
                var sources = [positions]
                let normals = Self.points(face.normals)
                if normals.count == points.count {
                    sources.append(SCNGeometrySource(normals: normals.map(Self.vector)))
                }
                let element = SCNGeometryElement(indices: face.indices, primitiveType: .triangles)
                let geometry = SCNGeometry(sources: sources, elements: [element])
                let material = SCNMaterial()
                material.lightingModel = .blinn
                material.diffuse.contents = bodyColor
                material.specular.contents = UIColor(white: 0.85, alpha: 1)
                material.shininess = 0.42
                material.isDoubleSided = true
                geometry.materials = [material]
                let node = SCNNode(geometry: geometry)
                node.name = face.id
                node.categoryBitMask = Self.faceMask
                faceRoot.addChildNode(node)
                faceNodes[face.id] = node
                points.forEach(include)
                // Use actual triangle interiors for accessible targets, so annular or
                // concave faces do not put their activation point inside empty space.
                let samples = stride(from: 0, to: face.indices.count, by: 3).map { index in
                    let a = points[Int(face.indices[index])]
                    let b = points[Int(face.indices[index + 1])]
                    let c = points[Int(face.indices[index + 2])]
                    return (area: simd_length_squared(simd_cross(b - a, c - a)), center: (a + b + c) / 3)
                }
                faceSamples[face.id] = samples.sorted { $0.area > $1.area }.prefix(12).map(\.center)
            }
            for edge in document.edges {
                let points = Self.points(edge.points)
                guard points.count >= 2, points.count * 3 == edge.points.count else { continue }
                var indices: [UInt32] = []
                indices.reserveCapacity((points.count - 1) * 2)
                for index in 0..<(points.count - 1) { indices.append(contentsOf: [UInt32(index), UInt32(index + 1)]) }
                let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points.map(Self.vector))],
                                           elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
                geometry.materials = [lineMaterial(lineColor)]
                let node = SCNNode(geometry: geometry)
                node.name = edge.id
                node.categoryBitMask = Self.edgeMask
                node.renderingOrder = 1
                edgeRoot.addChildNode(node)
                edgeNodes[edge.id] = node
                edges.append((edge.id, points))
                points.forEach(include)
            }
            for vertex in document.vertices {
                guard let point = Self.points(vertex.position).first, vertex.position.count == 3 else { continue }
                vertices.append((vertex.id, point))
                include(point)
            }
            if hasBounds {
                modelCenter = minimum + (maximum - minimum) / 2
                modelRadius = max(simd_length(maximum - minimum) / 2, 0.01)
            } else {
                // An empty document stays empty; these values only provide a valid camera.
                modelCenter = .zero
                modelRadius = 1
            }
            for vertex in vertices {
                let geometry = SCNSphere(radius: CGFloat(modelRadius * 0.009))
                geometry.segmentCount = 8
                geometry.materials = [lineMaterial(selectedLineColor)]
                let node = SCNNode(geometry: geometry)
                node.simdPosition = vertex.point
                node.name = vertex.id
                node.categoryBitMask = Self.vertexMask
                vertexRoot.addChildNode(node)
                vertexNodes[vertex.id] = node
            }
            needsInitialFit = true
            if parent.mode != .draw { fitToModel() }
            refreshAccessibility()
        }

        private func lineMaterial(_ color: UIColor) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.readsFromDepthBuffer = true
            material.writesToDepthBuffer = false
            return material
        }

        private func applySelection() {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            let selectedPartFaces = Set(parent.document.parts
                .filter { parent.selection.contains($0.id) }
                .flatMap(\.faceIDs))
            for (id, node) in faceNodes {
                let selected = parent.selection.contains(id) || selectedPartFaces.contains(id)
                node.geometry?.firstMaterial?.diffuse.contents = selected ? selectedFaceColor : bodyColor
                node.geometry?.firstMaterial?.emission.contents = selected ? UIColor(red: 0.02, green: 0.08, blue: 0.06, alpha: 1) : UIColor.black
            }
            for (id, node) in edgeNodes {
                let selected = parent.selection.contains(id)
                node.geometry?.firstMaterial?.diffuse.contents = selected ? selectedLineColor : lineColor
            }
            for (id, node) in vertexNodes {
                let selected = parent.selection.contains(id)
                node.isHidden = parent.mode != .vertex && !selected
                node.geometry?.firstMaterial?.diffuse.contents = selected ? selectedLineColor : bodyColor
                node.scale = SCNVector3(selected ? 1.6 : 1, selected ? 1.6 : 1, selected ? 1.6 : 1)
            }
            vertexRoot.isHidden = parent.mode != .vertex && vertexNodes.keys.allSatisfy { !parent.selection.contains($0) }
            SCNTransaction.commit()
            refreshAccessibility()
            view?.setNeedsDisplay()
        }

        fileprivate func fitToModel() {
            guard parent.mode != .draw, let view, view.bounds.width > 0, view.bounds.height > 0 else {
                needsInitialFit = true
                return
            }
            target = modelCenter
            yaw = .pi / 4
            pitch = 0.6154797 // Equal projected X, Y, and Z axes.
            distance = modelRadius * 4
            let aspect = Float(view.bounds.width / view.bounds.height)
            cameraNode.camera?.orthographicScale = Double(modelRadius * 1.18 / min(aspect, 1))
            cameraNode.camera?.zNear = Double(max(modelRadius * 0.001, 0.0001))
            cameraNode.camera?.zFar = Double(modelRadius * 12)
            needsInitialFit = false
            updateCamera()
        }

        fileprivate func captureCamera() -> ViewportCameraState? {
            guard !needsInitialFit, let camera = cameraNode.camera else { return nil }
            let m = cameraNode.simdTransform
            return ViewportCameraState(transform: [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap {
                [$0.x, $0.y, $0.z, $0.w]
            }, target: [target.x, target.y, target.z], orthographicScale: camera.orthographicScale)
        }

        fileprivate func restoreCamera(_ state: ViewportCameraState) {
            guard state.transform.count == 16, state.target.count == 3,
                  state.transform.allSatisfy(\.isFinite), state.target.allSatisfy(\.isFinite),
                  state.orthographicScale.isFinite, state.orthographicScale > 0 else { return }
            guard let view, !view.bounds.isEmpty else { deferredCamera = state; return }
            let values = state.transform
            let columns = stride(from: 0, to: 16, by: 4).map {
                SIMD4<Float>(values[$0], values[$0 + 1], values[$0 + 2], values[$0 + 3])
            }
            let matrix = simd_float4x4(columns: (columns[0], columns[1], columns[2], columns[3]))
            guard abs(simd_determinant(matrix)) > 0.00001 else { return }
            target = SIMD3<Float>(state.target[0], state.target[1], state.target[2])
            cameraNode.simdTransform = matrix
            let offset = cameraNode.simdPosition - target
            distance = max(simd_length(offset), modelRadius * 0.01)
            yaw = atan2(offset.x, -offset.y)
            pitch = asin(min(max(offset.z / distance, -1), 1))
            cameraNode.camera?.orthographicScale = state.orthographicScale
            cameraNode.camera?.zNear = Double(max(modelRadius * 0.001, 0.0001))
            cameraNode.camera?.zFar = Double(max(distance + modelRadius * 4, modelRadius * 12))
            needsInitialFit = false
            deferredCamera = nil
            cameraDidChange()
        }

        private func layoutChanged() {
            guard let view, view.bounds.size != previousSize, !view.bounds.isEmpty else { return }
            previousSize = view.bounds.size
            if needsInitialFit { fitToModel() }
            if let deferredCamera { restoreCamera(deferredCamera) }
            refreshAccessibility()
            view.setNeedsDisplay()
        }

        private func updateCamera() {
            cameraNode.simdPosition = target + distance * SIMD3<Float>(cos(pitch) * sin(yaw), -cos(pitch) * cos(yaw), sin(pitch))
            cameraNode.look(at: Self.vector(target), up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
            cameraDidChange()
        }

        private func cameraDidChange() {
            updateVertexSizes()
            refreshAccessibility()
            view?.setNeedsDisplay()
        }

        private func updateVertexSizes() {
            guard let view, view.bounds.height > 0, let camera = cameraNode.camera else { return }
            // Keep vertex handles finger-readable while zooming; geometry stays in world mm.
            let radius = CGFloat(camera.orthographicScale * 2 / Double(view.bounds.height) * 3.2)
            for node in vertexNodes.values { (node.geometry as? SCNSphere)?.radius = radius }
        }

        @objc private func orbit(_ recognizer: UIPanGestureRecognizer) {
            guard parent.mode != .draw, let view else { return }
            let delta = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            yaw -= Float(delta.x) * 0.008
            pitch = min(max(pitch + Float(delta.y) * 0.008, -.pi / 2 + 0.02), .pi / 2 - 0.02)
            updateCamera()
        }

        @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
            guard parent.mode != .draw, let view, view.bounds.height > 0, let camera = cameraNode.camera else { return }
            let delta = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            let matrix = cameraNode.simdTransform
            let right = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
            let up = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
            let scale = Float(camera.orthographicScale * 2 / Double(view.bounds.height))
            target -= right * Float(delta.x) * scale
            target += up * Float(delta.y) * scale
            updateCamera()
        }

        @objc private func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard parent.mode != .draw, let camera = cameraNode.camera, recognizer.scale > 0 else { return }
            let proposed = camera.orthographicScale / Double(recognizer.scale)
            camera.orthographicScale = min(max(proposed, Double(modelRadius) * 0.005), Double(modelRadius) * 50)
            recognizer.scale = 1
            cameraDidChange()
        }

        @objc private func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view, recognizer.state == .ended else { return }
            let point = recognizer.location(in: view)
            let id: String?
            switch parent.mode {
            case .face: id = faceHit(at: point)?.node.name
            case .edge: id = pickEdge(at: point)
            case .vertex: id = pickVertex(at: point)
            case .orbit, .draw: id = nil
            }
            if let id { toggle(id) }
        }

        private func toggle(_ id: String) {
            guard parent.mode != .draw else { return }
            var selection = parent.selection
            if !selection.insert(id).inserted { selection.remove(id) }
            parent.selection = selection
            lastSelection = selection
            applySelection()
            UISelectionFeedbackGenerator().selectionChanged()
        }

        private func faceHit(at point: CGPoint) -> SCNHitTestResult? {
            view?.hitTest(point, options: [
                .categoryBitMask: Self.faceMask,
                .backFaceCulling: false,
                .searchMode: SCNHitTestSearchMode.closest.rawValue
            ]).first
        }

        private func projected(_ point: SIMD3<Float>) -> SCNVector3? {
            guard let result = view?.projectPoint(Self.vector(point)),
                  result.x.isFinite, result.y.isFinite, result.z.isFinite,
                  result.z >= 0, result.z <= 1 else { return nil }
            return result
        }

        /// Only pick candidates at the visible surface. Test at each projected candidate,
        /// not at the finger position, which can fall outside a silhouette.
        private func visible(_ world: SIMD3<Float>, projected: SCNVector3) -> Bool {
            let screen = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
            guard let hit = faceHit(at: screen) else { return true }
            let hitPoint = SIMD3<Float>(hit.worldCoordinates.x, hit.worldCoordinates.y, hit.worldCoordinates.z)
            let forward = simd_normalize(target - cameraNode.simdPosition)
            let separation = simd_dot(world - hitPoint, forward)
            return separation <= modelRadius * 0.003
        }

        private func pickEdge(at point: CGPoint) -> String? {
            var candidates: [(id: String, distance: CGFloat, world: SIMD3<Float>, projected: SCNVector3)] = []
            for edge in edges {
                var best: (CGFloat, SIMD3<Float>, SCNVector3)?
                for index in 0..<(edge.points.count - 1) {
                    let a = edge.points[index], b = edge.points[index + 1]
                    guard let pa = projected(a), let pb = projected(b) else { continue }
                    let start = CGPoint(x: CGFloat(pa.x), y: CGFloat(pa.y))
                    let end = CGPoint(x: CGFloat(pb.x), y: CGFloat(pb.y))
                    let dx = end.x - start.x, dy = end.y - start.y
                    let denominator = dx * dx + dy * dy
                    let t = denominator > 0 ? min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator, 0), 1) : 0
                    let distance = hypot(point.x - (start.x + dx * t), point.y - (start.y + dy * t))
                    guard distance <= 18, best == nil || distance < best!.0 else { continue }
                    let world = a + (b - a) * Float(t)
                    let projection = SCNVector3(pa.x + (pb.x - pa.x) * Float(t), pa.y + (pb.y - pa.y) * Float(t), pa.z + (pb.z - pa.z) * Float(t))
                    best = (distance, world, projection)
                }
                if let best { candidates.append((edge.id, best.0, best.1, best.2)) }
            }
            return candidates.sorted { $0.distance < $1.distance }.first { visible($0.world, projected: $0.projected) }?.id
        }

        private func pickVertex(at point: CGPoint) -> String? {
            let candidates = vertices.compactMap { vertex -> (id: String, distance: CGFloat, world: SIMD3<Float>, projected: SCNVector3)? in
                guard let projection = projected(vertex.point) else { return nil }
                let distance = hypot(point.x - CGFloat(projection.x), point.y - CGFloat(projection.y))
                guard distance <= 24 else { return nil }
                return (vertex.id, distance, vertex.point, projection)
            }
            return candidates.sorted { $0.distance < $1.distance }.first { visible($0.world, projected: $0.projected) }?.id
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Two-finger pan and pinch can run together; single-finger orbit stays exclusive.
            let pan = (gestureRecognizer as? UIPanGestureRecognizer) ?? (otherGestureRecognizer as? UIPanGestureRecognizer)
            let hasPinch = gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
            return hasPinch && pan?.minimumNumberOfTouches == 2
        }

        private func refreshAccessibility() {
            guard let view, !view.bounds.isEmpty else { return }
            let summary = UIAccessibilityElement(accessibilityContainer: view)
            summary.accessibilityIdentifier = "cad.viewport.summary"
            summary.accessibilityLabel = "\(parent.document.name), 3D model"
            summary.accessibilityValue = "\(faceNodes.count) faces, \(parent.selection.count) selected"
            summary.accessibilityHint = modeAccessibilityHint
            summary.accessibilityFrameInContainerSpace = view.bounds
            summary.accessibilityTraits = [.image, .allowsDirectInteraction]
            var elements: [Any] = [summary]
            faceAccessibility.removeAll(keepingCapacity: true)
            if parent.mode == .face {
                for face in parent.document.faces {
                    let point = faceSamples[face.id]?.lazy.compactMap { sample -> CGPoint? in
                        guard let projection = self.projected(sample) else { return nil }
                        let point = CGPoint(x: CGFloat(projection.x), y: CGFloat(projection.y))
                        guard view.bounds.contains(point), self.faceHit(at: point)?.node.name == face.id else { return nil }
                        return point
                    }.first
                    guard let point else { continue }
                    let element = CADReferenceAccessibilityElement(accessibilityContainer: view)
                    element.accessibilityIdentifier = "cad.face.\(face.id)"
                    element.accessibilityLabel = "Face \(face.id)"
                    element.accessibilityValue = parent.selection.contains(face.id) ? "Selected" : "Not selected"
                    element.accessibilityHint = "Double tap to toggle selection"
                    element.accessibilityTraits = parent.selection.contains(face.id) ? [.button, .selected] : [.button]
                    element.accessibilityFrameInContainerSpace = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44).intersection(view.bounds)
                    element.activate = { [weak self] in self?.toggle(face.id) }
                    faceAccessibility.append(element)
                    elements.append(element)
                }
            }
            view.accessibilityElements = elements
        }

        private static func points(_ packed: [Float]) -> [SIMD3<Float>] {
            guard packed.count % 3 == 0 else { return [] }
            return stride(from: 0, to: packed.count, by: 3).compactMap { index in
                let point = SIMD3<Float>(packed[index], packed[index + 1], packed[index + 2])
                return point.x.isFinite && point.y.isFinite && point.z.isFinite ? point : nil
            }
        }

        private static func vector(_ point: SIMD3<Float>) -> SCNVector3 { SCNVector3(point.x, point.y, point.z) }
    }
}

@MainActor
private final class CADSceneView: SCNView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

@MainActor
private final class CADReferenceAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool {
        guard let activate else { return false }
        activate()
        return true
    }
}
