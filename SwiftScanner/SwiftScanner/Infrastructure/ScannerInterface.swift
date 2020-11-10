//
//  ScannerInterface.swift
//  SwiftScanner
//
//  Created by 斉藤 祐輔 on 2020/11/04.
//  Copyright © 2020 CoderJoris. All rights reserved.
//

import Combine

enum ScanningContext {
    enum TrackingState {
        case none
             , lost
             , modelIsOutOfView
             , tooClose
             , keepHolding
             , error(_ error: NSError)
    }
    case distance(_ distance: Float)
    case isScannable(_ isScannable: Bool)
    case trackingState(_ state: TrackingState)
}

enum FinalizeContext {
    case didUpdateProgressNativeColorize(progress: Double)
    case succeedToNativeColorize
    case didUpdateProgressEnhancedColorize(progress: Double)
    case succeedToEnhancedColorize
    case finished(_ url: String)
}

protocol ScannerInterface {
    func initialize(layer: CALayer) throws ->  PassthroughSubject<ScanningContext, SystemErrors>
    
    func startModeling() throws
    
    func restartFromCubePlacing()
    
    func finishModeling() throws -> PassthroughSubject<FinalizeContext, SystemErrors>
    
    func terminate()
}

