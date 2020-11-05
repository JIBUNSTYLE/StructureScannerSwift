//
//  Common.swift
//  SwiftScanner
//
//  Created by 斉藤 祐輔 on 2020/10/30.
//  Copyright © 2020 CoderJoris. All rights reserved.
//

import Foundation

struct InitialViewModelRotation {
    static let xAngleDegrees: Float = 35.0
    static let yAngleDegrees: Float = 50.0
}


/// See default initialization in: initializeDynamicOptions()
struct DynamicOptions {
    
    let depthAndColorTrackerIsOn: Bool
    let improvedTrackingIsOn: Bool
    ///
    /// _captureSession: "センサ"の入力解像度、デバイスにより決定。iPad miniはtrue
    ///
    let highResColoring: Bool
    let improvedMapperIsOn: Bool
    let highResMapping: Bool
    let depthStreamPreset: STCaptureSessionPreset
    
    init(
        depthAndColorTrackerIsOn: Bool = true
        , improvedTrackingIsOn: Bool = true
        , highResColoring: Bool = true
        , improvedMapperIsOn: Bool = true
        , highResMapping: Bool = true
        , depthStreamPreset: STCaptureSessionPreset = STCaptureSessionPreset.bodyScanning // 定数：bodyで良いか要確認
    ) {
        self.depthAndColorTrackerIsOn = depthAndColorTrackerIsOn
        self.improvedTrackingIsOn = improvedTrackingIsOn
        self.highResColoring = highResColoring
        self.improvedMapperIsOn = improvedMapperIsOn
        self.highResMapping = highResMapping
        self.depthStreamPreset = depthStreamPreset
    }
    
    
    /// 設定項目の一部を更新して返します。
    ///
    /// - Parameters:
    ///   - depthAndColorTrackerIsOn: <#depthAndColorTrackerIsOn description#>
    ///   - improvedTrackingIsOn: <#improvedTrackingIsOn description#>
    ///   - highResColoring: <#highResColoring description#>
    ///   - improvedMapperIsOn: <#improvedMapperIsOn description#>
    ///   - highResMapping: <#highResMapping description#>
    ///   - depthStreamPreset: <#depthStreamPreset description#>
    func update(
        depthAndColorTrackerIsOn: Bool? = nil
       , improvedTrackingIsOn: Bool? = nil
       , highResColoring: Bool? = nil
       , improvedMapperIsOn: Bool? = nil
       , highResMapping: Bool? = nil
       , depthStreamPreset: STCaptureSessionPreset? = nil
    ) -> Self {
        return Self(
            depthAndColorTrackerIsOn:  depthAndColorTrackerIsOn ?? self.depthAndColorTrackerIsOn
            , improvedTrackingIsOn: improvedTrackingIsOn ?? self.improvedTrackingIsOn
            , highResColoring: highResColoring ?? self.highResMapping
            , improvedMapperIsOn: improvedMapperIsOn ?? self.improvedMapperIsOn
            , highResMapping: highResMapping ?? self.highResColoring
            , depthStreamPreset: depthStreamPreset ?? self.depthStreamPreset
        )
    }
}

// Utility struct to manage a gesture-based scale.
struct PinchScaleState {

    var currentScale: CGFloat = 1
    var initialPinchScale: CGFloat = 1
}


struct AppStatus {
    let pleaseConnectSensorMessage = NSLocalizedString("PLEASE_CONNECT_STRUCTURE_SENSOR", comment: "")
    let pleaseChargeSensorMessage = NSLocalizedString("PLEASE_CHARGE_STRUCTURE_SENSOR", comment: "")

    let needColorCameraAccessMessage = NSLocalizedString("THIS_APP_REQUIRES_CAMERA_ACCESS_SCAN", comment: "")
    let needCalibratedColorCameraMessage = NSLocalizedString("NEED_CALIBRATED_COLOR_CAMERA", comment: "")

    let finalizingMeshMessage = NSLocalizedString("FINALIZING_MESH", comment: "")
    let sensorIsWakingUpMessage = NSLocalizedString("SENSOR_IS_WAKING_UP", comment: "")

    // Whether there is currently a message to show.
    var needsDisplayOfStatusMessage = false

    // Flag to disable entirely status message display.
    var statusMessageDisabled = false
}



let dateFormatter4log: DateFormatter = { format -> DateFormatter in
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = format
    return dateFormatter
}("yyyy/MM/dd HH:mm:ss.SSS")

func log(_ msg: String, file: String = #file, line: Int = #line, function: String = #function) {

    var f = "NONE"

    if let _f = file.components(separatedBy: "/").last {
        f = _f.replacingOccurrences(of: ".swift", with: "")
        f = f.replacingOccurrences(of: "ViewController", with: "Vc")
        f = f.replacingOccurrences(of: "Repository", with: "Rp")
        f = f.replacingOccurrences(of: "Interactor", with: "Ir")
        f = f.replacingOccurrences(of: "Presenter", with: "Ps")
    }

    print("\(f):\(line) [\(function)]: \(msg)")
}
