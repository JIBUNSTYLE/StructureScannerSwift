//
//    This file is a Swift port of the Structure SDK sample app "Scanner".
//    Copyright © 2016 Occipital, Inc. All rights reserved.
//    http://structure.io
//
//  ViewController.swift
//
//  Ported by Christopher Worley on 8/20/16.
//
//  Ported to Swift 5 by Windmolders Joris on 03/06/2020.
//  - Renamed to ScanViewController.swift
//  - Support closing the scan view
//  - Using segues
//  - Added distance label
//

import Foundation
import UIKit
import os.log
import Combine

enum ScanState {
    case unkown, cubePlacing, scanning, viewing
}

class ScanViewController: UIViewController {
    @IBOutlet weak var eview: EAGLView!

    @IBOutlet weak var appStatusMessageLabel: UILabel!
    @IBOutlet weak var scanButton: UIButton!
    @IBOutlet weak var resetButton: UIButton!
    @IBOutlet weak var doneButton: UIButton!
    @IBOutlet weak var trackingLostLabel: UILabel!
    @IBOutlet weak var backButton: UIButton!
    @IBOutlet weak var distanceLabel: UILabel!
    @IBOutlet weak var sensorBatteryLowImage: UIImageView!
    @IBOutlet weak var batteryLabel: UILabel!
    
    var state: ScanState = .unkown

    // Structure Sensor controller.
    //var _structureStreamConfig: STStreamConfig

    // Manages the app status messages.
    var _appStatus = AppStatus.init()

    // Most recent gravity vector from IMU.
    var _lastGravity: GLKVector3!

    // Scale of the scanning volume.
    var _volumeScale = PinchScaleState()

    // Mesh viewer controllers.
    var meshViewController: MeshViewController? = nil

    var _naiveColorizeTask: STBackgroundTask? = nil
    var _enhancedColorizeTask: STBackgroundTask? = nil
    var _depthAsRgbaVisualizer: STDepthToRgba? = nil
 
    weak var scanBuffer : ScanBufferDelegate?
    
    var cancellables = [AnyCancellable]()
    
    // DONE: ステータスバー
    // Make sure the status bar is disabled (iOS 7+)
    override var prefersStatusBarHidden : Bool {
        return true
    }
    
    // MARK: - LifeCycleメソッド

    deinit {
        Implementations.shared.scanner.terminate()
        
        os_log(.debug, log:OSLog.scanning, "unregistering app notification handlers")
        
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        
        os_log(.debug, log:OSLog.scanning, "ViewController deinit called")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.batteryLabel.text = ""
        self.sensorBatteryLowImage.isHidden = true
        self.scanButton.isHidden = true
        self.doneButton.isHidden = true
        self.backButton.isHidden = true

        // Do any additional setup after loading the view.
        _enhancedColorizeTask = nil
        _naiveColorizeTask = nil
        
        distanceLabel.layer.cornerRadius = 20

        os_log(.debug, log:OSLog.scanning, "Setting up GL/Capture Session/SLAM")

        do {
            _ = try Implementations.shared.scanner.initialize(layer: self.eview.layer)
                .sink(receiveCompletion: { completion in
                    if case .finished = completion {
                        log("正常終了")
                    } else if case .failure(let error) = completion {
                        log("\(error)")
                    }
                }, receiveValue: { context in
                    print("@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@")
                    switch context {
                    case .distance(let distance): do {
                        log("$$$$$$$ distance: \(distance) $$$$$$$")
                        self.showDistanceToTargetAndHeelIndicator(distance)
                    }
                    case .trackingState(let state): do {
                        log("@@@@@@@ trackingState: \(state) @@@@@@@")
                        switch state {
                        case .none:
                            self.hideTrackingErrorMessage()
                        case .lost:
                            self.showTrackingMessage("TRACKING_LOST_PLEASE_REALIGN")
                        case .keepHolding:
                            self.showTrackingMessage("PLEASE_HOLD_STILL")
                        case .modelIsOutOfView:
                            self.showTrackingMessage("PUT_MODEL_BACK_IN_VIEW")
                        case .tooClose:
                            self.showTrackingMessage("PLEASE_STEP_BACK")
                        case .error(let error):
                            log("\(error)")
                        }
                    }
                    case .isScannable(let isScannable): do {
                        log("%%%%%%% isScannable: \(isScannable) %%%%%%%")
                        self.scanButton.isEnabled = isScannable
                    }
                    }
                })
                .store(in: &cancellables)
        } catch let error {
            log("error \(error)")
        }

        os_log(.debug, log:OSLog.scanning, "Setting up User Interface")

        // Fully transparent message label, initially.
        appStatusMessageLabel.alpha = 0
        // Make sure the label is on top of everything else.
        appStatusMessageLabel.layer.zPosition = 100

        //os_log(.debug, log:OSLog.scanning, "Setting up Mesh view controller")

        //setupMeshViewController()
        
        os_log(.debug, log:OSLog.scanning, "Setting up Capture Session")


        os_log(.debug, log:OSLog.scanning, "Registering app notification handlers")
        
        // Make sure we get notified when the app becomes active to start/restore the sensor state if necessary.
        NotificationCenter.default.addObserver(self, selector: #selector(ScanViewController.appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        
        enterCubePlacementState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // The framebuffer will only be really ready with its final size after the view appears.
        
        // TODO
//        self.eview.setFramebuffer()
//        setupGLViewport()

            // TODO
//        updateAppStatusMessage()

        // We will connect to the sensor when we receive appDidBecomeActive.
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // in an unwind segue, the view controller is dismissed
        // in a modal segue, the view controller is not dismissed
        if isBeingDismissed {
            cleanup()
        }
    }
    
    // DONE: appがバックグラウンドからアクティブになったときに呼ばれる（ => registerNotificationHandlersで登録）
    @objc func appDidBecomeActive() {

        os_log(.debug, log:OSLog.scanning, "App did become active")

        runBatteryStatusTimer()
        // TODO
//        if currentStateNeedsSensor() {
//            _captureSession?.streamingEnabled = true;
//        }
        
        // Abort the current scan if we were still scanning before going into background since we
        // are not likely to recover well.
//        if _slamState.scannerState == .scanning {
//            resetButtonPressed(resetButton)
//        }
    }
    
    // PENDING
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        respondToMemoryWarning()
    }
    
    // MARK - User Action

    
    // DOING: prepare（遷移時）で呼ばれる
    // ayameではSceneKit画面に行くので必要ない？
    // ここで渡しているmeshさへあれば、テクスチャの素材にできるのか？
    // 行わているのはGLの処理（描画）
    
    // TODO
    func setupMeshViewController(meshViewController: MeshViewController, mesh: STMesh) {
        
        meshViewController.scanView = self
        meshViewController.scanBuffer = self.scanBuffer // MainVCにmeshを渡すのに使っている（ネーミング意味不）
        meshViewController.colorizer = self

//        meshViewController.setup(context: display!.context!, with: mesh)
        meshViewController.colorEnabled = true
//        meshViewController.setCameraProjectionMatrix(_display!.depthCameraGLProjectionMatrix)

        // Sample a few points to estimate the volume center
        let totalNumVertices = [Int32](0..<mesh.numberOfMeshes())
            .reduce(into: 0) { (sum, i) in
                sum += mesh.number(ofMeshVertices: Int32(i))
            }
        
        // The sample step if we need roughly 1000 sample points
        let sampleStep = Int(max(1, totalNumVertices / 1000))
        var (sampleCount, volumeCenter) = [Int32](0..<mesh.numberOfMeshes())
            .reduce(into: (0, GLKVector3Make(0, 0, 0))) { (ret, i) in
                guard let vertex = mesh.meshVertices(Int32(i)) else { return }
                
                let numVertices = Int(mesh.number(ofMeshVertices: i))
                for j in stride(from: 0, to: numVertices, by: sampleStep) {
                    let v = vertex[Int(j)]
                    ret.0 += 1
                    ret.1 = GLKVector3Add(ret.1, v)
                }
            }
        
        
        if sampleCount > 0 {
            volumeCenter = GLKVector3DivideScalar(volumeCenter, Float(sampleCount))
        } else {
            // TODO
//            volumeCenter = GLKVector3MultiplyScalar(_slamState.volumeSizeInMeters, 0.5)
        }
        
        meshViewController.resetMeshCenter(volumeCenter)
        meshViewController.showColorRenderingMode()
        
        self.meshViewController = meshViewController
    }

    // DONE: viewDidLoad/setupSLAM（viewDidLoad/onSLAMOptionsChanged）/resetSLAM(onSLAMOptionsChanged/resetButton/unwind/cleanup)で呼ばれる
    // 状態変更：キューブ表示
    func enterCubePlacementState() {

        // Only show the scan buttons if the sensor is ready
        // To avoid flickering on and off when initially connecting
        // TODO
//        if _captureSession?.sensorMode == .ready {
            showScanControls()
//        }
        
        // Cannot be lost in cube placement mode.
        trackingLostLabel.isHidden = true

        updateIdleTimer()
        
        self.state = .cubePlacing
    }

    // DONE: stopButtonPressed/memoryWarningで呼ばれる
    // 状態変更：スキャン終了
    // Note: the "enterViewingState" method from the sample app is split into stopScanningState and enterViewingState
    // 状態を変えているだけで、何かを明示的に終了している様子はない。
    private func stopScanningState() {
        // Cannot be lost in view mode.
        trackingLostLabel.isHidden = true
        
        _appStatus.statusMessageDisabled = true
//        updateAppStatusMessage()
        
        // Hide the Scan/Done/Reset/Autostop button.
        scanButton.isHidden = true
        doneButton.isHidden = true
        resetButton.isHidden = true

        // never hide the back button
        backButton.isHidden = false

        // TODO
//        if let isWriting = _captureSession?.occWriter.isWriting, isWriting {
//            if let success = _captureSession?.occWriter.stopWriting(), !success {
                // Should fail instead - but not using OCC anyway
                   os_log(.error, log:OSLog.scanning, "Could not properly stop OCC writer.")
//               }
//           }
        
//        _captureSession?.streamingEnabled = false;
    }
    
    // DONE: doneButtonPressed/memoryWarningで呼ばれる
    // 状態変更：画面遷移
    private func enterViewingState() {
        log("=========================== enterViewingState")
      
//        let mesh = try! Implementations.shared.scanner.finishModeling()
        
//        let storyboard = UIStoryboard(name: "Mesh", bundle: self.nibBundle)
//        guard let meshViewController = storyboard.instantiateInitialViewController() as? MeshViewController else {
//            fatalError()
//        }
//
//        self.setupMeshViewController(meshViewController: meshViewController, mesh: mesh)
//        self.present(meshViewController, animated: true, completion: nil)
        
        _ = try! Implementations.shared.scanner.finishModeling()
            .sink(receiveCompletion: { completion in
                if case .finished = completion {
                    log("正常終了")
                } else if case .failure(let error) = completion {
                    log("error: \(error)")
                }
            }, receiveValue: { context in
                switch context {
                case .didUpdateProgressNativeColorize(let progress):
                    log(">>>>>>>>>> \(progress) - native")
                case .succeedToNativeColorize:
                    log("========== succeedToNativeColorize")
                case .didUpdateProgressEnhancedColorize(let progress):
                    log(">>>>>>>>>> \(progress) - enhanced")
                case .succeedToEnhancedColorize: break
                case .finished(let url): DispatchQueue.main.async {
                    log("========== finished: \(url)")
                    let storyboard = UIStoryboard(name: "Mesh2", bundle: self.nibBundle)
                    guard let mesh2ViewController = storyboard.instantiateInitialViewController() as? Mesh2ViewController else {
                        fatalError()
                    }
                    
                    mesh2ViewController.set(file: url)
                    self.present(mesh2ViewController, animated: true, completion: nil)
                    
                    self.state = .viewing
                    self.updateIdleTimer()
                    
                    Implementations.shared.scanner.terminate()
                }
                }
            }).store(in: &cancellables)
    }

    //MARK: -  Structure Sensor Management
    

    // MARK: - User Actions
    
    
    @IBAction func backButtonDidPush(_ sender: UIButton) {
        os_log("unwinding segue unwindMeshToScanView", log: OSLog.meshView, type: .debug)
        
        if self.meshViewController != nil {
            self.meshViewController = nil
        }
        _appStatus.statusMessageDisabled = false
//            updateAppStatusMessage()
        
        self.dismiss(animated: true, completion: nil)
    }

    
    // DONE:
    @IBAction func scanButtonPressed(_ sender: UIButton) {
        // Uncomment the following lines to enable OCC writing
        /*
        let success = _captureSession.occWriter.startWriting("[AppDocuments]/Scanner.occ", appendDateAndExtension:false);
        
        if (!success)
        {
            os_log(.error, log:OSLog.scanning, "Could not properly start OCC writer.");
        }*/

        // This can happen if the UI did not get updated quickly enough.
//        if !_slamState.cameraPoseInitializer!.lastOutput.hasValidPose.boolValue {
//            os_log(.error, log:OSLog.scanning, "Not accepting to enter into scanning state since the initial pose is not valid.")
//            return
//        }

        os_log(.debug, log:OSLog.scanning, "Enter Scanning state")

        // Show/Hide buttons.
        scanButton.isHidden = true
        resetButton.isHidden = false
        backButton.isHidden = false
        doneButton.isHidden = false

        // We will lock exposure during scanning to ensure better coloring.
        // Acceptはここで落ちる
//        _captureSession?.properties = STCaptureSessionPropertiesLockAllColorCameraPropertiesToCurrent();

        do {
            try Implementations.shared.scanner.startModeling()
            self.state = .scanning
        } catch let error {
            log("error\(error)")
            fatalError()
        }
    }

    // DONE:
    @IBAction func resetButtonPressed(_ sender: UIButton) {
        // TODO reserModeing
        Implementations.shared.scanner.restartFromCubePlacing()
        enterCubePlacementState()
    }

    // DONE:
    @IBAction func doneButtonPressed(_ sender: UIButton) {
        self.enterViewingState()
    }
    
    // MARK: -
    
    // DONE: 設定画面で使うが、このサンプルはそこまで書いていない
//    func onSLAMOptionsChanged() {
//
//        // A full reset to force a creation of a new tracker.
//        resetSLAM()
//        clearSLAM()
//        setupSLAM()
//
//        // Restore the volume size cleared by the full reset.
//        adjustVolumeSize( volumeSize: _slamState.volumeSizeInMeters)
//    }
    
//    func isStructureConnected() -> Bool {
//
//        guard let captureSession = _captureSession else {
//            return false
//        }
//
//        return captureSession.sensorMode.rawValue > STCaptureSessionSensorMode.notConnected.rawValue;
//    }
    
    // DONE
    // Manages whether we can let the application sleep.
    func updateIdleTimer() {
        // TODOs
//        if isStructureConnected() {
            // Do not let the application sleep if we are currently using the sensor data.
            UIApplication.shared.isIdleTimerDisabled = true
//        } else {
//            // Let the application sleep if we are only viewing the mesh or if no sensors are connected.
//            UIApplication.shared.isIdleTimerDisabled = false
//        }
    }
    
    // DONE
    func showTrackingMessage(_ message: String) {
        trackingLostLabel.text = message
        trackingLostLabel.isHidden = false
        distanceLabel.isHidden = true
    }
    
    // DONE
    func hideTrackingErrorMessage() {
        trackingLostLabel.isHidden = true
    }

    func showAppStatusMessage(_ msg: String) {
        if Thread.current.isMainThread {
            self.showAppStatusMessage_OnMainThread(msg)
        }
        else{
            DispatchQueue.main.async {
                self.showAppStatusMessage_OnMainThread(msg)
            }
        }
    }

    private func showAppStatusMessage_OnMainThread(_ msg: String) {
        assert(Thread.current.isMainThread)

        self.hideScanControls()
        
        _appStatus.needsDisplayOfStatusMessage = true
        view.layer.removeAllAnimations()
        
        appStatusMessageLabel.text = msg
        appStatusMessageLabel.isHidden = false
        
        // Progressively show the message label.
        view!.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.5, animations: {
            self.appStatusMessageLabel.alpha = 1.0
        })
        view!.isUserInteractionEnabled = true
    }

    func hideAppStatusMessage() {
        if Thread.current.isMainThread {
            self.hideAppStatusMessage_OnMainThread()
        }
        else{
            DispatchQueue.main.async {
                self.hideAppStatusMessage_OnMainThread()
            }
        }
    }
    
    func hideAppStatusMessage_OnMainThread() {
        assert(Thread.current.isMainThread)
        
        if !_appStatus.needsDisplayOfStatusMessage {
            return
        }

        _appStatus.needsDisplayOfStatusMessage = false
        view.layer.removeAllAnimations()

        UIView.animate(withDuration: 0.5, animations: {
            self.appStatusMessageLabel.alpha = 0
            }, completion: { _ in
                // If nobody called showAppStatusMessage before the end of the animation, do not hide it.
                if !self._appStatus.needsDisplayOfStatusMessage {

                    // Could be nil if the self is released before the callback happens.
                    if self.view != nil {
                        self.appStatusMessageLabel.isHidden = true
                        self.view.isUserInteractionEnabled = true
                        
//                        guard let captureSession = self._captureSession else {
//                            os_log(.info, log:OSLog.scanning, "Prevented crash when returning from scan view")
//                            return
//                        }
                        
                        // Restore the scan controls that were hidden for displaying the message, but only
                        // if the sensor is ready, otherwise other messages may follow and the scan controls
                        // will appear to flicker on and off
                        
                        // TODO
//                        if (captureSession.sensorMode == .ready) && (self._slamState.scannerState == .cubePlacement)
//                        {
//                            self.showScanControls()
//                        }
                    }
                }
        })
    }

//    func updateAppStatusMessage() {
//
//        // Skip everything if we should not show app status messages (e.g. in viewing state).
//        if _appStatus.statusMessageDisabled {
//            hideAppStatusMessage()
//            return
//        }
//
//        let userInstructions = captureSession.userInstructions
//
//        let needToConnectSensor = userInstructions.contains(.needToConnectSensor)
//        let needToChargeSensor = userInstructions.contains(.needToChargeSensor)
//        let needToAuthorizeColorCamera = userInstructions.contains(.needToAuthorizeColorCamera)
//        //let needToUpgradeFirmware = userInstructions.contains(.firmwareUpdateRequired)
//
//        // If you don't want to display the overlay message when an approximate calibration
//        // is available use `_captureSession.calibrationType >= STCalibrationTypeApproximate`
//        //let needToRunCalibrator = userInstructions.contains(.needToRunCalibrator)
//
//        if (needToConnectSensor)
//        {
//            showAppStatusMessage(_appStatus.pleaseConnectSensorMessage)
//            return;
//        }
//
//        if (captureSession.sensorMode == .wakingUp)
//        {
//            showAppStatusMessage(_appStatus.sensorIsWakingUpMessage)
//            return;
//        }
//
//        if (needToChargeSensor)
//        {
//            showAppStatusMessage(_appStatus.pleaseChargeSensorMessage)
//        }
//
//        // Color camera permission issues.
//        if (needToAuthorizeColorCamera)
//        {
//            showAppStatusMessage(_appStatus.needColorCameraAccessMessage)
//            return;
//        }
//
//        // If we reach this point, no status to show.
//        hideAppStatusMessage()
//    }
    
    // DONE: ayameでは固定になるはず
    @IBAction func pinchGesture(_ sender: UIPinchGestureRecognizer) {

        if sender.state == .began {
            if case .cubePlacing = self.state {
                _volumeScale.initialPinchScale = _volumeScale.currentScale / sender.scale
            }
        } else if sender.state == .changed {

            if case .cubePlacing = self.state  {

                // In some special conditions the gesture recognizer can send a zero initial scale.
                if !_volumeScale.initialPinchScale.isNaN {

                    _volumeScale.currentScale = sender.scale * _volumeScale.initialPinchScale

                    // Don't let our scale multiplier become absurd
                    
                    // TODO
//                    _volumeScale.currentScale = CGFloat(keepInRange(Float(_volumeScale.currentScale), minValue: 0.01, maxValue: 1000))
//
//                    let newVolumeSize: GLKVector3 = GLKVector3MultiplyScalar(_options.initVolumeSizeInMeters, Float(_volumeScale.currentScale))
//
//                    adjustVolumeSize( volumeSize: newVolumeSize)
                }
            }
        }
    }
        
    private func stopScanning() {
        stopScanningState()
    }

    private func hideScanControls() {
        self.scanButton.isHidden = true
        self.distanceLabel.isHidden = true
        self.resetButton.isHidden = true
    }

    internal func showScanControls() {
        scanButton.isHidden = false
        doneButton.isHidden = true
        resetButton.isHidden = true
        backButton.isHidden = false
    }
    
    // 色を付ける場合に呼ばれる
    func performEnhancedColorize(_ mesh: STMesh, enhancedCompletionHandler: @escaping () -> Void) {

//        let handler = DispatchWorkItem { [weak self] in
//            enhancedCompletionHandler()
//            self?.meshViewController?.mesh = mesh
//        }
//
//        let colorizeCompletionHandler: (Error?) -> Void = { [weak self] error in
//            if error != nil {
//                os_log(.error, log:OSLog.scanning, "Error during colorizing: %{Public}@", error!.localizedDescription)
//            } else {
//                DispatchQueue.main.async(execute: handler)
//
//                self?._enhancedColorizeTask?.delegate = nil
//                self?._enhancedColorizeTask = nil
//            }
//        }
//
//        // TODO
//        _enhancedColorizeTask = try! STColorizer.newColorizeTask(
//            with: mesh
//            , scene: _slamState.scene
//            , keyframes: _slamState.keyFrameManager!.getKeyFrames()
//            , completionHandler: colorizeCompletionHandler
//            , options: [
//                kSTColorizerTypeKey : STColorizerType.textureMapForObject.rawValue
//                , kSTColorizerPrioritizeFirstFrameColorKey: _options.prioritizeFirstFrameColor
//                , kSTColorizerQualityKey: _options.colorizerQuality.rawValue
//                , kSTColorizerTargetNumberOfFacesKey: _options.colorizerTargetNumFaces
//            ]
//        )
//
//        if _enhancedColorizeTask != nil {
//
//            // We don't need the keyframes anymore now that the final colorizing task was started.
//            // Clearing it now gives a chance to early release the keyframe memory when the colorizer
//            // stops needing them.
//            _slamState.keyFrameManager!.clear()
//
//            os_log(.debug, log:OSLog.scanning, "Starting enhanced colorizing task")
//            _enhancedColorizeTask!.delegate = self
//            _enhancedColorizeTask!.start()
//        }
    }
    
    func respondToMemoryWarning() {
        // TODO
//        os_log(.debug, log:OSLog.scanning, "respondToMemoryWarning")
//        switch _slamState.scannerState {
//        case .viewing:
//            // If we are running a colorizing task, abort it
//            if _enhancedColorizeTask != nil && !_slamState.showingMemoryWarning {
//
//                _slamState.showingMemoryWarning = true
//
//                // stop the task
//                _enhancedColorizeTask!.cancel()
//                _enhancedColorizeTask = nil
//
//                // hide progress bar
//                self.meshViewController?.hideMeshViewerMessage()
//
//                let alertCtrl = UIAlertController(
//                    title: NSLocalizedString("MEMORY_LOW", comment: ""),
//                    message: NSLocalizedString("COLORIZING_WAS_CANCELED", comment: ""),
//                    preferredStyle: .alert)
//
//                let handler : (UIAlertAction) -> Void = {[weak self] _ in
//                    self?._slamState.showingMemoryWarning = false
//                }
//
//                let okAction = UIAlertAction(
//                    title: NSLocalizedString("OK", comment: ""),
//                    style: .default,
//                    handler: handler)
//
//                alertCtrl.addAction(okAction)
//
//                // show the alert in the meshViewController
//                self.meshViewController?.present(alertCtrl, animated: true, completion: nil)
//            }
//
//        case .scanning:
//
//            if !_slamState.showingMemoryWarning {
//
//                _slamState.showingMemoryWarning = true
//
//                let alertCtrl = UIAlertController(
//                    title: NSLocalizedString("MEMORY_LOW", comment: ""),
//                    message: NSLocalizedString("SCANNING_WILL_BE_STOPPED", comment: ""),
//                    preferredStyle: .alert)
//
//                let handler : (UIAlertAction) -> Void = {[weak self] _ in
//                    self?._slamState.showingMemoryWarning = false
//                    self?.stopScanningState()
//                    self?.enterViewingState()
//                }
//
//                let okAction = UIAlertAction(
//                    title: NSLocalizedString("OK", comment: ""),
//                    style: .default,
//                    handler: handler)
//
//                alertCtrl.addAction(okAction)
//
//                // show the alert
//                present(alertCtrl, animated: true, completion: nil)
//            }
//
//        default:
//            // not much we can do here
//            break
//        }
    }

    
    //MARK: - Battery
    var batteryStatusTimer = Timer()
    //DONE: Timerで実行する間隔
    var batteryStatusRefreshSeconds: Double = 3.0
    
    //DONE: ConnectToStructureScannerからしか呼ばれていない（つまりバックグラウンドから戻ったときだけ）
    private func runBatteryStatusTimer() {
        stopBatteryStatusTimer()
        //DONE: https://qiita.com/KikurageChan/items/5b33f95cbec9e0d8a05f
        batteryStatusTimer = Timer.scheduledTimer(timeInterval: batteryStatusRefreshSeconds, target: self,   selector: (#selector(ScanViewController.updateBatteryStatus)), userInfo: nil, repeats: true)
    }
    
    private func stopBatteryStatusTimer() {
        // DONE: Timerインスタンスを破棄
        batteryStatusTimer.invalidate()
    }
    
    // DONE: runBatteryStatusTimerからしか呼ばれない
    // バックグラウンドから戻ったときだけでなく、常時チェックしても良い気がするが、
    // 5%未満だとバッテリー残量が表示される。
    @objc internal func updateBatteryStatus() {

        // TODO
//        if let level = _captureSession?.sensorBatteryLevel {
//            let pcttext = String(format: "%02d", level)
//            self.batteryLabel.text = "Sensor battery: \(pcttext)%"
//            self.sensorBatteryLowImage.isHidden = level > 5
//        }
//        else {
            self.batteryLabel.text = ""
            self.sensorBatteryLowImage.isHidden = true
//        }
   }
    
    //MARK: - Distance to Target
    
    internal func showDistanceToTargetAndHeelIndicator(_ distance: Float) {
        if distance != Float.nan {
            let distanceFormatString = NSLocalizedString("__0__CM", comment: "")
            let formattedDistance = String(format: distanceFormatString, distance)
            let formattedDistanceNan = NSLocalizedString("NAN_CM", comment: "")
            if formattedDistance == formattedDistanceNan {
                distanceLabel.text = ""
                distanceLabel.isHidden = true
            }
            else {
                distanceLabel.isHidden = false
                distanceLabel.text = formattedDistance
                distanceLabel.backgroundColor = VisualSettings.sharedInstance.colorMap.get(at: CGFloat(distance))
            }
        }
        else {
            distanceLabel.text = ""
            distanceLabel.isHidden = true
        }
    }
    
}

// MARK: - STBackgroundTaskDelegate プロトコルの実装
// 色をつけるところで呼ばれている
extension ScanViewController : STBackgroundTaskDelegate {
    
    func backgroundTask(_ sender: STBackgroundTask!, didUpdateProgress progress: Double) {
        let processingStringFormat = NSLocalizedString("PROCESSING_PCT__0__", comment: "")

        if sender == _naiveColorizeTask {
            DispatchQueue.main.async(execute: {
                self.meshViewController?.showMeshViewerMessage(String(format: processingStringFormat, Int(progress*20)))
            })
        } else if sender == _enhancedColorizeTask {

            DispatchQueue.main.async(execute: {
                self.meshViewController?.showMeshViewerMessage(String(format: processingStringFormat, Int(progress*80)+20))
            })
        }
    }
}

// MARK: - ColorizeDelegate プロトコルの実装
extension ScanViewController : ColorizeDelegate {

    internal func stopColorizing() {

        // If we are running colorize work, we should cancel it.
        if _naiveColorizeTask != nil {
            _naiveColorizeTask!.cancel()
            _naiveColorizeTask = nil
        }

        if _enhancedColorizeTask != nil {
            _enhancedColorizeTask!.cancel()
            _enhancedColorizeTask = nil
        }
        
        self.meshViewController?.hideMeshViewerMessage()
    }

    
    /// MeshViewControllerで色を付けるときに呼ばれる
    /// - Parameters:
    ///   - mesh: <#mesh description#>
    ///   - previewCompletionHandler: <#previewCompletionHandler description#>
    ///   - enhancedCompletionHandler: <#enhancedCompletionHandler description#>
    /// - Returns: <#description#>
    func meshViewDidRequestColorizing(_ mesh: STMesh, previewCompletionHandler: @escaping () -> Void, enhancedCompletionHandler: @escaping () -> Void) -> Bool {
        // TODO

        os_log(.debug, log:OSLog.scanning, "meshViewDidRequestColorizing")

//        if let _ = _naiveColorizeTask, let _ = _enhancedColorizeTask { // already one running
//            os_log(.debug, log:OSLog.scanning, "Already running background task!")
//            return false
//        }
//
//        let handler = DispatchWorkItem { [weak self] in
//            previewCompletionHandler() // ← ログ出してるだけ
//            self?.meshViewController?.mesh = mesh
//            self?.performEnhancedColorize(
//                mesh
//                , enhancedCompletionHandler: enhancedCompletionHandler // ← hideMeshMessage
//            )
//        }
//
//        let colorizeCompletionHandler : (Error?) -> Void = { [weak self] error in
//            if error != nil {
//                os_log(.error, log:OSLog.scanning, "Error during colorizing: %{Public}@", error?.localizedDescription ?? "Unknown Error")
//            } else {
//                DispatchQueue.main.async(execute: handler)
//                self?._naiveColorizeTask?.delegate = nil
//                self?._naiveColorizeTask = nil
//            }
//        }
//
//        do {
//            _naiveColorizeTask = try STColorizer.newColorizeTask(
//                with: mesh
//                , scene: _slamState.scene
//                , keyframes: _slamState.keyFrameManager!.getKeyFrames()
//                , completionHandler: colorizeCompletionHandler
//                , options: [
//                    kSTColorizerTypeKey : STColorizerType.perVertex.rawValue
//                    , kSTColorizerPrioritizeFirstFrameColorKey: _options.prioritizeFirstFrameColor
//                ]
//            )
//
//            if _naiveColorizeTask != nil {
//                // Release the tracking and mapping resources. It will not be possible to resume a scan after this point
//                _slamState.mapper!.reset()
//                _slamState.tracker!.reset()
//
//                os_log(.debug, log:OSLog.scanning, "Assigning delegate to naive colorizing task")
//                _naiveColorizeTask?.delegate = self
//
//                os_log(.debug, log:OSLog.scanning, "Starting naive colorizing task")
//                _naiveColorizeTask?.start()
//
//                return true
//            }
//        } catch {
//            os_log(.error, log:OSLog.scanning, "Exception while creating colorize task: %{Public}@", error.localizedDescription)
//            return false
//        }

        return true
    }
}

// MARK: - ScanViewDelegate プロトコルの実装
extension ScanViewController : ScanViewDelegate {
    internal func cleanup()
    {
        self.stopBatteryStatusTimer()
        
//        _captureSession?.streamingEnabled = false
//
//        resetSLAM()
//        clearSLAM()
        
        if self.meshViewController != nil {
            self.meshViewController = nil
        }

//        _captureSession?.delegate = nil
                
        os_log(.debug, log:OSLog.scanning, "ViewController dismissed")
    }
}


// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertToUIApplicationOpenExternalURLOptionsKeyDictionary(_ input: [String: Any]) -> [UIApplication.OpenExternalURLOptionsKey: Any] {
    return Dictionary(uniqueKeysWithValues: input.map { key, value in (UIApplication.OpenExternalURLOptionsKey(rawValue: key), value)})
}

