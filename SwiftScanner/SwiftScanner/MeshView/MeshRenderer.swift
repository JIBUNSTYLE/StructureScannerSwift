//
//    This file is a Swift port of the Structure SDK sample app "Scanner".
//    Copyright © 2016 Occipital, Inc. All rights reserved.
//    http://structure.io
//
//  MeshRenderer.swift
//
//  Ported by Christopher Worley on 8/20/16.
//
//  Ported to Swift 5 by Windmolders Joris on 03/06/2020.
//


import Foundation
import os.log

let MAX_MESHES: Int = 30

enum RendererContext {
    case unknown
    case initialized(
            textureUnit: GLenum
            , vertexVbo: [GLuint]
            , normalsVbo: [GLuint]
            , colorsVbo: [GLuint]
            , texcoordsVbo: [GLuint]
            , facesVbo: [GLuint]
            , linesVbo: [GLuint]
         )
}

class MeshRenderer: NSObject {

    enum RenderingMode: Int {
        case xRay = 0
        case perVertexColor
        case textured
        case lightedGray
    }

    struct PrivateData {

        var lightedGrayShader: LightedGrayShader?
        var perVertexColorShader: PerVertexColorShader?
        var xRayShader: XrayShader?
        var yCbCrTextureShader: YCbCrTextureShader?

        var numUploadedMeshes: Int = 0
        var numTriangleIndices = [Int](repeating: 0, count: MAX_MESHES)
        var numLinesIndices = [Int](repeating: 0, count: MAX_MESHES)

        var hasPerVertexColor: Bool = false
        var hasPerVertexNormals: Bool = false
        var hasPerVertexUV: Bool = false
        var hasTexture: Bool = false

        // OpenGL Texture reference for y and chroma images.
        var lumaTexture: CVOpenGLESTexture? = nil
        var chromaTexture: CVOpenGLESTexture? = nil

        // OpenGL Texture cache for the color texture.
        var textureCache: CVOpenGLESTextureCache? = nil

        // Current render mode.
        var currentRenderingMode: RenderingMode = .lightedGray

        internal init() {

            lightedGrayShader = LightedGrayShader()
            perVertexColorShader = PerVertexColorShader()
            xRayShader = XrayShader()
            yCbCrTextureShader = YCbCrTextureShader()
        }
    }

    var d: PrivateData! = PrivateData()
    

    func initialize(with defaultTextureUnit: GLenum = GLenum(GL_TEXTURE3)) -> RendererContext {
        // Vertex buffer objects.
        var vertexVbo = [GLuint](repeating: 0, count: MAX_MESHES)
        var normalsVbo = [GLuint](repeating: 0, count: MAX_MESHES)
        var colorsVbo = [GLuint](repeating: 0, count: MAX_MESHES)
        var texcoordsVbo = [GLuint](repeating: 0, count: MAX_MESHES)
        var facesVbo = [GLuint](repeating: 0, count: MAX_MESHES)
        var linesVbo = [GLuint](repeating: 0, count: MAX_MESHES)
        
        glGenBuffers( GLsizei(MAX_MESHES), &vertexVbo)
        glGenBuffers( GLsizei(MAX_MESHES), &normalsVbo)
        glGenBuffers( GLsizei(MAX_MESHES), &colorsVbo)
        glGenBuffers( GLsizei(MAX_MESHES), &texcoordsVbo)
        glGenBuffers( GLsizei(MAX_MESHES), &facesVbo)
        glGenBuffers( GLsizei(MAX_MESHES), &linesVbo)
        
        return .initialized(
            textureUnit: defaultTextureUnit // Texture unit to use for texture binding/rendering.
            , vertexVbo: vertexVbo
            , normalsVbo: normalsVbo
            , colorsVbo: colorsVbo
            , texcoordsVbo: texcoordsVbo
            , facesVbo: facesVbo
            , linesVbo: linesVbo
        )
    }
    
    func terminate(with context: RendererContext) {
        self.releaseGLBuffers(with: context)
        self.releaseGLTextures()
        self.meshRendererDestructor(with: context)
    }

    deinit {
        self.d = nil
    }
    
    /// draw 内で reder 前に呼ばれる
    func clear() {
        if d.currentRenderingMode == RenderingMode.perVertexColor || d.currentRenderingMode == RenderingMode.textured {
            glClearColor(0.9, 0.9, 0.9, 1.0)
        
        } else if d.currentRenderingMode  == RenderingMode.lightedGray {
            glClearColor(0.3, 0.3, 0.3, 1.0)
        
        } else {
            glClearColor(0.4, 0.4, 0.4, 1.0)
        }
    
        glClearDepthf(1.0)

        glClear(GLenum(GL_COLOR_BUFFER_BIT) | GLenum(GL_DEPTH_BUFFER_BIT))
    }

    func setRenderingMode(_ mode: RenderingMode) {
        d.currentRenderingMode = mode
    }

    func upload(_ mesh: STMesh, with context: RendererContext) {
        let numUploads: Int = min(Int(mesh.numberOfMeshes()), Int(MAX_MESHES))
        d.numUploadedMeshes = min(Int(mesh.numberOfMeshes()), Int(MAX_MESHES))

        d.hasPerVertexColor = mesh.hasPerVertexColors()
        d.hasPerVertexNormals = mesh.hasPerVertexNormals()
        d.hasPerVertexUV = mesh.hasPerVertexUVTextureCoords()
        d.hasTexture = (mesh.meshYCbCrTexture() != nil)
        
        guard case .initialized(
            let textureUnit
            , let vertexVbo
            , let normalsVbo
            , let colorsVbo
            , let texcoordsVbo
            , let facesVbo
            , let linesVbo
        ) = context else { return }
        
        let pixelBuffer = Unmanaged<CVImageBuffer>.takeUnretainedValue(mesh.meshYCbCrTexture())
        self.uploadTexture(textureUnit, pixelBuffer: pixelBuffer())
        
        for meshIndex in 0..<numUploads {
            let numVertices: Int = Int(mesh.number(ofMeshVertices: Int32(meshIndex)))

            glBindBuffer(GLenum(GL_ARRAY_BUFFER), vertexVbo[meshIndex])
            glBufferData(
                GLenum(GL_ARRAY_BUFFER)
                , numVertices * MemoryLayout<GLKVector3>.size
                , mesh.meshVertices(Int32(meshIndex))
                , GLenum(GL_STATIC_DRAW)
            )

            if d.hasPerVertexNormals {
                glBindBuffer(GLenum(GL_ARRAY_BUFFER), normalsVbo[meshIndex])
                glBufferData(
                    GLenum(GL_ARRAY_BUFFER)
                    , numVertices * MemoryLayout<GLKVector3>.size
                    , mesh.meshPerVertexNormals(Int32(meshIndex))
                    , GLenum(GL_STATIC_DRAW)
                )
            }

            if d.hasPerVertexColor {
                glBindBuffer(GLenum(GL_ARRAY_BUFFER), colorsVbo[meshIndex])
                glBufferData(
                    GLenum(GL_ARRAY_BUFFER)
                    , numVertices * MemoryLayout<GLKVector3>.size
                    , mesh.meshPerVertexColors(Int32(meshIndex))
                    , GLenum(GL_STATIC_DRAW)
                )
            }

            if d.hasPerVertexUV {
                glBindBuffer( GLenum(GL_ARRAY_BUFFER), texcoordsVbo[meshIndex])
                glBufferData(
                    GLenum(GL_ARRAY_BUFFER)
                    , numVertices * MemoryLayout<GLKVector2>.size
                    , mesh.meshPerVertexUVTextureCoords(Int32(meshIndex))
                    , GLenum(GL_STATIC_DRAW)
                )
            }

            glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), facesVbo[meshIndex])
            glBufferData(
                GLenum(GL_ELEMENT_ARRAY_BUFFER)
                , Int(mesh.number(ofMeshFaces: Int32(meshIndex))) * MemoryLayout<Int32>.size * 3
                , mesh.meshFaces(Int32(meshIndex))
                , GLenum(GL_STATIC_DRAW)
            )

            glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), linesVbo[meshIndex])
            glBufferData(
                GLenum(GL_ELEMENT_ARRAY_BUFFER)
                , Int(mesh.number(ofMeshLines: Int32(meshIndex))) * MemoryLayout<Int32>.size * 2
                , mesh.meshLines(Int32(meshIndex))
                , GLenum(GL_STATIC_DRAW)
            )

            glBindBuffer( GLenum(GL_ELEMENT_ARRAY_BUFFER), 0)
            glBindBuffer( GLenum(GL_ARRAY_BUFFER), 0)

            d.numTriangleIndices[meshIndex] = Int(mesh.number(ofMeshFaces: Int32(meshIndex)) * 3)
            d.numLinesIndices[meshIndex] = Int(mesh.number(ofMeshLines: Int32(meshIndex)) * 2)
        }
    }

    /// displayLinkで実行されるdrawから呼ばれている
    /// - Parameters:
    ///   - projectionMatrix: <#projectionMatrix description#>
    ///   - modelViewMatrix: <#modelViewMatrix description#>
    func render(with context: RendererContext, projectionMatrix: UnsafePointer<GLfloat>, modelViewMatrix: UnsafePointer<GLfloat>) {
        
        guard case .initialized(
            let textureUnit
            , _ // let vertexVbo
            , _ // let normalsVbo
            , _ // let colorsVbo
            , _ // let texcoordsVbo
            , _ // let facesVbo
            , _ // let linesVbo
        ) = context else { return }

        if d.currentRenderingMode == RenderingMode.perVertexColor && !d.hasPerVertexColor && d.hasTexture && d.hasPerVertexUV {

            os_log(.info, log:OSLog.rendering, "Warning: The mesh has no per-vertex colors, but a texture, switching the rendering mode to Textured")
            d.currentRenderingMode = RenderingMode.textured
            
        } else if d.currentRenderingMode == RenderingMode.textured && (!d.hasTexture || !d.hasPerVertexUV) && d.hasPerVertexColor {
            os_log(.info, log:OSLog.rendering, "Warning: The mesh has no texture, but per-vertex colors, switching the rendering mode to PerVertexColor")
            d.currentRenderingMode = RenderingMode.perVertexColor
        }

        switch d.currentRenderingMode {
        case .xRay:
            d.xRayShader!.enable()
            d.xRayShader!.prepareRendering(projectionMatrix, modelView: modelViewMatrix)

        case .lightedGray:
            d.lightedGrayShader!.enable()
            d.lightedGrayShader!.prepareRendering(projectionMatrix, modelView: modelViewMatrix)

        case .perVertexColor:
            guard d.hasPerVertexColor else {
                os_log(.error, log:OSLog.rendering, "Warning: the mesh has no colors, skipping rendering.")
                return
            }

            d.perVertexColorShader!.enable()
            d.perVertexColorShader!.prepareRendering(projectionMatrix, modelView: modelViewMatrix)

        case .textured:
            guard d.hasTexture
            , let lumaTexture = d.lumaTexture
            , let chromaTexture = d.chromaTexture else {
                os_log(.error, log:OSLog.rendering, "Warning: null textures, skipping rendering.")
                return
            }

            glActiveTexture(textureUnit)
            glBindTexture(
                CVOpenGLESTextureGetTarget(lumaTexture)
                , CVOpenGLESTextureGetName(lumaTexture)
            )

            glActiveTexture(textureUnit + 1)
            glBindTexture(
                CVOpenGLESTextureGetTarget(chromaTexture)
                , CVOpenGLESTextureGetName(chromaTexture)
            )

            d.yCbCrTextureShader!.enable()
            d.yCbCrTextureShader!.prepareRendering(
                projectionMatrix
                , modelView: modelViewMatrix
                , textureUnit: GLint(textureUnit)
            )
        }

        // Keep previous GL_DEPTH_TEST state
        let wasDepthTestEnabled: GLboolean = glIsEnabled(GLenum(GL_DEPTH_TEST))
        glEnable(GLenum(GL_DEPTH_TEST))

        for i in 0..<d.numUploadedMeshes {
            self.renderPartialMesh(with: context, meshIndex: i)
        }

        if wasDepthTestEnabled == GLboolean(GL_FALSE) {
            glDisable(GLenum(GL_DEPTH_TEST))
        }
    }
}

// MARK: - Private Methods
extension MeshRenderer {
    
    // MARK: - uplaod mesh
    
    private func uploadTexture(_ textureUnit: GLenum, pixelBuffer: CVImageBuffer) {
        let width = Int(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int(CVPixelBufferGetHeight(pixelBuffer))
        
        let context = EAGLContext.current()
        assert(context != nil)
        
        self.releaseGLTextures()
        
        if d.textureCache == nil {
            let texError = CVOpenGLESTextureCacheCreate(
                kCFAllocatorDefault
                , nil
                , context!
                , nil
                , &d.textureCache
            )
            if texError != kCVReturnSuccess {
                os_log(.error, log:OSLog.rendering, "Error at CVOpenGLESTextureCacheCreate %{Public}d", texError)
            }
        }
        
        // Allow the texture cache to do internal cleanup.
        CVOpenGLESTextureCacheFlush(d.textureCache!, 0)
        
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        assert(pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        
        // Activate the default texture unit.
        glActiveTexture(textureUnit)
        
        // Create a new Y texture from the video texture cache.
        var err = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault
            , d.textureCache!
            , pixelBuffer
            , nil
            , GLenum(GL_TEXTURE_2D)
            , GL_RED_EXT
            , GLsizei(width), GLsizei(height)
            , GLenum(GL_RED_EXT)
            , GLenum(GL_UNSIGNED_BYTE)
            , 0
            , &d.lumaTexture
        )
        
        guard err == kCVReturnSuccess else {
            os_log(.error, log:OSLog.rendering, "Error with CVOpenGLESTextureCacheCreateTextureFromImage: %{Public}d", err)
            return
        }
        
        // Set rendering properties for the new texture.
        glBindTexture(
            CVOpenGLESTextureGetTarget(d.lumaTexture!)
            , CVOpenGLESTextureGetName(d.lumaTexture!)
        )
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
        
        // Activate the next texture unit for CbCr.
        glActiveTexture(textureUnit + 1)
        
        // Create a new CbCr texture from the video texture cache.
        err = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault
            , d.textureCache!
            , pixelBuffer
            , nil
            , GLenum(GL_TEXTURE_2D)
            , GL_RG_EXT
            , Int32(width) / 2
            , Int32(height) / 2
            , GLenum(GL_RG_EXT)
            , GLenum(GL_UNSIGNED_BYTE)
            , 1
            , &d.chromaTexture
        )
        
        guard err == kCVReturnSuccess else {
            os_log(.error, log:OSLog.rendering, "Error with CVOpenGLESTextureCacheCreateTextureFromImage: %{Public}d", err)
            return
        }
        
        glBindTexture(
            CVOpenGLESTextureGetTarget(d.chromaTexture!)
            , CVOpenGLESTextureGetName(d.chromaTexture!)
        )
        glTexParameterf( GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
        glTexParameterf( GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
        glBindTexture( GLenum(GL_TEXTURE_2D), 0)
    }
    
    // MARK: - render
    
    private func enable(vertexVbo:[GLuint], meshIndex: Int) {
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vertexVbo[meshIndex])
        glEnableVertexAttribArray(CustomShader.Attrib.vertex.rawValue)
        glVertexAttribPointer(
            CustomShader.Attrib.vertex.rawValue
            , 3
            , GLenum(GL_FLOAT)
            , GLboolean(GL_FALSE)
            , 0
            , nil
        )
    }
    
    private func disable(vertexVbo:[GLuint], meshIndex: Int) {
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vertexVbo[meshIndex])
        glDisableVertexAttribArray(CustomShader.Attrib.vertex.rawValue)
    }
    
    private func enable(normalsVbo:[GLuint], meshIndex: Int) {
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), normalsVbo[meshIndex])
        glEnableVertexAttribArray(CustomShader.Attrib.normal.rawValue)
        glVertexAttribPointer(
            CustomShader.Attrib.normal.rawValue
            , 3
            , GLenum(GL_FLOAT)
            , GLboolean(GL_FALSE)
            , 0
            , nil
        )
    }
    
    private func disable(normalsVbo:[GLuint], meshIndex: Int) {
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), normalsVbo[meshIndex])
        glDisableVertexAttribArray(CustomShader.Attrib.normal.rawValue)
    }
    
    private func enable(colorsVbo: [GLuint], meshIndex: Int) {
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), colorsVbo[meshIndex])
        glEnableVertexAttribArray(CustomShader.Attrib.color.rawValue)
        glVertexAttribPointer(
            CustomShader.Attrib.color.rawValue
            , 3
            , GLenum(GL_FLOAT)
            , GLboolean(GL_FALSE)
            , 0
            , nil
        )
    }
    
    private func disable(colorsVbo: [GLuint], meshIndex: Int) {
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), colorsVbo[meshIndex])
        glDisableVertexAttribArray(CustomShader.Attrib.color.rawValue)
    }
    
    private func enable(texcoordsVbo:[GLuint], meshIndex: Int) {
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), texcoordsVbo[meshIndex])
        glEnableVertexAttribArray(CustomShader.Attrib.textCoord.rawValue)
        glVertexAttribPointer(
            CustomShader.Attrib.textCoord.rawValue
            , 2
            , GLenum(GL_FLOAT)
            , GLboolean(GL_FALSE)
            , 0
            , nil
        )
    }
    
    private func disable(texcoordsVbo:[GLuint],  meshIndex: Int) {
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), texcoordsVbo[meshIndex])
        glDisableVertexAttribArray(CustomShader.Attrib.textCoord.rawValue)
    }
    
    private func enable(linesVbo: [GLuint], meshIndex: Int) {
        glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), linesVbo[meshIndex])
        glLineWidth(1.0)
    }
    
    private func enable(facesVbo: [GLuint], meshIndex: Int) {
        glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), facesVbo[meshIndex])
    }
    
    private func renderPartialMesh(with context: RendererContext, meshIndex: Int) {
        // nothing uploaded. return test
        guard d.numTriangleIndices[meshIndex] > 0 else { return }
        
        guard case .initialized(
            _ // let textureUnit
            , let vertexVbo
            , let normalsVbo
            , let colorsVbo
            , let texcoordsVbo
            , let facesVbo
            , let linesVbo
        ) = context else { return }
        
        switch d.currentRenderingMode {
        
        case .xRay:
            self.enable(linesVbo: linesVbo, meshIndex: meshIndex)
            self.enable(vertexVbo: vertexVbo, meshIndex: meshIndex)
            self.enable(normalsVbo: normalsVbo, meshIndex: meshIndex)
            glDrawElements(
                GLenum(GL_LINES)
                , GLsizei(d.numLinesIndices[meshIndex])
                , GLenum(GL_UNSIGNED_INT)
                , nil
            )
            self.disable(normalsVbo: normalsVbo, meshIndex: meshIndex)
            self.disable(vertexVbo: vertexVbo, meshIndex: meshIndex)
            
        case .lightedGray:
            self.enable(facesVbo: facesVbo, meshIndex: meshIndex)
            self.enable(vertexVbo: vertexVbo, meshIndex: meshIndex)
            self.enable(normalsVbo: normalsVbo, meshIndex: meshIndex)
            glDrawElements(
                GLenum(GL_TRIANGLES)
                , GLsizei(d.numTriangleIndices[meshIndex])
                , GLenum(GL_UNSIGNED_INT)
                , nil
            )
            self.disable(normalsVbo: normalsVbo, meshIndex: meshIndex)
            self.disable(vertexVbo: vertexVbo, meshIndex: meshIndex)
            
        case .perVertexColor:
            self.enable(facesVbo: facesVbo, meshIndex: meshIndex)
            self.enable(vertexVbo: vertexVbo, meshIndex: meshIndex)
            self.enable(normalsVbo: normalsVbo, meshIndex: meshIndex)
            self.enable(colorsVbo: colorsVbo, meshIndex: meshIndex)
            glDrawElements(
                GLenum(GL_TRIANGLES)
                , GLsizei(d.numTriangleIndices[meshIndex])
                , GLenum(GL_UNSIGNED_INT)
                , nil
            )
            self.disable(colorsVbo: colorsVbo, meshIndex: meshIndex)
            self.disable(normalsVbo: normalsVbo, meshIndex: meshIndex)
            self.disable(vertexVbo: vertexVbo, meshIndex: meshIndex)
            
        case .textured:
            self.enable(facesVbo: facesVbo, meshIndex: meshIndex)
            self.enable(vertexVbo: vertexVbo, meshIndex: meshIndex)
            self.enable(texcoordsVbo: texcoordsVbo, meshIndex: meshIndex)
            glDrawElements( GLenum(GL_TRIANGLES), GLsizei(d.numTriangleIndices[meshIndex]), GLenum(GL_UNSIGNED_INT), nil)
            self.disable(texcoordsVbo: texcoordsVbo, meshIndex: meshIndex)
            self.disable(vertexVbo: vertexVbo, meshIndex: meshIndex)
        }
        
        glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), 0)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), 0)
    }
    
    // MARK : - termination

    private func releaseGLTextures() {
        d.lumaTexture = nil
        d.chromaTexture = nil
        d.textureCache = nil
    }
    
    private func releaseGLBuffers(with context: RendererContext) {
        guard case .initialized(
            _ // let textureUnit
            , let vertexVbo
            , let normalsVbo
            , let colorsVbo
            , let texcoordsVbo
            , let facesVbo
            , let linesVbo
        ) = context else { return }
        
        for meshIndex in 0..<d.numUploadedMeshes {
            glBindBuffer(GLenum(GL_ARRAY_BUFFER), vertexVbo[meshIndex])
            glBufferData(GLenum(GL_ARRAY_BUFFER), 0, nil, GLenum(GL_STATIC_DRAW))
            
            glBindBuffer(GLenum(GL_ARRAY_BUFFER), normalsVbo[meshIndex])
            glBufferData(GLenum(GL_ARRAY_BUFFER), 0, nil, GLenum(GL_STATIC_DRAW))
            
            glBindBuffer(GLenum(GL_ARRAY_BUFFER), colorsVbo[meshIndex])
            glBufferData(GLenum(GL_ARRAY_BUFFER), 0, nil, GLenum(GL_STATIC_DRAW))
            
            glBindBuffer(GLenum(GL_ARRAY_BUFFER), texcoordsVbo[meshIndex])
            glBufferData(GLenum(GL_ARRAY_BUFFER), 0, nil, GLenum(GL_STATIC_DRAW))
            
            glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), facesVbo[meshIndex])
            glBufferData(GLenum(GL_ELEMENT_ARRAY_BUFFER), 0, nil, GLenum(GL_STATIC_DRAW))
            
            glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), linesVbo[meshIndex])
            glBufferData(GLenum(GL_ELEMENT_ARRAY_BUFFER), 0, nil, GLenum(GL_STATIC_DRAW))
        }
    }

    private func meshRendererDestructor(with context: RendererContext) {
        if case .initialized(
            _ // let textureUnit
            , let vertexVbo
            , let normalsVbo
            , let colorsVbo
            , let texcoordsVbo
            , let facesVbo
            , let linesVbo
        ) = context {
            if vertexVbo[0] != 0 {
                glDeleteBuffers(GLsizei(MAX_MESHES), vertexVbo)
            }
            if normalsVbo[0] != 0 {
                glDeleteBuffers(GLsizei(MAX_MESHES), normalsVbo)
            }
            if colorsVbo[0] != 0 {
                glDeleteBuffers(GLsizei(MAX_MESHES), colorsVbo)
            }
            if texcoordsVbo[0] != 0 {
                glDeleteBuffers(GLsizei(MAX_MESHES), texcoordsVbo)
            }
            if facesVbo[0] != 0 {
                glDeleteBuffers(GLsizei(MAX_MESHES), facesVbo)
            }
            if linesVbo[0] != 0 {
                glDeleteBuffers(GLsizei(MAX_MESHES), linesVbo)
            }
        }
        
        self.d.lightedGrayShader = nil
        self.d.perVertexColorShader = nil
        self.d.xRayShader = nil
        self.d.yCbCrTextureShader = nil
        self.d.numUploadedMeshes = 0
    }
    

}
