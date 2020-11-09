//
//    This file is a Swift port of the Structure SDK sample app "Scanner".
//    Copyright © 2016 Occipital, Inc. All rights reserved.
//    http://structure.io
//
//  EAGLView.swift
//
//  Ported by Christopher Worley on 8/20/16.
//

import Foundation
import os.log
import UIKit

// This class wraps the CAEAGLLayer from CoreAnimation into a convenient UIView subclass.
// The view content is basically an EAGL surface you render your OpenGL scene into.
// Note that setting the view non-opaque will only work if the EAGL surface has an alpha channel.

class EAGLView: UIView {

    // The pixel dimensions of the CAEAGLLayer.
    var framebufferWidth: GLint = 0
    var framebufferHeight: GLint = 0
    
    // The OpenGL ES names for the framebuffer and renderbuffer used to render to this view.
    var defaultFramebuffer: GLuint = 0
    var colorRenderbuffer: GLuint = 0
    var depthRenderbuffer: GLuint = 0

    override  class var layerClass : AnyClass {
        return CAEAGLLayer.self
    }
    
    @inline(__always) func eaglLayer() -> CAEAGLLayer { return self.layer as! CAEAGLLayer }

    // The EAGL view is stored in the nib file. When it's unarchived it's sent -initWithCoder:.
    required init(coder: NSCoder) {
        super.init(coder: coder)!
        
        let eagllayer = eaglLayer()
        
        eagllayer.isOpaque = true
        eagllayer.drawableProperties = [
            kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8
            , kEAGLDrawablePropertyRetainedBacking : true
        ]
        
        self.contentScaleFactor = 1.0
    }

    
    fileprivate var _context: EAGLContext? = nil
    var context: EAGLContext? {
        get {
            return _context
        }
        set {
            if (_context != newValue) {
                _context = newValue
                EAGLContext.setCurrent(nil)
            }
        }
    }

    
    func presentFramebuffer() -> Bool {
        
        var success = false
        
        // iOS may crash if presentRenderbuffer is called when the application is in background.
        if ((context != nil) && (UIApplication.shared.applicationState != .background)) {
            
            EAGLContext.setCurrent(context)
            
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
            
            success = context!.presentRenderbuffer(GLintptr(GL_RENDERBUFFER))
        }
        
        return success
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // CAREFUL!!!! If you have autolayout enabled, you will re-create your framebuffer all the time if
        // your EAGLView has any subviews that are updated. For example, having a UILabel that is updated
        // to display FPS will result in layoutSubviews being called every frame. Two ways around this:
        // 1) don't use autolayout
        // 2) don't add any subviews to the EAGLView. Have the EAGLView be a subview of another "master" view.
        
        // The framebuffer will be re-created at the beginning of the next setFramebuffer method call.
//        self.deleteFramebuffer()
    }

    func getFramebufferSize() -> CGSize {
        return CGSize(width: CGFloat(framebufferWidth), height: CGFloat(framebufferHeight))
    }
}
