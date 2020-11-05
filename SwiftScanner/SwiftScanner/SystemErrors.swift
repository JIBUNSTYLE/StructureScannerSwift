//
//  SystemErrors.swift
//  SwiftScanner
//
//  Created by 斉藤 祐輔 on 2020/11/04.
//  Copyright © 2020 CoderJoris. All rights reserved.
//

import Foundation

enum SystemErrors: Error {
    
    enum Development: Error {
        case 未実装
        case キャストに失敗
    }
    
    enum GraphicsInterface: Error {
        case レイヤーのキャストに失敗
        case コンテキストの初期化に失敗
        case eSTextureCacheの作成に失敗
        case フレームバッファの初期化に失敗(status: GLenum)
        case sceneの生成に失敗
        case trackerの生成に失敗
        case cameraPoseInitializerの生成に失敗
        case cubeRendererの生成に失敗
        case keyFrameManagerの生成に失敗
        case depthToRgbaの生成に失敗
        case スキャニングが開始されていません
        case 出力サンプルの取得に失敗
        case mapperの生成に失敗
        case meshの生成に失敗
    }
    
    case development(_ error: Development)
    case graphicsInterface(_ error: GraphicsInterface)
}
