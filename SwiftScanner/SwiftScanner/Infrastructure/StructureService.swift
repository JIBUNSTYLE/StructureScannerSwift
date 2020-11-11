//
//  StructureService.swift
//  SwiftScanner
//
//  Created by 斉藤 祐輔 on 2020/11/04.
//  Copyright © 2020 CoderJoris. All rights reserved.
//

import Foundation

import Combine
import AVFoundation

let VGA_ASPECT_RATIO = Float(640.0)/Float(480.0)

// Here, we set a larger volume bounds size when mapping in high resolution.
let LOW_RESOLUTION_VOLUME_BOUNDS: Float = 125
let HIGH_RESOLUTION_VOLUME_BOUNDS: Float = 200

struct Buffers {
    let frameBuffer: GLuint
    let colorRenderBuffer: GLuint
    let depthRenderBuffer: GLuint
    let width: GLint
    let height: GLint
    
    init(
        frameBuffer: GLuint
        , colorRenderBuffer: GLuint
        , depthRenderBuffer: GLuint
        , width: GLint
        , height: GLint
    ) {
        self.frameBuffer = frameBuffer
        self.colorRenderBuffer = colorRenderBuffer
        self.depthRenderBuffer = depthRenderBuffer
        self.width = width
        self.height = height
    }
}

// Display
enum GraphicContext {
    case unkown
    case initialized(
            layer: CAEAGLLayer
            , context: EAGLContext
            , buffers: Buffers
            , viewport: [GLfloat]
            // Shader to render a GL texture as a simple quad.
            , yCbCrTextureShader: STGLTextureShaderYCbCr
            , rgbaTextureShader: STGLTextureShaderRGBA
            , depthAsRgbaTexture: GLuint
            , videoTextureCache: CVOpenGLESTextureCache
         )
}

// SLAM
enum ScannerContext {
    case unknown
    case initialized(
            scene: STScene
            , tracker: STTracker
            , cameraPoseInitializer: STCameraPoseInitializer
            , cubeRenderer: STCubeRenderer // Renders the volume boundaries as a cube.
            , keyFrameManager: STKeyFrameManager
            , depthAsRgbaVisualizer: STDepthToRgba
            , volumeSizeInMeters: GLKVector3
         )
    case scanning(
            scene: STScene
            , tracker: STTracker
            , cameraPoseInitializer: STCameraPoseInitializer
            , cubeRenderer: STCubeRenderer // Renders the volume boundaries as a cube.
            , keyFrameManager: STKeyFrameManager
            , depthAsRgbaVisualizer: STDepthToRgba
            , mapper: STMapper
            , volumeSizeInMeters: GLKVector3
         )
    case completed(mesh: STMesh)
    case terminated
}

// CaptureSession
enum CaptureSessionContext {
    case unknown
    case initialized(session: STCaptureSession)
}

enum ColorizeContext {
    case unknown
    case native(task: STBackgroundTask)
    case enhanced(task: STBackgroundTask)
}

class StructureService : NSObject, ScannerInterface {
    
    // TODO: presenter層からstructごと更新可能にする
    var dynamicOptions = DynamicOptions()
    
    /* ================== DisplayState ================== */
   
    var graphicContext: GraphicContext = .unkown
    
    // Intrinsics to use with the current frame in the undistortion shader
    var intrinsics: STIntrinsics = STIntrinsics()
    
    // OpenGL Texture reference for y images.
    var lumaTexture: CVOpenGLESTexture? = nil

    // OpenGL Texture reference for color images.
    var chromaTexture: CVOpenGLESTexture? = nil

    // OpenGL projection matrix for the color camera.
    var colorCameraGLProjectionMatrix: GLKMatrix4 = GLKMatrix4Identity

    // OpenGL projection matrix for the depth camera.
    var depthCameraGLProjectionMatrix: GLKMatrix4 = GLKMatrix4Identity

    // Mesh rendering alpha
    var meshRenderingAlpha: Float = 0.8
    
    
    /* ================== SlamData ================== */
    
    private var scannerContext: ScannerContext = .unknown

    var prevFrameTimeStamp: TimeInterval = -1

    // cubePlacemnent中、processDepthFrameで更新され、scan開始時に初期値として利用する
    var initialDepthCameraPose: GLKMatrix4 = GLKMatrix4Identity
    
    /* ================== OTHER ================== */
    
    var captureSessionContext: CaptureSessionContext = .unknown
    
    var colorizeContext: ColorizeContext = .unknown
    
    // Most recent gravity vector from IMU.
    var _lastGravity: GLKVector3!
    

    var _lastScannableState = false
    let scanningSubject = PassthroughSubject<ScanningContext, SystemErrors>()
    let finalizeSubject = PassthroughSubject<FinalizeContext, SystemErrors>()
    
    var cancellables = [AnyCancellable]()
    
    /// 描画（OpenGL）設定、キャプチャ設定、SLAM作成設定を初期化し、スキャニングを開始します（CubePlacing）。
    /// - Parameter layer: <#layer description#>
    /// - Throws: <#description#>
    /// - Returns: <#description#>
    func initialize(layer: CALayer) throws -> PassthroughSubject<ScanningContext, SystemErrors> {
        guard let layer = layer as? CAEAGLLayer else {
            throw SystemErrors.scannerInterface(.レイヤーのキャストに失敗)
        }
        
        // 画面描画処理の初期化
        self.graphicContext = try self.initializeGraphics(layer: layer)
        
        guard case .initialized(_, let context, _, _, _, _, _, _) = self.graphicContext else {
            fatalError()
        }
        
        // キャプチャセッションの初期化
        self.captureSessionContext = self.initializeCaptureSession(with: self.dynamicOptions)
        
        // スキャン（SLAM作成）処理の初期化
        self.scannerContext = try self.initializeScanner(context: context, with: self.dynamicOptions)
        
        if case .initialized = self.scannerContext
           , case .initialized(let session) = self.captureSessionContext
        {
            session.streamingEnabled = true
            session.properties = STCaptureSessionPropertiesSetColorCameraAutoExposureISOAndWhiteBalance()
            
            switch session.sensorMode {
            case .batteryDepleted:
                log("============================= sensorMode: .batteryDepleted")
                break
            case .notConnected:
                log("============================= sensorMode: .notConnected")
                break
            case .ready:
                log("============================= sensorMode: .ready")
                // readyの時のみスキャンできる
                break
            case .standby:
                log("============================= sensorMode: .standby")
                break
            case .unknown:
                log("============================= sensorMode: .unknown")
                break
            case .wakingUp:
                log("============================= sensorMode: .wakingUp")
                break
            default:
                break
            }
        }
        
        return self.scanningSubject
    }
    
    
    /// SLAM作成を開始します。
    func startModeling() throws {
        guard case .initialized(
                let scene
                , let tracker
                , let cameraPoseInitializer
                , let cubeRenderer
                , let keyFrameManager
                , let depthAsRgbaVisualizer
                , let volumeSizeInMeters
        ) = self.scannerContext else {
            throw SystemErrors.scannerInterface(.スキャニングが開始されていません)
        }
        
        // processDepthFrameで更新された値を使う
        tracker.initialCameraPose = self.initialDepthCameraPose
        
        self.scannerContext = try self.startScanning(
            scene: scene
            , tracker: tracker
            , cameraPoseInitializer: cameraPoseInitializer
            , cubeRenderer: cubeRenderer
            , keyFrameManager: keyFrameManager
            , depthAsRgbaVisualizer: depthAsRgbaVisualizer
            , volumeSizeInMeters: volumeSizeInMeters
            , with: self.dynamicOptions
        )
    }
    
    func getCurrentState() {
        if case .initialized = self.scannerContext
           , case .initialized(let session) = self.captureSessionContext
        {
            session.streamingEnabled = true
            session.properties = STCaptureSessionPropertiesSetColorCameraAutoExposureISOAndWhiteBalance()
            
            switch session.userInstructions {
            case .firmwareUpdateRequired:
                break
            case .needToAuthorizeColorCamera:
                break
            case .needToChargeSensor:
                break
            case .needToConnectSensor:
                break
            case .needToRunCalibrator:
                break
            case .optionallyConnectStructureSensor:
                break
            case .sensorWakingUp:
                break
            default:
                break
            }
            
            switch session.sensorMode {
            case .batteryDepleted:
                break
            case .notConnected:
                break
            case .ready:
                // readyの時のみスキャンできる
                break
            case .standby:
                break
            case .unknown:
                break
            case .wakingUp:
                break
            default:
                break
            }
        }
    }
    
    /// 作成中のSLAMを破棄して再度CubePlacingに入ります。
    func restartFromCubePlacing() {
        
        guard case .scanning(
            let scene
            , let tracker
            , let cameraPoseInitializer
            , let cubeRenderer
            , let keyFrameManager
            , let depthAsRgbaVisualizer
            , let mapper
            , let volumeSizeInMeters
        ) = self.scannerContext else { return }
        
        self.prevFrameTimeStamp = -1.0
        
        mapper.reset()
        tracker.reset()
        scene.clear()
        keyFrameManager.clear()
        
        self.scannerContext = .initialized(
            scene: scene
            , tracker: tracker
            , cameraPoseInitializer: cameraPoseInitializer
            , cubeRenderer: cubeRenderer
            , keyFrameManager: keyFrameManager
            , depthAsRgbaVisualizer: depthAsRgbaVisualizer
            , volumeSizeInMeters: volumeSizeInMeters
        )
        
        if case .initialized(let session) = self.captureSessionContext {
            session.streamingEnabled = true
            session.properties = STCaptureSessionPropertiesSetColorCameraAutoExposureISOAndWhiteBalance()
        }
    }
    
    /// モデリングを終了します。
    func finishModeling() throws -> PassthroughSubject<FinalizeContext, SystemErrors> {
        
        guard case .scanning(
            let scene
            , let tracker
            , _ // let cameraPoseInitializer
            , _ // let cubeRenderer
            , let keyFrameManager
            , _ // let depthAsRgbaVisualizer
            , let mapper
            , _ // let volumeSizeInMeters
        ) = self.scannerContext
            , case .initialized(let session) = self.captureSessionContext else {
            throw SystemErrors.scannerInterface(.モデリングが開始されていません)
        }
        
        
        if session.occWriter.isWriting
           , !session.occWriter.stopWriting() {
            // Should fail instead - but not using OCC anyway
            log("Could not properly stop OCC writer.")
        }
        
        session.streamingEnabled = false
        session.delegate = nil
        
        self.scanningSubject.send(completion: .finished)
        
        mapper.finalizeTriangleMesh()
        
        guard let mesh = scene.lockAndGetMesh() else {
            throw SystemErrors.scannerInterface(.meshの生成に失敗)
        }
        
        scene.unlockMesh()
        
        self.scannerContext = .completed(mesh: mesh)
        
        self.colorizeContext
            = try self.nativeColorize(mesh, scene: scene, keyFrameManager: keyFrameManager)
        
        guard case .native(let nativeColorizeTask) = self.colorizeContext else {
            fatalError()
        }
        
        // Release the tracking and mapping resources. It will not be possible to resume a scan after this point
        mapper.reset()
        tracker.reset()
            
        _ = self.finalizeSubject
            .sink(receiveCompletion: {_ in }
                  , receiveValue: { context in
                switch context {
                case .succeedToNativeColorize: do {
                    log("========== succeedToNativeColorize")
                    // MeshRender.update()が必要か？
                    
                    do {
                        // native colorize が終わったら次を実行する
                        self.colorizeContext = try self.enhancedColorize(mesh, scene: scene, keyFrameManager: keyFrameManager)
                        
                        guard case .enhanced(let enhancedColorizeTask) = self.colorizeContext else {
                            fatalError()
                        }
                        
                        // We don't need the keyframes anymore now that the final colorizing task was started.
                        // Clearing it now gives a chance to early release the keyframe memory when the colorizer
                        // stops needing them.
                        keyFrameManager.clear()
                        
                        log("========== start enhancedColorizeTask")
                        enhancedColorizeTask.delegate = self
                        enhancedColorizeTask.start()
                        
                    } catch SystemErrors.scannerInterface(let error) {
                        self.finalizeSubject.send(completion: .failure(SystemErrors.scannerInterface(error)))
                        
                    } catch {
                        fatalError()
                    }
                }
                case .succeedToEnhancedColorize: do {
                    log("========== succeedToEnhancedColorize")
                    // MeshRender.update()が必要か？
                    
                    do {
                        // ファイルに保存
                        let url = try self.save(mesh)
                        self.finalizeSubject.send(.finished(url))
                        self.finalizeSubject.send(completion: .finished)
                        
                    } catch SystemErrors.scannerInterface(let error) {
                        self.finalizeSubject.send(completion: .failure(SystemErrors.scannerInterface(error)))
                        
                    } catch {
                        fatalError()
                    }
                }
                default:
                    break
                }
            })
            .store(in: &cancellables)
        
        log("========== start nativeColorizeTask")
        nativeColorizeTask.delegate = self
        nativeColorizeTask.start()
        
        return self.finalizeSubject
    }
    
    func terminate() {
        if case .initialized(
            _ // let layer
            , let context
            , let buffers
            , _ // let viewport
            , _ // let yCbCrTextureShader
            , _ // let rgbaTextureShader
            , _ // let depthAsRgbaTexture
            , _ // let videoTextureCache
        ) = self.graphicContext
              , EAGLContext.current() == context {
            EAGLContext.setCurrent(nil)
            self.delete(buffers)
        }
        
        if case .initialized(let session) = self.captureSessionContext {
            session.streamingEnabled = false
            session.delegate = nil
        }
        
        self.resetScanner(context: self.scannerContext)
    }
    
}

extension StructureService {
    
    private func save(_ mesh: STMesh) throws -> String {
        let filename = "dummy.zip"// "\(UUID().uuidString).zip"
        let fileManager = FileManager.default
//        let documentsDir = try fileManager.url(
//            for: .documentDirectory
//            , in: .userDomainMask
//            , appropriateFor: nil
//            , create: true)
        
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let documentsDir = paths[0]
        
        // 列挙
        do {
            let files_before = try fileManager.contentsOfDirectory(atPath: documentsDir)
            files_before.forEach { f in
                log("file: \(f)")
            }
        } catch let error {
            log("ERROR: \(error)")
        }
        
        let filepath = (documentsDir as NSString).appendingPathComponent(filename)
        
        if fileManager.fileExists(atPath: filepath) {
            try fileManager.removeItem(atPath: filepath)
        }
        
        let options: [AnyHashable: Any] = [
            kSTMeshWriteOptionFileFormatKey : STMeshWriteOptionFileFormat.objFileZip.rawValue
        ]
        try mesh.write(toFile: filepath, options: options)
        
        // 列挙
        let files_after = try! fileManager.contentsOfDirectory(atPath: documentsDir)
        files_after.forEach { f in
            log("file: \(f)")
        }
        
        return filepath
    }
    
    private func nativeColorize(_ mesh :STMesh, scene: STScene, keyFrameManager: STKeyFrameManager) throws -> ColorizeContext {
        
        do {
            // native color
            let task = try STColorizer.newColorizeTask(
                with: mesh
                , scene: scene
                , keyframes: keyFrameManager.getKeyFrames()
                , completionHandler: { [weak self] error in
                    guard let _self = self else { return }
                    
                    if let error = error {
                        log("エラーあるよ \(error)")
                        _self.finalizeSubject.send(completion: .failure(SystemErrors.scannerInterface(.nativeColorizeTaskでエラーが発生しました(error: error))))
                    } else {
                        log("エラーないよ")
                        // 完了
                        _self.finalizeSubject.send(.succeedToNativeColorize)
                    }
                }
                , options: [
                    kSTColorizerTypeKey : STColorizerType.perVertex.rawValue
                    , kSTColorizerPrioritizeFirstFrameColorKey: Options.prioritizeFirstFrameColor
                ]
            )
            
            return .native(task: task)
            
        } catch let error {
            throw SystemErrors.scannerInterface(.nativeColorizeTaskの開始に失敗しました(error: error))
        }
    }
    
    private func enhancedColorize(_ mesh :STMesh, scene: STScene, keyFrameManager: STKeyFrameManager) throws -> ColorizeContext {
        
        do {
            // enhanced color
            let task = try STColorizer.newColorizeTask(
                with: mesh
                , scene: scene
                , keyframes: keyFrameManager.getKeyFrames()
                , completionHandler: { [weak self] error in
                    guard let _self = self else { return }
                    
                    if let error = error {
                        _self.finalizeSubject.send(completion: .failure(SystemErrors.scannerInterface(.enhancedColorizeTaskでエラーが発生しました(error: error))))
                    } else {
                        // 完了
                        _self.finalizeSubject.send(.succeedToEnhancedColorize)
                    }
                }
                , options: [
                    kSTColorizerTypeKey: STColorizerType.textureMapForObject.rawValue
                    , kSTColorizerPrioritizeFirstFrameColorKey: Options.prioritizeFirstFrameColor
                    , kSTColorizerQualityKey: Options.colorizerQuality.rawValue
                    , kSTColorizerTargetNumberOfFacesKey: Options.colorizerTargetNumFaces
                ]
            )
            
            return .enhanced(task: task)
            
        } catch let error {
            throw SystemErrors.scannerInterface(.enhancedColorizeTaskの開始に失敗しました(error: error))
        }
    }
}

// MARK: - private for OpenGL
// TODO: View側に持っていきたい
extension StructureService {
    
    private func initializeBuffers(context: EAGLContext, layer: CAEAGLLayer) throws -> Buffers {
        var frameBuffer = GLuint()
        var colorRenderBuffer = GLuint()
        var depthRenderBuffer = GLuint()
        var width = GLint()
        var height = GLint()
        
        EAGLContext.setCurrent(context)
        
        /*  Create framebuffer object. */
        glGenFramebuffers(1, &frameBuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), frameBuffer)
        
        /* Create color render buffer and allocate backing store. */
        glGenRenderbuffers(1, &colorRenderBuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderBuffer)
        
        context.renderbufferStorage(GLintptr(GL_RENDERBUFFER), from: layer)
        
        glGetRenderbufferParameteriv(
            GLenum(GL_RENDERBUFFER)
            , GLenum(GL_RENDERBUFFER_WIDTH)
            , &width
        )
        
        glGetRenderbufferParameteriv(
            GLenum(GL_RENDERBUFFER)
            , GLenum(GL_RENDERBUFFER_HEIGHT)
            , &height
        )
        
        glFramebufferRenderbuffer(
            GLenum(GL_FRAMEBUFFER)
            , GLenum(GL_COLOR_ATTACHMENT0)
            , GLenum(GL_RENDERBUFFER)
            , colorRenderBuffer
        )
        
        /* Create depth render buffer and allocate backing store. */
        glGenRenderbuffers(1, &depthRenderBuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), depthRenderBuffer)
        
        glRenderbufferStorage(
            GLenum(GL_RENDERBUFFER)
            , GLenum(GL_DEPTH_COMPONENT16)
            , width
            , height
        )
        
        glFramebufferRenderbuffer(
            GLenum(GL_FRAMEBUFFER)
            , GLenum(GL_DEPTH_ATTACHMENT)
            , GLenum(GL_RENDERBUFFER)
            , depthRenderBuffer
        )
        
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            throw SystemErrors.scannerInterface(.フレームバッファの初期化に失敗(status: status))
        }
        
        return Buffers(
            frameBuffer: frameBuffer
            , colorRenderBuffer: colorRenderBuffer
            , depthRenderBuffer: depthRenderBuffer
            , width: width
            , height: height
        )
    }
    
    private func initializeGraphics(layer: CAEAGLLayer) throws -> GraphicContext {
        
        // Create an EAGLContext for EAGLView.
        guard let context = EAGLContext(api: .openGLES2) else {
            log("Failed to create EAGLContext")
            throw SystemErrors.scannerInterface(.コンテキストの初期化に失敗)
        }
        
        let buffers = try self.initializeBuffers(context: context, layer: layer)
        glViewport(0, 0, buffers.width, buffers.height)
        
        let framebufferAspectRatio = Float(buffers.width)/Float(buffers.height)

        // The iPad's diplay conveniently has a 4:3 aspect ratio just like our video feed.
        // Some iOS devices need to render to only a portion of the screen so that we don't distort
        // our RGB image. Alternatively, you could enlarge the viewport (losing visual information),
        // but fill the whole screen.
        let imageAspectRatio = nearlyEqual(framebufferAspectRatio, VGA_ASPECT_RATIO) ? 1.0 : Float(480.0)/Float(640.0)

        let viewport: [GLfloat] = [0, 0, Float(buffers.width) * imageAspectRatio, Float(buffers.height)]
        
        let yCbCrTextureShader = STGLTextureShaderYCbCr()
        let rgbaTextureShader = STGLTextureShaderRGBA()
        
        // OpenGL Texture cache for the color camera.
        var _videoTextureCache: CVOpenGLESTextureCache? = nil
        
        // Set up texture and textureCache for images output by the color camera.
        let texError: CVReturn = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, context, nil, &_videoTextureCache)
        
        guard texError == kCVReturnSuccess
              , let videoTextureCache = _videoTextureCache else {
            log("Error at CVOpenGLESTextureCacheCreate \(texError)")
            throw SystemErrors.scannerInterface(.eSTextureCacheの作成に失敗)
        }
        
        var depthAsRgbaTexture: GLuint = 0
        
        glGenTextures(1, &depthAsRgbaTexture)
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), depthAsRgbaTexture)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_NEAREST)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_NEAREST)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        
        return .initialized(
            layer: layer
            , context: context
            , buffers: buffers
            , viewport: viewport
            , yCbCrTextureShader: yCbCrTextureShader
            , rgbaTextureShader: rgbaTextureShader
            , depthAsRgbaTexture: depthAsRgbaTexture
            , videoTextureCache: videoTextureCache
        )
    }
    
    private func delete(_ buffers: Buffers) {
        if buffers.frameBuffer != 0 {
            var frameBuffer = buffers.frameBuffer
            glDeleteFramebuffers(1, &frameBuffer)
        }
        
        if buffers.depthRenderBuffer != 0 {
            var depthRenderBuffer = buffers.depthRenderBuffer
            glDeleteFramebuffers(1, &depthRenderBuffer)
        }
        
        if buffers.colorRenderBuffer != 0 {
            var colorRenderBuffer = buffers.colorRenderBuffer
            glDeleteFramebuffers(1, &colorRenderBuffer)
        }
    }
    
    /// 深度フレームセンサのサンプルが出力された際の描画を行います。STCaptureSessionDelegateプロトコルの実装で呼ばれます。
    /// - Parameters:
    ///   - depthFrame: <#depthFrame description#>
    ///   - colorFrame: <#colorFrame description#>
    ///   - graphicContext: <#graphicContext description#>
    ///   - scannerContext: <#scannerContext description#>
    private func renderSceneForDepthFrameCubePlacing(_ depthFrame: STDepthFrame, colorFrame: STColorFrame?, graphicContext: GraphicContext, cameraPoseInitializer: STCameraPoseInitializer, cubeRenderer: STCubeRenderer) {
        
        log("ここにはきている")
        
        // Render the background image from the color camera.
        self.renderCameraImage(graphicContext: graphicContext)
        
        guard cameraPoseInitializer.lastOutput.hasValidPose.boolValue else {
            log("cameraPoseInitializer.lastOutput.hasValidPose.boolValueさよなら")
            return
        }
        
        log("cameraPoseInitializer.lastOutput.hasValidPose.boolValueきてる")
            
        // cubePlacemnent中、processDepthFrameで更新され、scan開始時に初期値として利用する
        let depthCameraPose: GLKMatrix4 = self.initialDepthCameraPose
        
        let (cameraViewpoint, alpha) : (GLKMatrix4, Float) = {
            if Options.useHardwareRegisteredDepth {
                return (depthCameraPose, 1.0)
                
            } else {
                // Make sure the viewpoint is always to color camera one, even if not using registered depth.
                let iOSColorFromDepthExtrinsics = depthFrame.iOSColorFromDepthExtrinsics()
                
                // colorCameraPoseInWorld
                return (
                    GLKMatrix4Multiply(depthCameraPose, GLKMatrix4Invert(iOSColorFromDepthExtrinsics, nil))
                    , 0.5
                )
            }
        }()
        
        // Highlighted depth values inside the current volume area.
        cubeRenderer.renderHighlightedDepth(withCameraPose: cameraViewpoint, alpha: alpha)
        
        // Render the wireframe cube corresponding to the current scanning volume.
        cubeRenderer.renderCubeOutline(
            withCameraPose: cameraViewpoint
            , depthTestEnabled: false
            , occlusionTestEnabled: true
        )
    }
    
    private func renderSceneForDepthFrameScanning(_ depthFrame: STDepthFrame, colorFrame: STColorFrame?, graphicContext: GraphicContext, scene: STScene, tracker: STTracker, cubeRenderer: STCubeRenderer) {
        
        // Enable GL blending to show the mesh with some transparency.
        glEnable(GLenum(GL_BLEND))
        
        // Render the background image from the color camera.
        self.renderCameraImage(graphicContext: graphicContext)
        
        // Render the current mesh reconstruction using the last estimated camera pose.
        
        let depthCameraPose = tracker.lastFrameCameraPose()
        
        let cameraGLProjection: GLKMatrix4 = {
            if let colorFrame = colorFrame {
                return colorFrame.glProjectionMatrix()
            } else {
                return depthFrame.glProjectionMatrix()
            }
        }()
        
        let cameraViewpoint: GLKMatrix4 = {
            if Options.useHardwareRegisteredDepth {
                return depthCameraPose
            } else {
                // If we want to use the color camera viewpoint, and are not using registered depth, then
                // we need to deduce the color camera pose from the depth camera pose.
                let iOSColorFromDepthExtrinsics = depthFrame.iOSColorFromDepthExtrinsics()
                
                // colorCameraPoseInWorld
                return GLKMatrix4Multiply(
                    depthCameraPose
                    , GLKMatrix4Invert(iOSColorFromDepthExtrinsics, nil)
                )
            }
        }()
        
        scene.renderMesh(
            fromViewpoint: cameraViewpoint
            , cameraGLProjection: cameraGLProjection
            , alpha: self.meshRenderingAlpha
            , highlightOutOfRangeDepth: true
            , wireframe: false
        )
        
        glDisable(GLenum(GL_BLEND))
        
        // Render the wireframe cube corresponding to the scanning volume.
        // Here we don't enable occlusions to avoid performance hit.
        cubeRenderer.renderCubeOutline (
            withCameraPose: cameraViewpoint
            , depthTestEnabled: true
            , occlusionTestEnabled: false
        )
    }
    
    private func renderCameraImage(graphicContext: GraphicContext) {
        guard case .initialized(_, _, _, _, let yCbCrTextureShader, let rgbaTextureShader, _, _) = graphicContext
              , let lumaTexture = self.lumaTexture
              , let chromaTexture = self.chromaTexture else { return }
        
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(CVOpenGLESTextureGetTarget(lumaTexture), CVOpenGLESTextureGetName(lumaTexture))
        
        glActiveTexture(GLenum(GL_TEXTURE1))
        glBindTexture(CVOpenGLESTextureGetTarget(chromaTexture), CVOpenGLESTextureGetName(chromaTexture))
        
        glDisable(GLenum(GL_BLEND))
        yCbCrTextureShader.useShaderProgram(withUndistortion: &(self.intrinsics))
        yCbCrTextureShader.render(withLumaTexture: GL_TEXTURE0, chromaTexture: GL_TEXTURE1)
        
        glUseProgram(0)
    }
    
    // TODO: SLAM作成系処理の分離。colorFrameを直接渡すのでなく、gl系処理のみを残す
    private func uploadGLColorTexture(from colorFrame: STColorFrame, with videoTextureCache: CVOpenGLESTextureCache) {
        var colorFrame = colorFrame
        
        self.intrinsics = colorFrame.intrinsics()
        
        // Clear the previous color texture.
        self.lumaTexture = nil
        
        // Clear the previous color texture
        self.chromaTexture = nil
        
        // Displaying image with width over 1280 is an overkill. Downsample it to save bandwidth.
        while colorFrame.width > 2560 {
            colorFrame = colorFrame.halfResolution
        }
        
        var err: CVReturn
        
        // Allow the texture cache to do internal cleanup.
        CVOpenGLESTextureCacheFlush(videoTextureCache, 0)
        
        guard let pixelBuffer: CVImageBuffer = CMSampleBufferGetImageBuffer(colorFrame.sampleBuffer) else {
            fatalError()
        }
        
        let width: size_t = CVPixelBufferGetWidth(pixelBuffer)
        let height: size_t = CVPixelBufferGetHeight(pixelBuffer)
        
        let pixelFormat: OSType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        assert(pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "YCbCr is expected!")
        
        // Activate the default texture unit.
        glActiveTexture(GLenum(GL_TEXTURE0))
        
        // Create an new Y texture from the video texture cache.
        err = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault
            , videoTextureCache
            , pixelBuffer
            , nil
            , GLenum(GL_TEXTURE_2D)
            , GLint(GL_RED_EXT)
            , GLsizei(width)
            , GLsizei(height)
            , GLenum(GL_RED_EXT)
            , GLenum(GL_UNSIGNED_BYTE)
            , 0
            , &self.lumaTexture
        )
        
        guard err == kCVReturnSuccess
              , let lumaTexture = self.lumaTexture else {
            log("Error with CVOpenGLESTextureCacheCreateTextureFromImage: \(err)")
            return
        }
        
        // Set good rendering properties for the new texture.
        glBindTexture(CVOpenGLESTextureGetTarget(lumaTexture), CVOpenGLESTextureGetName(lumaTexture))
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
        
        // Activate the default texture unit.
        glActiveTexture(GLenum(GL_TEXTURE1))
        
        // Create an new CbCr texture from the video texture cache.
        err = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault
            , videoTextureCache
            , pixelBuffer
            , nil
            , GLenum(GL_TEXTURE_2D)
            , GLint(GL_RG_EXT)
            , GLsizei(width / 2)
            , GLsizei(height / 2)
            , GLenum(GL_RG_EXT)
            , GLenum(GL_UNSIGNED_BYTE)
            , 1
            , &self.chromaTexture
        )
        
        guard err == kCVReturnSuccess
              , let chromaTexture = self.chromaTexture else {
            log("Error with CVOpenGLESTextureCacheCreateTextureFromImage: \(err)")
            return
        }
        
        // Set rendering properties for the new texture.
        glBindTexture(CVOpenGLESTextureGetTarget(chromaTexture), CVOpenGLESTextureGetName(chromaTexture))
        glTexParameterf( GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
        glTexParameterf( GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
    }
    
    private func uploadGLColorTexture(depthAsRgbaTexture: GLuint, width: GLsizei, height: GLsizei, pixels: UnsafeRawPointer!) {
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), depthAsRgbaTexture)
        
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA, width, height, 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), pixels)
    }
    
    private func nearlyEqual(_ a: Float, _ b: Float) -> Bool {
        return abs(a-b) < Float.ulpOfOne
    }
}

// MARK: - private for CaptureSession
extension StructureService {
    
    // Function modified for SDK 0.9
    var videoDeviceSupportsHighResColor: Bool {
        // High Resolution Color format is width 2592, height 1936.
        // Most recent devices support this format at 30 FPS.
        // However, older devices may only support this format at a lower framerate.
        // In your Structure Sensor is on firmware 2.0+, it supports depth capture at FPS of 24.
        
        guard let testVideoDevice = AVCaptureDevice.default(for: .video) else { fatalError() }
        
        let base420f: UInt32 = 875704422  // decimal val of '420f' (full range YCbCr)
        let fourCharCodeStr = base420f as FourCharCode
        
        for format in testVideoDevice.formats {
            if format.isVideoBinned { continue }
            
            let firstFrameRateRange = format.videoSupportedFrameRateRanges[0]
            
            let formatMinFps = (firstFrameRateRange as AnyObject).minFrameRate
            let formatMaxFps = (firstFrameRateRange as AnyObject).maxFrameRate
            
            if formatMaxFps! < 15 // Max framerate too low.
                    || formatMinFps! > 30 // Min framerate too high.
                    || (formatMaxFps! == 24 && formatMinFps! > 15) { // We can neither do the 24 FPS max framerate, nor fall back to 15.
                continue
            }
            
            let formatDesc = format.formatDescription
            let fourCharCode = CMFormatDescriptionGetMediaSubType(formatDesc)
            
            // we only support full range YCbCr for now
            if fourCharCode != fourCharCodeStr { continue }
            
            let formatDims = CMVideoFormatDescriptionGetDimensions(formatDesc)
            
            if 2592 != formatDims.width { continue }
            if 1936 != formatDims.height { continue }
            
            // All requirements met.
            return true
        }
        
        // No acceptable high-res format was found.
        return false
    }
    
    private func initializeCaptureSession(with dynamicOptions: DynamicOptions) -> CaptureSessionContext {
        // Clear / reset the capture session if it already exists
        let session = { (context: CaptureSessionContext) -> STCaptureSession in
            switch context {
            case .unknown:
                // Create an STCaptureSession instance
                return STCaptureSession.new()
                
            case .initialized(let session):
                session.streamingEnabled = false
                return session
            }
        }(self.captureSessionContext)
        
        let resolution = dynamicOptions.highResColoring && self.videoDeviceSupportsHighResColor
            ? STCaptureSessionColorResolution.resolution2592x1936
            : STCaptureSessionColorResolution.resolution640x480
        
        let sensorConfig : [AnyHashable: Any] = [
            kSTCaptureSessionOptionColorResolutionKey: resolution.rawValue
            , kSTCaptureSessionOptionDepthSensorVGAEnabledIfAvailableKey: false
            , kSTCaptureSessionOptionColorMaxFPSKey: 30.0 as Float
            , kSTCaptureSessionOptionDepthSensorEnabledKey: true
            , kSTCaptureSessionOptionUseAppleCoreMotionKey: true
            , kSTCaptureSessionOptionDepthStreamPresetKey: dynamicOptions.depthStreamPreset.rawValue
            , kSTCaptureSessionOptionSimulateRealtimePlaybackKey: true
        ]
        
        // Set the lens detector off, and default lens state as "non-WVL" mode
        session.lens = STLens.normal
        session.lensDetection = STLensDetectorState.off
        
        // Set ourself as the delegate to receive sensor data.
        session.delegate = self
        session.startMonitoring(options: sensorConfig)
        
        return .initialized(session: session)
    }
  
    /// 深度フレームセンサのサンプルが出力された際の処理を行います。STCaptureSessionDelegateプロトコルの実装で呼ばれます。
    /// - Parameters:
    ///   - depthFrame: <#depthFrame description#>
    ///   - colorFrame: <#colorFrame description#>
    ///   - depthAsRgbaTexture: <#graphicContext description#>
    ///   - scannerContext: <#scannerContext description#>
    private func processDepthFrameCubePlacing(_ depthFrame: STDepthFrame, colorFrame: STColorFrame?, depthAsRgbaTexture: GLuint, cameraPoseInitializer: STCameraPoseInitializer, cubeRenderer: STCubeRenderer) {
        
        ///
        /// .cubePlacement の間は、スキャン可能になるまで物体を追いかける
        ///
        let (depthFrameForCubeInitialization, depthCameraPoseInColorCoordinateFrame) : (STDepthFrame, GLKMatrix4) = {
            if Options.useHardwareRegisteredDepth {
                return (depthFrame, GLKMatrix4Identity)
            } else {
                // If we are using color images but not using registered depth, then use a registered
                // version to detect the cube, otherwise the cube won't be centered on the color image,
                // but on the depth image, and thus appear shifted.
                return (
                    depthFrame.registered(to: colorFrame)
                    , depthFrame.iOSColorFromDepthExtrinsics()
                )
            }
        }()
        
        // Provide the new depth frame to the cube renderer for ROI highlighting.
        cubeRenderer.setDepthFrame(depthFrameForCubeInitialization)
        
        // Estimate the new scanning volume position.
        if GLKVector3Length(self._lastGravity) > 1e-5 {
            do {
                try cameraPoseInitializer.updateCameraPose(
                    withGravity: self._lastGravity
                    , depthFrame: depthFrameForCubeInitialization
                )
                
                // Since we potentially detected the cube in a registered depth frame, also save the pose
                // in the original depth sensor coordinate system since this is what we'll use for SLAM
                // to get the best accuracy.
                self.initialDepthCameraPose = GLKMatrix4Multiply(
                    cameraPoseInitializer.lastOutput.cameraPose
                    , depthCameraPoseInColorCoordinateFrame
                )
            } catch {
                assertionFailure("Camera pose initializer error.")
            }
        }
        
        // Tell the cube renderer whether there is a support plane or not.
        cubeRenderer.setCubeHasSupportPlane(cameraPoseInitializer.lastOutput.hasSupportPlane.boolValue)
        
        // Enable the scan button if the pose initializer could estimate a pose.
        if self._lastScannableState != cameraPoseInitializer.lastOutput.hasValidPose.boolValue {
            self._lastScannableState = cameraPoseInitializer.lastOutput.hasValidPose.boolValue
            log("%%%%%%% isScannable: \(self._lastScannableState)")
            self.scanningSubject.send(.isScannable(self._lastScannableState))
        } else {
            log("さようなら") // <------- 変化がないのでこっちに入っている
        }
    }
    
    private func processDepthFrameScanning(_ depthFrame: STDepthFrame, colorFrame: STColorFrame?, depthAsRgbaTexture: GLuint, tracker: STTracker, keyFrameManager: STKeyFrameManager, mapper: STMapper) {
        
        log("Processing Depth Frame")
        
        // First try to estimate the 3D pose of the new frame.
        
        let depthCameraPoseBeforeTracking: GLKMatrix4 = tracker.lastFrameCameraPose()
        
        // Integrate it into the current mesh estimate if tracking was successful.
        do {
            try tracker.updateCameraPose(with: depthFrame, colorFrame: colorFrame)
            
            // If the tracker accuracy is high, use this frame for mapper update and maybe as a keyframe too.
            if tracker.poseAccuracy.rawValue >= STTrackerPoseAccuracy.high.rawValue {
                log("Integrating Depth Frame")
                mapper.integrateDepthFrame(depthFrame, cameraPose: tracker.lastFrameCameraPose())
            }
            
            // Tracking messages have higher priority.
            // Update the tracking message.
            if let trackingState = computeTrackingState(from: tracker.trackerHints) {
                self.scanningSubject.send(.trackingState(trackingState))
                
            } else if let colorFrame = colorFrame {
                if self.maybeAddKeyframeWithDepthFrame(
                    depthFrame
                    , colorFrame: colorFrame
                    , depthCameraPoseBeforeTracking: depthCameraPoseBeforeTracking
                    , tracker: tracker
                    , keyFrameManager: keyFrameManager
                    , prevFrameTimeStamp: self.prevFrameTimeStamp
                ) {
                    self.scanningSubject.send(.trackingState(.keepHolding))
                }
            } else {
                self.scanningSubject.send(.trackingState(.none))
            }
            
        } catch let trackingError as NSError {
            self.scanningSubject.send(.trackingState(.error(trackingError)))
        }
        
        self.prevFrameTimeStamp = depthFrame.timestamp
    }

    /// デバイスモーションデータのサンプルが出力された際の処理を行います。STCaptureSessionDelegateプロトコルの実装で呼ばれます。
    /// - Parameters:
    ///   - motion: <#motion description#>
    ///   - scannerContext: <#scannerContext description#>
    ///   - error: <#error description#>
    private func processDeviceMotion(_ motion: CMDeviceMotion, scannerContext: ScannerContext, error: NSError?) {
        
        if case .initialized(_, let tracker, _, _, _, _, _) = scannerContext {
            // Update our gravity vector, it will be used by the cube placement initializer.
            self._lastGravity = GLKVector3Make(Float(motion.gravity.x), Float(motion.gravity.y), Float(motion.gravity.z))
            // The tracker is more robust to fast moves if we feed it with motion data.
            tracker.updateCameraPose(with: motion)
            
        } else if case .scanning(_, let tracker, _, _, _, _, _, _) = scannerContext {
            // The tracker is more robust to fast moves if we feed it with motion data.
            tracker.updateCameraPose(with: motion)
        }
    }
    
    private func distanceToTargetInCentimeters(for depthFrame: STDepthFrame) -> Float {
        let w = depthFrame.width
        let h = depthFrame.height
        let w2 = w/2
        let h2 = h/2
        guard let depthArray = depthFrame.depthInMillimeters else { return Float.nan }
        return depthArray[Int(w * h2 + w2)] / 10.0
    }
    
    private func getMeshRenderingAlpha(from poseAccuracy: STTrackerPoseAccuracy) -> Float {
        switch poseAccuracy {
        case .high, .approximate:
            return 0.8
        case .low:
            return 0.4
        case .veryLow, .notAvailable:
            return 0.1
        @unknown default:
            return Float.nan
        }
    }
    
    private func computeTrackingState(from hints: STTrackerHints) -> ScanningContext.TrackingState? {
        if hints.trackerIsLost { return .lost }
        if hints.modelOutOfView { return .modelIsOutOfView }
        if hints.sceneIsTooClose { return .tooClose }
        return nil
    }
    
    private func deltaRotationAngleBetweenPosesInDegrees(_ previousPose: GLKMatrix4, newPose: GLKMatrix4) -> Float {
        // Transpose is equivalent to inverse since we will only use the rotation part.
        let deltaPose: GLKMatrix4 = GLKMatrix4Multiply(newPose, GLKMatrix4Transpose(previousPose))
        
        // Get the rotation component of the delta pose
        let deltaRotationAsQuaternion = GLKQuaternionMakeWithMatrix4(deltaPose)
        
        // Get the angle of the rotation
        let angleInDegree = GLKQuaternionAngle(deltaRotationAsQuaternion) / Float(Double.pi) * 180
        
        return angleInDegree
    }
    
    private func maybeAddKeyframeWithDepthFrame(
        _ depthFrame: STDepthFrame
        , colorFrame: STColorFrame
        , depthCameraPoseBeforeTracking: GLKMatrix4
        , tracker: STTracker
        , keyFrameManager: STKeyFrameManager
        , prevFrameTimeStamp: TimeInterval
    ) -> Bool {
        // Only consider adding a new keyframe if the accuracy is high enough.
        if tracker.poseAccuracy.rawValue < STTrackerPoseAccuracy.approximate.rawValue {
            return false
        }
        
        let depthCameraPoseAfterTracking = tracker.lastFrameCameraPose
        
        // Make sure the pose is in color camera coordinates in case we are not using registered depth.
        let iOSColorFromDepthExtrinsics = depthFrame.iOSColorFromDepthExtrinsics
        let colorCameraPoseAfterTracking =
            GLKMatrix4Multiply(depthCameraPoseAfterTracking(), GLKMatrix4Invert(iOSColorFromDepthExtrinsics(), nil))
        
        // Check if the viewpoint has moved enough to add a new keyframe
        // OR if we don't have a keyframe yet
        if keyFrameManager.wouldBeNewKeyframe(withColorCameraPose: colorCameraPoseAfterTracking) {
            
            let isFirstFrame = self.prevFrameTimeStamp < 0
            let canAddKeyframe: Bool = {
                if isFirstFrame { // always add the first frame.
                    return true
                    
                } else { // for others, check the speed.
                    let deltaSeconds = depthFrame.timestamp - self.prevFrameTimeStamp
                    
                    // Compute angular speed
                    let deltaAngularSpeedInDegreesPerSecond = deltaRotationAngleBetweenPosesInDegrees(
                        depthCameraPoseBeforeTracking
                        , newPose: depthCameraPoseAfterTracking()
                    ) / Float(deltaSeconds)
                    
                    // If the camera moved too much since the last frame, we will likely end up
                    // with motion blur and rolling shutter, especially in case of rotation. This
                    // checks aims at not grabbing keyframes in that case.
                    if CGFloat(deltaAngularSpeedInDegreesPerSecond) < Options.maxKeyframeRotationSpeedInDegreesPerSecond {
                        return true
                    }
                    return false
                }
            }()
            
            if canAddKeyframe {
                keyFrameManager.processKeyFrameCandidate(
                    withColorCameraPose: colorCameraPoseAfterTracking
                    , colorFrame: colorFrame
                    , depthFrame: nil
                ) // Spare the depth frame memory, since we do not need it in keyframes.
            } else {
                // Moving too fast. Hint the user to slow down to capture a keyframe
                // without rolling shutter and motion blur.
                return true
            }
        }
        
        return false
    }
}

// MARK: - private for SLAM
extension StructureService {
    /// SLAM作成のためのオブジェクト郡を生成します。
    /// - Parameters:
    ///   - context: OpenGLのコンテキスト
    ///   - dynamicOptions: 画面で変更可能なオプション
    /// - Returns: 状態
    private func initializeScanner(context: EAGLContext, with dynamicOptions: DynamicOptions) throws -> ScannerContext {
        guard case .unknown = self.scannerContext else { return self.scannerContext }

        // Initialize the scene.
        guard let scene = STScene(context: context) else {
            throw SystemErrors.scannerInterface(.sceneの生成に失敗)
        }
        
        // Initialize the camera pose tracker.
        let trackerOptions: [AnyHashable: Any] = [
            kSTTrackerTypeKey: dynamicOptions.depthAndColorTrackerIsOn
                ? STTrackerType.depthAndColorBased.rawValue
                : STTrackerType.depthBased.rawValue
            // tracking against the model is much better for close range scanning.
            , kSTTrackerTrackAgainstModelKey: true
            , kSTTrackerQualityKey: STTrackerQuality.accurate.rawValue
            , kSTTrackerBackgroundProcessingEnabledKey: true
            , kSTTrackerSceneTypeKey: STTrackerSceneType.object.rawValue
            , kSTTrackerLegacyKey: dynamicOptions.improvedTrackingIsOn
        ]

        // Initialize the camera pose tracker.
        guard let tracker = STTracker(scene: scene, options: trackerOptions) else {
            throw SystemErrors.scannerInterface(.trackerの生成に失敗)
        }
        
        // Set up the initial volume size.
        let volumeSizeInMeters = self.adjustVolumeSize(volumeSize: Options.initVolumeSizeInMeters)
        
        // The mapper will be initialized when we start scanning.
        
        // Setup the cube placement initializer.
        guard let cameraPoseInitializer = STCameraPoseInitializer(
            volumeSizeInMeters: volumeSizeInMeters
            , options: [kSTCameraPoseInitializerStrategyKey: STCameraPoseInitializerStrategy.tableTopCube.rawValue]
        ) else {
            throw SystemErrors.scannerInterface(.cameraPoseInitializerの生成に失敗)
        }
        
        // Set up the cube renderer with the current volume size.
        guard let cubeRenderer = STCubeRenderer(context: context) else {
            throw SystemErrors.scannerInterface(.cubeRendererの生成に失敗)
        }
        cubeRenderer.adjustCubeSize(volumeSizeInMeters)

        let keyframeManagerOptions: [AnyHashable: Any] = [
            kSTKeyFrameManagerMaxSizeKey : Options.maxNumKeyFrames
            , kSTKeyFrameManagerMaxDeltaTranslationKey : Options.maxKeyFrameTranslation
            , kSTKeyFrameManagerMaxDeltaRotationKey : Options.maxKeyFrameRotation // 20 degrees.
        ]
        
        guard let keyFrameManager = STKeyFrameManager(options: keyframeManagerOptions) else {
            throw SystemErrors.scannerInterface(.keyFrameManagerの生成に失敗)
        }
        
        guard let depthAsRgbaVisualizer = STDepthToRgba(options: [kSTDepthToRgbaStrategyKey: STDepthToRgbaStrategy.gray.rawValue]) else {
            throw SystemErrors.scannerInterface(.depthToRgbaの生成に失敗)
        }
        
        return .initialized(
            scene: scene
            , tracker: tracker
            , cameraPoseInitializer: cameraPoseInitializer
            , cubeRenderer: cubeRenderer
            , keyFrameManager: keyFrameManager
            , depthAsRgbaVisualizer: depthAsRgbaVisualizer
            , volumeSizeInMeters: volumeSizeInMeters
        )
    }
    
    
    /// スキャンを開始し、SLAMの作成を始めます。
    /// - Parameters:
    ///   - scene: <#scene description#>
    ///   - tracker: <#tracker description#>
    ///   - cameraPoseInitializer: <#cameraPoseInitializer description#>
    ///   - cubeRenderer: <#cubeRenderer description#>
    ///   - keyFrameManager: <#keyFrameManager description#>
    ///   - depthAsRgbaVisualizer: <#depthAsRgbaVisualizer description#>
    ///   - volumeSizeInMeters: <#volumeSizeInMeters description#>
    ///   - dynamicOptions: <#dynamicOptions description#>
    /// - Returns: <#description#>
    private func startScanning(
        scene: STScene
        , tracker: STTracker
        , cameraPoseInitializer: STCameraPoseInitializer
        , cubeRenderer: STCubeRenderer
        , keyFrameManager: STKeyFrameManager
        , depthAsRgbaVisualizer: STDepthToRgba
        , volumeSizeInMeters: GLKVector3
        , with dynamicOptions: DynamicOptions
    ) throws -> ScannerContext {
        
        let tmpVoxelSizeInMeters: Float = volumeSizeInMeters.x /
            (dynamicOptions.highResMapping ? HIGH_RESOLUTION_VOLUME_BOUNDS : LOW_RESOLUTION_VOLUME_BOUNDS)
        
        // Avoid voxels that are too small - these become too noisy.
        let voxelSizeInMeters = keepInRange(tmpVoxelSizeInMeters, minValue: 0.003, maxValue: 0.2)
        
        // Compute the volume bounds in voxels, as a multiple of the volume resolution.
        let volumeBounds = GLKVector3(v: (
            roundf(volumeSizeInMeters.x / voxelSizeInMeters)
            , roundf(volumeSizeInMeters.y / voxelSizeInMeters)
            , roundf(volumeSizeInMeters.z / voxelSizeInMeters)
        ))
        
        let volumeSizeText = String(
            format: "[Mapper] volumeSize (m): %f %f %f volumeBounds: %.0f %.0f %.0f (resolution=%f m)"
            , volumeSizeInMeters.x, volumeSizeInMeters.y, volumeSizeInMeters.z
            , volumeBounds.x, volumeBounds.y, volumeBounds.z, voxelSizeInMeters )
        
        log("volumeSize (m): \(volumeSizeText)")
        
        let mapperOptions: [AnyHashable: Any] = [
            kSTMapperLegacyKey : dynamicOptions.improvedMapperIsOn
            , kSTMapperVolumeResolutionKey : voxelSizeInMeters
            , kSTMapperVolumeBoundsKey: [volumeBounds.x, volumeBounds.y, volumeBounds.z]
            , kSTMapperVolumeHasSupportPlaneKey: cameraPoseInitializer.lastOutput.hasSupportPlane.boolValue
            , kSTMapperEnableLiveWireFrameKey: false
        ]
        
        guard let mapper = STMapper(scene: scene, options: mapperOptions) else {
            throw SystemErrors.scannerInterface(.mapperの生成に失敗)
        }
        
        return .scanning(
            scene: scene
            , tracker: tracker
            , cameraPoseInitializer: cameraPoseInitializer
            , cubeRenderer: cubeRenderer
            , keyFrameManager: keyFrameManager
            , depthAsRgbaVisualizer: depthAsRgbaVisualizer
            , mapper: mapper
            , volumeSizeInMeters: volumeSizeInMeters
        )
    }
    
    private func resetScanner(context: ScannerContext) {
        self.prevFrameTimeStamp = -1.0
        
        switch context {
        case .unknown, .terminated, .completed:
            break
            
        case .initialized(
                let scene
                , let tracker
                , _ // let cameraPoseInitializer
                , _ // let cubeRenderer
                , let keyFrameManager
                , _ // let depthAsRgbaVisualizer
                , _ // let volumeSizeInMeters
        ):
            tracker.reset()
            scene.clear()
            keyFrameManager.clear()
            
        case .scanning(
                let scene
                , let tracker
                , _ // let cameraPoseInitializer
                , _ // let cubeRenderer
                , let keyFrameManager
                , _ // let depthAsRgbaVisualizer
                , let mapper
                , _ // let volumeSizeInMeters
        ):
            mapper.reset()
            tracker.reset()
            scene.clear()
            keyFrameManager.clear()
        }
    }
    
    private func terminateScanner() -> ScannerContext {
        self.prevFrameTimeStamp = -1.0
        return .terminated
    }
    
    private func keepInRange(_ value: Float, minValue: Float, maxValue: Float) -> Float {
        if value.isNaN { return minValue }
        if value > maxValue { return maxValue }
        if value < minValue { return minValue }
        return value
    }

    private func adjustVolumeSize(volumeSize: GLKVector3) -> GLKVector3 {
        // Make sure the volume size remains between 10 centimeters and 3 meters.
        let x = keepInRange(volumeSize.x, minValue: 0.1, maxValue: 3)
        let y = keepInRange(volumeSize.y, minValue: 0.1, maxValue: 3)
        let z = keepInRange(volumeSize.z, minValue: 0.1, maxValue: 3)
        
        return GLKVector3(v: (x, y, z))
    }
    
}

// MARK: - STCaptureSessionDelegate プロトコルの実装
extension StructureService : STCaptureSessionDelegate {
    
    // MARK: - Required
    
    func captureSession(_ captureSession: STCaptureSession!, sensorDidEnter mode: STCaptureSessionSensorMode) {
        log("captureSession(_:sensorDidEnter: \(mode.rawValue))")

        // TODO
    }
    
    func captureSession(_ captureSession: STCaptureSession!, colorCameraDidEnter mode: STCaptureSessionColorCameraMode) {
        log("captureSession(_:colorCameraDidEnter: \(mode.rawValue))")
        
        // TODO
    }
    
    // MARK: - Optional
    
    /// Power Management
    func captureSession(_ captureSession: STCaptureSession!, sensorChargerStateChanged chargerState: STCaptureSessionSensorChargerState) {
        log("captureSession(_:sensorChargerStateChanged): \(chargerState.rawValue))")
        
        // TODO
    }
    
    /// AVCaptureSession Status
    func captureSession(_ captureSession: STCaptureSession!, didStart avCaptureSession: AVCaptureSession) {
        log("========================== captureSession(_:didStart:) ==========================")
        
        if case .initialized(let session) = self.captureSessionContext {
            session.properties = STCaptureSessionPropertiesSetColorCameraAutoExposureISOAndWhiteBalance()
        }
    }
    
    func captureSession(_ captureSession: STCaptureSession!, didStop avCaptureSession: AVCaptureSession) {
        log("captureSession(_:didStop:)")
        
        // TODO
    }
    
    // Capture Session sample output
    func captureSession(_ captureSession: STCaptureSession!, didOutputSample sample: [AnyHashable : Any]?, type: STCaptureSessionSampleType) {
        log("captureSession(_:didOutputSample:\(sample)type:\(type.rawValue)")
        
        guard let sample = sample else {
//            self.scanningSubject.send(completion: .failure(SystemErrors.scannerInterface(.出力サンプルの取得に失敗)))
            log("Output sample not available")
            return
        }
        
        switch type {
        case .sensorDepthFrame, .synchronizedFrames : do {
            log("====================== sensorDepthFrame | synchronizedFrames")
                
            guard let depthFrame = sample[kSTCaptureSessionSampleEntryDepthFrame] as? STDepthFrame
                  , case .initialized(_, let context, let buffers, let viewport, _, _, let depthAsRgbaTexture, let videoTextureCache) = graphicContext else { return }
                
            // sensorDepthFrameの時は nil で、synchronizedFrames の時のみ値がある
            let colorFrame = sample[kSTCaptureSessionSampleEntryIOSColorFrame] as? STColorFrame
                
            if Options.applyExpensiveCorrectionToDepth {
                assert(!Options.useHardwareRegisteredDepth, "Cannot enable both expensive depth correction and registered depth.")
                if !depthFrame.applyExpensiveCorrection() {
                    log("Warning: could not improve depth map accuracy, is your firmware too old?");
                }
            }
                
            // Upload the new color image for next rendering.
            if let colorFrame = colorFrame {
                log("colorFrame: \(colorFrame)")
                // TODO: SLAM作成系処理の分離。colorFrameを直接渡すのでなく、gl系処理とその他を分ける（じゃないとGLをView側に持っていけない）
                self.uploadGLColorTexture(from: colorFrame, with: videoTextureCache)
                
            } else if case .initialized(_, _, _, _, _, let depthAsRgbaVisualizer, _) = scannerContext {
                log("initialized: \(depthFrame)")
                depthAsRgbaVisualizer.convertDepthFrame(toRgba: depthFrame)
                self.uploadGLColorTexture(
                    depthAsRgbaTexture: depthAsRgbaTexture
                    , width: depthAsRgbaVisualizer.width
                    , height: depthAsRgbaVisualizer.height
                    , pixels: depthAsRgbaVisualizer.rgbaBuffer
                )
            } else if case .scanning(_, _, _, _, _, let depthAsRgbaVisualizer, _, _) = scannerContext {
                log("scanning: \(depthFrame)")
                depthAsRgbaVisualizer.convertDepthFrame(toRgba: depthFrame)
                self.uploadGLColorTexture(
                    depthAsRgbaTexture: depthAsRgbaTexture
                    , width: depthAsRgbaVisualizer.width
                    , height: depthAsRgbaVisualizer.height
                    , pixels: depthAsRgbaVisualizer.rgbaBuffer
                )
            }
            
            // Update the projection matrices since we updated the frames.
            self.depthCameraGLProjectionMatrix = depthFrame.glProjectionMatrix()
            if let colorFrame = colorFrame {
                self.colorCameraGLProjectionMatrix = colorFrame.glProjectionMatrix()
            }
                
            // Depth information
            let distance = self.distanceToTargetInCentimeters(for: depthFrame)
            log("$$$$$$$ distance: \(distance)")
            self.scanningSubject.send(.distance(distance)) // <----- nan
                
            // 共通GL前処理
            // Activate our view framebuffer.
            EAGLContext.setCurrent(context)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), buffers.frameBuffer)
            glViewport(0, 0, buffers.width, buffers.height)
            
            // this changes the background color for the scanning window
            glClearColor(0.0, 0.0, 0.0, 1.0)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            glClear(GLbitfield(GL_DEPTH_BUFFER_BIT))
            glViewport(GLint(viewport[0]), GLint(viewport[1]), GLint(viewport[2]), GLint(viewport[3]))
            
            if case .initialized(
                _ // let scene
                , _ // let tracker
                , let cameraPoseInitializer
                , let cubeRenderer
                , _ // let keyFrameManager
                , _ // depthAsRgbaVisualizer
                , _ // volumeSizeInMeters
            ) = self.scannerContext {
                self.processDepthFrameCubePlacing(depthFrame, colorFrame: colorFrame, depthAsRgbaTexture: depthAsRgbaTexture, cameraPoseInitializer: cameraPoseInitializer, cubeRenderer: cubeRenderer)
                
                // Scene rendering is triggered by new frames to avoid rendering the same view several times.
                self.renderSceneForDepthFrameCubePlacing(
                    depthFrame
                    , colorFrame: colorFrame
                    , graphicContext: self.graphicContext
                    , cameraPoseInitializer: cameraPoseInitializer
                    , cubeRenderer: cubeRenderer
                )
            } else if case .scanning(
                let scene
                , let tracker
                , _ // let cameraPoseInitializer
                , let cubeRenderer
                , let keyFrameManager
                , _ // let depthAsRgbaVisualizer
                , let mapper
                , _ // let volumeSizeInMeters
            ) = self.scannerContext {
                self.processDepthFrameScanning(depthFrame, colorFrame: colorFrame, depthAsRgbaTexture: depthAsRgbaTexture, tracker: tracker, keyFrameManager: keyFrameManager, mapper: mapper)
                
                // Set the mesh transparency depending on the current accuracy.
                let meshRenderingAlpha = getMeshRenderingAlpha(from: tracker.poseAccuracy)
                if meshRenderingAlpha != Float.nan { self.meshRenderingAlpha = meshRenderingAlpha }
                
                // Scene rendering is triggered by new frames to avoid rendering the same view several times.
                self.renderSceneForDepthFrameScanning(
                    depthFrame
                    , colorFrame: colorFrame
                    , graphicContext: self.graphicContext
                    , scene: scene
                    , tracker: tracker
                    , cubeRenderer: cubeRenderer
                )
            }
            
            // 共通GL後処理
            // Check for OpenGL errors
            let err: GLenum = glGetError()
            if err != GLenum(GL_NO_ERROR) { log("glError = \(err)") }
            
            // Display the rendered framebuffer.
            if case .background = UIApplication.shared.applicationState { return }
            
            EAGLContext.setCurrent(context)
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), buffers.colorRenderBuffer)
            if !context.presentRenderbuffer(GLintptr(GL_RENDERBUFFER)) {
                log("glError")
            }
        }
        case .iosColorFrame:
            log("iosColorFrame")
                // Skipping until a pair is returned.
                break
        
        case .deviceMotionData:
            log("deviceMotionData")
            if let deviceMotion = sample[kSTCaptureSessionSampleEntryDeviceMotionData] as? CMDeviceMotion {
                self.processDeviceMotion(deviceMotion, scannerContext: self.scannerContext, error: nil)
            }
        case .unknown:
            log("unknown")
            // cannot throw because as in the Obj C example, because the delegate is not marked throwable
            preconditionFailure("Unknown STCaptureSessionSampleType!")
            
        default:
            log("Skipping Capture Session sample type: \(type)")
        }
    }
    
    
    // _captureSession.lensDetection = STLensDetectorState.offなので呼ばれない
    func captureSession(_ captureSession: STCaptureSession, onLensDetectorOutput detectedLensStatus: STDetectedLensStatus) {
        log("captureSession(_:onLensDetectorOutput:)")
        
        // TODO
    }
}

// MARK: - STBackgroundTaskDelegate プロトコルの実装
extension StructureService : STBackgroundTaskDelegate {
    
    /// Colorizeの進捗を取得する
    /// - Parameters:
    ///   - sender: <#sender description#>
    ///   - progress: <#progress description#>
    func backgroundTask(_ sender: STBackgroundTask?, didUpdateProgress progress: Double) {
        if case .native = self.colorizeContext {
            self.finalizeSubject.send(.didUpdateProgressNativeColorize(progress: progress))
            
        } else if case .enhanced = self.colorizeContext {
            self.finalizeSubject.send(.didUpdateProgressEnhancedColorize(progress: progress))
        }
    }
}
