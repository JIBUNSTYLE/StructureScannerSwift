//
//  Constants.swift
//  SwiftScanner
//
//  Created by 斉藤 祐輔 on 2020/11/04.
//  Copyright © 2020 CoderJoris. All rights reserved.
//

import Foundation

/// Volume resolution in meters
/// TODO: ===== Volumeは具体的にはなにのサイズの値か（Cubeのサイズ、スキャン対象領域等）=====
struct Options {
    
    /// The initial scanning volume size
    /// (X is left-right, Y is up-down, Z is forward-back)
    /// setupSLAMで使用（スキャナー設定）
    static let initVolumeSizeInMeters: GLKVector3                  = GLKVector3Make(0.5, 0.5, 0.5)

    /// The maximum number of keyframes saved in keyFrameManager
    /// keyframeの3parameterはすべてAPIデフォルト値と同じ（48, 20, 0.3）
    static let maxNumKeyFrames: Int                                = 48

    /// Take a new keyframe in the rotation difference is higher than 20 degrees.
    static let maxKeyFrameRotation: CGFloat                        = CGFloat(20 * (Double.pi / 180)) // 20 degrees

    /// Take a new keyframe if the translation difference is higher than 30 cm.
    static let maxKeyFrameTranslation: CGFloat                     = 0.3 // 30cm

    /// Colorizer quality
    /// 表示カラーではなさそう、スキャン時のカラー？、要調査
    static let colorizerQuality: STColorizerQuality                = STColorizerQuality.normalQuality

    /// Threshold to consider that the rotation motion was small enough for a frame to be accepted
    /// as a keyframe. This avoids capturing keyframes with strong motion blur / rolling shutter.
    /// 具体的に実験してみないとわからない。
    static let maxKeyframeRotationSpeedInDegreesPerSecond: CGFloat = 1

    /// Whether we should use depth aligned to the color viewpoint when Structure Sensor was calibrated.
    /// This setting may get overwritten to false if no color camera can be used.
    /// 赤外線とカラーカメラどちらに合わせてキューブを表示するかということだろうか。
    static let useHardwareRegisteredDepth: Bool                    = false

    /// Whether to enable an expensive per-frame depth accuracy refinement.
    /// Note: this option requires useHardwareRegisteredDepth to be set to false.
    static let applyExpensiveCorrectionToDepth: Bool               = true

    /// Whether the colorizer should try harder to preserve appearance of the first keyframe.
    /// Recommended for face scans.
    static let prioritizeFirstFrameColor: Bool                     = true

    /// Target number of faces of the final textured mesh.
    static let colorizerTargetNumFaces: Int                        = 50000

    /// Focus position for the color camera (between 0 and 1). Must remain fixed one depth streaming
    /// has started when using hardware registered depth.
    static let lensPosition: CGFloat                               = 0.75
}

