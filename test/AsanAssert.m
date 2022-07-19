//
//  Neovim Mac Test
//  AsanAssert.m
//
//  Copyright © 2022 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include "AsanAssert.h"

#if __has_feature(address_sanitizer)

bool asan_region_is_all_poisoned(void *ptr, size_t length) {
    char *bytes = (char*)ptr;

    for (size_t i=0; i<length; ++i) {
        if (!__asan_address_is_poisoned(bytes + i)) {
            return false;
        }
    }

    return true;
}

void asan_assert_report_issue(XCTestCase *test,
                              NSString *message, NSString *user_message,
                              NSString *filename, NSUInteger line) {
    if ([user_message length]) {
        message = [NSString stringWithFormat:@"%@ - %@", message, user_message];
    }

    XCTSourceCodeLocation *location = [[XCTSourceCodeLocation alloc] initWithFilePath:filename lineNumber:line];
    XCTSourceCodeContext *sourceCodeContext = [[XCTSourceCodeContext alloc] initWithLocation:location];

    XCTIssue *issue = [[XCTIssue alloc] initWithType:XCTIssueTypeAssertionFailure
                                  compactDescription:message
                                 detailedDescription:nil
                                   sourceCodeContext:sourceCodeContext
                                     associatedError:nil
                                         attachments:@[]];

    [test recordIssue:issue];
}

#endif // __has_feature(address_sanitizer)
