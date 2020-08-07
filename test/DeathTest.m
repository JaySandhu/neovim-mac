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

bool forked_context(XCTestCase *test, int testcode,
                    bool equal, const char *assertion,
                    const char *failure_message, NSString *user_message,
                    NSString *filename, NSUInteger line) {
    pid_t pid = fork();
    
    if (pid == 0) {
        // Child process, supress stderr and set death callbacks
        dup2(open("/dev/null", O_WRONLY), STDERR_FILENO);

#if __has_feature(address_sanitizer)
        __sanitizer_set_death_callback(abort);
#endif

        signal(SIGABRT, _exit);
        return true;
    }
    
    int status;
    BOOL expexted_failure;
    NSString *description;
    
    if (pid == -1) {
        expexted_failure = NO;
        description = [NSString stringWithFormat:@"%s failed: fork error: %s", assertion, strerror(errno)];
    } else if(!try_waitpid(pid, &status)) {
        expexted_failure = NO;
        description = [NSString stringWithFormat:@"%s failed: waitpid error: %s", assertion, strerror(errno)];
    } else if ((WEXITSTATUS(status) == testcode) != equal) {
        expexted_failure = YES;
        description = [NSString stringWithFormat:@"%s failed: %s", assertion, failure_message];
    } else {
        // Test passed
        return false;
    }
    
    if ([user_message length]) {
        description = [NSString stringWithFormat:@"%@ - %@", description, user_message];
    }
    
    [test recordFailureWithDescription:description
                                inFile:filename
                                atLine:line
                              expected:expexted_failure];
    
    return false;
}
