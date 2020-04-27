//
//  Neovim Mac
//  NVGridView.h
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

namespace ui {
struct grid;
}

@interface NVGridView : NSView<CALayerDelegate>

- (void)setGrid:(ui::grid*)grid;

@end

NS_ASSUME_NONNULL_END
