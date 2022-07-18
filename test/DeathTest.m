//
//  Neovim Mac Test
//  DeathTest.m
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <sanitizer/asan_interface.h>
#include "DeathTest.h"

// waitpid is liable to be interupted SIGCHLD, this wrapper function
// retries calls to waitpid if they fail with EINTR
static inline bool try_waitpid(pid_t pid, int *status) {
    for (;;) {
        int result = waitpid(pid, status, 0);
        
        if (result != -1) {
            return true;
        } else if (errno != EINTR) {
            return false;
        }
    }
}

static bool report_issue(XCTestCase *test, NSString *description,
                         NSString *user_message, NSString *filename, NSUInteger line) {
    if ([user_message length]) {
        description = [NSString stringWithFormat:@"%@ - %@", description, user_message];
    }

    XCTSourceCodeLocation *location = [[XCTSourceCodeLocation alloc] initWithFilePath:filename lineNumber:line];
    XCTSourceCodeContext *sourceCodeContext = [[XCTSourceCodeContext alloc] initWithLocation:location];

    XCTIssue *issue = [[XCTIssue alloc] initWithType:XCTIssueTypeAssertionFailure
                                  compactDescription:description
                                 detailedDescription:nil
                                   sourceCodeContext:sourceCodeContext
                                     associatedError:nil
                                         attachments:@[]];

    [test recordIssue:issue];
    return false;
}

bool forked_context(XCTestCase *test, int testcode,
                    bool equal, const char *assertion,
                    const char *failure_message, NSString *user_message,
                    NSString *filename, NSUInteger line) {
    pid_t pid = fork();

    // Child process, supress stderr and set death callbacks
    if (pid == 0) {
        dup2(open("/dev/null", O_WRONLY), STDERR_FILENO);

#if __has_feature(address_sanitizer)
        __sanitizer_set_death_callback(abort);
#endif

        signal(SIGABRT, _exit);
        return true;
    }

    int status;

    if (pid == -1) {
        NSString *description = [NSString stringWithFormat:@"%s failed: fork error: %s", assertion, strerror(errno)];
        return report_issue(test, description, user_message, filename, line);
    }

    if(!try_waitpid(pid, &status)) {
        NSString *description = [NSString stringWithFormat:@"%s failed: waitpid error: %s", assertion, strerror(errno)];
        return report_issue(test, description, user_message, filename, line);
    }

    if ((WEXITSTATUS(status) == testcode) != equal) {
        NSString *description = [NSString stringWithFormat:@"%s failed: %s", assertion, failure_message];
        return report_issue(test, description, user_message, filename, line);
    }

    return false;
}
