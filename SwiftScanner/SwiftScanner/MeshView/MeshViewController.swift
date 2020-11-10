//
//    This file is a Swift port of the Structure SDK sample app "Scanner".
//    Copyright © 2016 Occipital, Inc. All rights reserved.
//    http://structure.io
//
//  MeshViewController.swift
//
//  Ported by Christopher Worley on 8/20/16.
//
//  Ported to Swift 5 by Windmolders Joris on 03/06/2020.
//  - Using colorized view only
//  - Removed mail send functionality
//  - Implemented segues
//


import Foundation
import MessageUI
import os.log

open class MeshViewController: UIViewController, UIGestureRecognizerDelegate {
    
    weak var scanView : ScanViewDelegate?
    weak var scanBuffer : ScanBufferDelegate?
    weak var colorizer : ColorizeDelegate?
    
    // force the view to redraw.
    var needsDisplay: Bool = false
    var colorEnabled: Bool = false
    fileprivate var _mesh: STMesh? = nil

    deinit {
        os_log(.debug, log: OSLog.meshView, "MeshViewController deinit called")
    }
    
    var mesh: STMesh? {
        get {
            return self._mesh
        }
        set {
            if let _ = self._mesh {
                os_log(.debug, log: OSLog.meshView, "cleaned up the mesh")
                _mesh = nil
            }
            
            self._mesh = newValue
            
            guard let mesh = newValue else { return }
            
            os_log(.debug, log: OSLog.meshView, "Setting the mesh")
            
            self.renderer.upload(mesh, with: self.rendererContext)
            self.trySwitchToColorRenderingMode()
            self.needsDisplay = true
        }
    }
    
    var projectionMatrix: GLKMatrix4 = GLKMatrix4Identity {
        didSet {
            setCameraProjectionMatrix(projectionMatrix)
        }
    }
    
    var volumeCenter = GLKVector3Make(0,0,0) {
        didSet {
            resetMeshCenter(volumeCenter)
        }
    }
    
    @IBOutlet weak var eview: EAGLView!
    @IBOutlet weak var meshViewerMessageLabel: UILabel!
    
    var displayLink: CADisplayLink?
    var renderer: MeshRenderer!
    var viewpointController: ViewpointController!
    var viewport = [GLfloat](repeating: 0, count: 4)
    var modelViewMatrixBeforeUserInteractions: GLKMatrix4?
    var projectionMatrixBeforeUserInteractions: GLKMatrix4?
    
    var rendererContext: RendererContext = .unknown
    
    
    // MARK: - Lifecycle Methods

    override open func viewDidLoad() {
        super.viewDidLoad()

        self.renderer = MeshRenderer()
        self.viewpointController = ViewpointController(
            screenSizeX: Float(self.view.frame.size.width)
            , screenSizeY: Float(self.view.frame.size.height)
        )
    }

    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        if let displayLink = self.displayLink {
            displayLink.invalidate()
            self.displayLink = nil
        }
        
        let displayLink = CADisplayLink(target: self, selector: #selector(MeshViewController.draw))
        displayLink.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
        self.displayLink = displayLink
        
        self.viewpointController.reset()
        self.viewpointController.initRotation(
            xAngleDegrees: InitialViewModelRotation.xAngleDegrees
            , yAngleDegrees: InitialViewModelRotation.yAngleDegrees
        )
    }
    
    // Make sure the status bar is disabled (iOS 7+)
    override open var prefersStatusBarHidden : Bool {
        return true
    }

    override open func didReceiveMemoryWarning () {}
    
    
    /// 画面遷移前（ViewDidLoadより前）にScanViewControllerから呼ばれる
    /// - Parameter context: <#context description#>
    func setup(context: EAGLContext, with mesh: STMesh) {

        (self.view as! EAGLView).context = context
        EAGLContext.setCurrent(context)

        self.rendererContext = self.renderer.initialize()

        // TODO
//        self.eview.setFramebuffer()
        
        let framebufferSize: CGSize = self.eview.getFramebufferSize()
        
        // The iPad's diplay conveniently has a 4:3 aspect ratio just like our video feed.
        // Some iOS devices need to render to only a portion of the screen so that we don't distort
        // our RGB image. Alternatively, you could enlarge the viewport (losing visual information),
        // but fill the whole screen.
        
        // if you want to keep aspect ratio
        //        var imageAspectRatio: CGFloat = 1
        //
        //        if abs(framebufferSize.width / framebufferSize.height - 640.0 / 480.0) > 1e-3 {
        //            imageAspectRatio = 480.0 / 640.0
        //        }
        //
        //        viewport[0] = Float(framebufferSize.width - framebufferSize.width * imageAspectRatio) / 2
        //        viewport[1] = 0
        //        viewport[2] = Float(framebufferSize.width * imageAspectRatio)
        //        viewport[3] = Float(framebufferSize.height)
        
        // if you want full screen
        self.viewport[0] = 0
        self.viewport[1] = 0
        self.viewport[2] = Float(framebufferSize.width)
        self.viewport[3] = Float(framebufferSize.height)
        
        self.mesh = mesh
    }
    
    // MARK: - User Actions
    
    @IBAction func backButtonDidPush(_ sender: UIButton) {
        os_log("Preparing for unwindMeshToScanView", log: OSLog.meshView, type: .debug)
        self.cleanup()
        
        self.dismiss(animated: true, completion: nil)
    }
    
    
    @IBAction func resetButtonDidPush(_ sender: UIButton) {
        self.viewpointController.resetView()
    }
    
    @IBAction func acceptButtonDidPush(_ sender: Any) {
        os_log("Preparing for unwindMeshToMainView", log: OSLog.meshView, type: .debug)
        if let mesh = self.mesh {
            self.scanBuffer?.addScan(mesh)
        }
        self.cleanup()
        self.scanView?.cleanup()
        
        self.presentingViewController?.dismiss(animated: true, completion: nil)
    }
    
    
    // MARK: - Private Methods
    private func cleanup() {
        self.colorizer?.stopColorizing()
                
        self.renderer.terminate(with: self.rendererContext)
        self.renderer = nil
        
        self.viewpointController = nil
        
        self.displayLink?.invalidate()
        self.displayLink = nil
        
        self.mesh = nil

        self.eview.context = nil

        os_log(.debug, log: OSLog.meshView, "Mesh view dismissed")
    }
    
    //MARK: - MeshViewer setup when loading the mesh
    
    func setCameraProjectionMatrix (_ projection: GLKMatrix4) {
        self.viewpointController.setCameraProjection(projection)
        self.projectionMatrixBeforeUserInteractions = projection
    }
    
    func resetMeshCenter (_ center: GLKVector3) {
        self.viewpointController.reset()
        self.viewpointController.initRotation(
            xAngleDegrees: InitialViewModelRotation.xAngleDegrees
            , yAngleDegrees: InitialViewModelRotation.yAngleDegrees
        )
        self.viewpointController.setMeshCenter(center)
        self.modelViewMatrixBeforeUserInteractions = self.viewpointController.currentGLModelViewMatrix()
    }

    // MARK: Rendering
    
    @objc func draw () {
        // TODO
//        self.eview.setFramebuffer()
        
        glViewport(
            GLint(self.viewport[0])
            , GLint(self.viewport[1])
            , GLint(self.viewport[2])
            , GLint(self.viewport[3])
        )
        
        let viewpointChanged = self.viewpointController.update()
        
        // If nothing changed, do not waste time and resources rendering.
        if !needsDisplay && !viewpointChanged { return }
        
        var currentModelView = self.viewpointController.currentGLModelViewMatrix()
        var currentProjection = self.viewpointController.currentGLProjectionMatrix()
        
        if let renderer = self.renderer {
            renderer.clear()
            withUnsafePointer(to: &currentProjection) { (one) -> () in
                withUnsafePointer(to: &currentModelView, { (two) -> () in
                    
                    one.withMemoryRebound(to: GLfloat.self, capacity: 16, { (onePtr) -> () in
                        two.withMemoryRebound(to: GLfloat.self, capacity: 16, { (twoPtr) -> () in
                            
                            renderer.render(
                                with: self.rendererContext
                                , projectionMatrix: onePtr
                                , modelViewMatrix: twoPtr
                            )
                        })
                    })
                })
            }
        }

        self.needsDisplay = false
        
        let _ = self.eview.presentFramebuffer()
    }
    
    // MARK: - Touch & Gesture Control
    
    @IBAction func tapGesture(_ sender: UITapGestureRecognizer) {
        if sender.state == .ended {
            self.viewpointController.onTouchBegan()
        }
    }
    
    @IBAction func pinchScaleGesture(_ sender: UIPinchGestureRecognizer) {

        // Forward to the ViewpointController.
        if sender.state == .began {
            self.viewpointController.onPinchGestureBegan(Float(sender.scale))
        } else if sender.state == .changed {
            self.viewpointController.onPinchGestureChanged(Float(sender.scale))
        }
    }
    
    @IBAction func oneFingerPanGesture(_ sender: UIPanGestureRecognizer) {
        let touchPos = sender.location(in: view)
        let touchVel = sender.velocity(in: view)
        let touchPosVec = GLKVector2Make(Float(touchPos.x), Float(touchPos.y))
        let touchVelVec = GLKVector2Make(Float(touchVel.x), Float(touchVel.y))
        
        if sender.state == .began {
            self.viewpointController.onOneFingerPanBegan(touchPosVec)
        } else if sender.state == .changed {
            self.viewpointController.onOneFingerPanChanged(touchPosVec)
        } else if sender.state == .ended {
            self.viewpointController.onOneFingerPanEnded(touchVelVec)
        }
    }

    @IBAction func twoFingersPanGesture(_ sender: AnyObject) {

        guard sender.numberOfTouches == 2 else { return }
        
        let touchPos = sender.location(in: view)
        let touchVel = sender.velocity(in: view)
        let touchPosVec = GLKVector2Make(Float(touchPos.x), Float(touchPos.y))
        let touchVelVec = GLKVector2Make(Float(touchVel.x), Float(touchVel.y))
        
        if sender.state == .began {
            self.viewpointController.onTwoFingersPanBegan(touchPosVec)
        } else if sender.state == .changed {
            self.viewpointController.onTwoFingersPanChanged(touchPosVec)
        } else if sender.state == .ended {
            self.viewpointController.onTwoFingersPanEnded(touchVelVec)
        }
    }
    
    
    // MARK: - UI Control
    
    private func trySwitchToColorRenderingMode() {
   
        // Choose the best available color render mode, falling back to LightedGray
        // This method may be called when colorize operations complete, and will
        // switch the render mode to color, as long as the user has not changed
        // the selector.
        
        if mesh!.hasPerVertexUVTextureCoords() {
            os_log(.info, log: OSLog.meshView, "Setting rendermode textured")
            self.renderer.setRenderingMode(.textured)
            
        } else if mesh!.hasPerVertexColors() {
            os_log(.info, log: OSLog.meshView, "Setting rendermode per vertex color")
            self.renderer.setRenderingMode(.perVertexColor)
            
        } else {
            os_log(.info, log: OSLog.meshView, "Setting rendermode lighted gray")
            self.renderer.setRenderingMode(.lightedGray)
        }
    }
    
    
    /// 画面遷移時のセットアップで呼ばれている
    internal func showColorRenderingMode() {
        os_log(.debug, log: OSLog.meshView, "ShowColorRenderingMode")
        
        self.trySwitchToColorRenderingMode()
        
        let meshIsColorized: Bool = self.mesh!.hasPerVertexColors() || self.mesh!.hasPerVertexUVTextureCoords()
        
        os_log(.debug, log: OSLog.meshView, "Mesh is colorized = %{Public}@", String(describing: meshIsColorized))
        
        if !meshIsColorized {
            self.colorizeMesh()
        }
    }
    
    private func colorizeMesh() {
        os_log(.debug, log: OSLog.meshView, "Colorizing Mesh")
        
        let previewHandler = {
            os_log(.debug, log: OSLog.meshView, "Colorizing mesh - preview")
        }
        
        let completionHandler = { [weak self] in
            os_log(.debug, log: OSLog.meshView, "Colorizing mesh - enhanced")
            // Hide progress bar.
            self?.hideMeshViewerMessage()
        }
        
        // colorizer は ScanViewController
        let _ = self.colorizer?.meshViewDidRequestColorizing(
            self.mesh!
            , previewCompletionHandler: previewHandler
            , enhancedCompletionHandler: completionHandler
        )
    }
        
    func hideMeshViewerMessage() {
        UIView.animate(
            withDuration: 0.5
            , animations: { self.meshViewerMessageLabel.alpha = 0.0 }
            , completion: { _ in
                self.meshViewerMessageLabel.isHidden = true
            })
    }
    
    func showMeshViewerMessage(_ msg: String) {
        self.meshViewerMessageLabel.text = msg
        
        if self.meshViewerMessageLabel.isHidden == true {
            self.meshViewerMessageLabel.alpha = 0.0
            self.meshViewerMessageLabel.isHidden = false
            
            UIView.animate(withDuration: 0.5, animations: {
                self.meshViewerMessageLabel.alpha = 1.0
            })
        }
    }
}

