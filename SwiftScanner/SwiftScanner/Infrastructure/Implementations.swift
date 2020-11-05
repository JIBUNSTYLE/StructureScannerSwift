//
//  Implementations.swift
//  SwiftScanner
//
//  Created by 斉藤 祐輔 on 2020/11/04.
//  Copyright © 2020 CoderJoris. All rights reserved.
//

import Foundation

struct Implementations {
    static let shared: Implementations = Implementations()
    
    let scanner: ScannerInterface
    
    init(
        scanner: ScannerInterface = StructureService()
    ) {
        self.scanner = scanner
    }
}
