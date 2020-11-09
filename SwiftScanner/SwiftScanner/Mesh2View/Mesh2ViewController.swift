//
//  Mesh2ViewController.swift
//  SwiftScanner
//
//  Created by 斉藤 祐輔 on 2020/11/09.
//  Copyright © 2020 CoderJoris. All rights reserved.
//

import UIKit
import ZIPFoundation
import SceneKit
import SceneKit.ModelIO

class Mesh2ViewController: UIViewController {
    
    
    @IBOutlet weak var sceneView: SCNView! {
        didSet {
            // 1: Load .obj file
            let scene = SCNScene()
            // 2: Add camera node
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            // 3: Place camera
            cameraNode.position = SCNVector3(x: 0.2, y: -0.5, z: 0.8)
            // 4: Set camera on scene
            // カメラの位置合わせが思うようにいかない
            // デフォルトカメラだときれいに表示される
    //        scene?.rootNode.addChildNode(cameraNode)
            
            // 5: Adding light to scene
            let lightNode = SCNNode()
            lightNode.light = SCNLight()
            lightNode.light?.type = .omni
            lightNode.position = SCNVector3(x: 0, y: 10, z: 35)
            scene.rootNode.addChildNode(lightNode)
            
            // 6: Creating and adding ambien light to scene
            let ambientLightNode = SCNNode()
            ambientLightNode.light = SCNLight()
            ambientLightNode.light?.type = .ambient
            ambientLightNode.light?.color = UIColor.darkGray
            scene.rootNode.addChildNode(ambientLightNode)
            
            // Allow user to manipulate camera
            self.sceneView.allowsCameraControl = true
            
            // Show FPS logs and timming
            // self.sceneView.showsStatistics = true
            
            // Set background color
            self.sceneView.backgroundColor = UIColor.gray
            
            // Allow user translate image
            self.sceneView.cameraControlConfiguration.allowsTranslation = false
            
            // Set scene settings
            self.sceneView.scene = scene
        }
    }
    
    var fileURL: String?
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        
        guard let fileURL = self.fileURL else {
            log("ERROR")
            return
        }
        
        log("■■■■■■■■■■■■■■■■■■  \(fileURL) ■■■■■■■■■■■■■■■■■■■■■")
        
        let fileManager = FileManager.default
        
        do {
            let documentsDir = try fileManager.url(
                for: .documentDirectory
                , in: .userDomainMask
                , appropriateFor: nil
                , create: true)
            
            // お掃除
            let files_before = try fileManager.contentsOfDirectory(at: documentsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            try files_before.forEach { f in
                log("file: \(f.absoluteString)")
                if !f.pathExtension.elementsEqual("zip") {
                    try fileManager.removeItem(at: f)
                }
            }

            try fileManager.unzipItem(at: URL(fileURLWithPath: fileURL), to: documentsDir)
            
            let files_after = try fileManager.contentsOfDirectory(at: documentsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            files_after.forEach { f in
                log("file: \(f.absoluteString)")
            }
            
            // Sceneに直接オブジェクトを貼るとテクスチャをイジれないので、チャイルドノードとして持たせる

            let modelObj                = SCNMaterial()
            // diffuse.contentsにテクスチャを指定する
    //        modelObj.diffuse.contents   = UIImage(named: "Model.jpg")

            let objURL = documentsDir.appendingPathComponent("dummy.obj")
            
            let node = SCNNode(mdlObject: MDLAsset(url: objURL).object(at: 0))
            node.geometry?.materials    = [modelObj]
            self.sceneView.scene?.rootNode.addChildNode(node)
            
        } catch let error {
            log("\(error)")
        }
        
    }
    
    func set(file: String) {
        self.fileURL = file
    }
    

    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destination.
        // Pass the selected object to the new view controller.
    }
    */

}
