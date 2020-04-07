//
//  Neovim Mac
//  NVWindowController.h
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NVWindowController : NSWindowController<NSWindowDelegate>

- (void)shutdown;
- (void)connect:(NSString *)addr;

@end

NS_ASSUME_NONNULL_END
