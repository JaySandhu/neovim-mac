//
//  Neovim Mac Test
//  DeathTest.h
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef DEATH_TEST_H
#define DEATH_TEST_H

#import <XCTest/XCTest.h>

#ifdef __cplusplus
extern "C"
#endif
bool forked_context(XCTestCase *test, int testcode,
                    bool equal, const char *assertion,
                    const char *failure_message, NSString *user_message,
                    NSString *filename, NSUInteger line);

/// Evaluates an expression in a forked process then immediately calls _exit().
/// Generates a failure if ((exitcode == testcode) != equal), where exitcode
/// is the child process's exit code.
///
/// @param expr     An expression to be evaluated in the forked process.
/// @param exitwith The exit code to use in the terminating call to _exit().
/// @param testcode The value compared with the child process's exit code.
/// @param equal    A boolean indicating whether the child process's
///                 exit code should equal testcode.
/// @param assert   Description of the assertion condition.
/// @param failure  Default decription description of the failure.
/// @param ...      An optional supplementary description of the failure.
///                 A literal NSString with optional string format specifiers.
#define FORK_ASSERT(expr, exitwith, testcode, equal, assert, failure, ...)     \
if (forked_context(self, testcode, equal, "(("#expr") " assert ")", failure,   \
                   ([NSString stringWithFormat:@"" __VA_ARGS__]),              \
                   @__FILE__, __LINE__)) {                                     \
    (void)(expr);                                                              \
    _exit(exitwith);                                                           \
}

/// Generates a failure if evaluating expression would not cause the process
/// to abort.
///
/// @param expr An expression to be evaluated.
/// @param ...  An optional supplementary description of the failure.
///             A literal NSString with optional string format specifiers.
#define AssertAborts(expr, ...) \
FORK_ASSERT(expr, 0, SIGABRT, true, "aborts", "did not abort", ##__VA_ARGS__)

/// Generates a failure if evaluating expression would cause the process
/// to abort.
///
/// @param expr An expression to be evaluated.
/// @param ...  An optional supplementary description of the failure.
///             A literal NSString with optional string format specifiers.
#define AssertNoAbort(expr, ...) \
FORK_ASSERT(expr, 0, SIGABRT, false, "does not abort", "aborted", ##__VA_ARGS__)

/// Generates a failure if evaluating expression does not cause the program
/// to terminate.
///
/// @param expr An expression to be evaluated.
/// @param ...  An optional supplementary description of the failure.
///             A literal NSString with optional string format specifiers.
#define AssertDies(expr, ...) \
FORK_ASSERT(expr, 127, 127, false, "dies", "did not die", ##__VA_ARGS__)

/// Generates a failure if evaluating expression does causes the program
/// to terminate.
///
/// @param expr An expression to be evaluated.
/// @param ...  An optional supplementary description of the failure.
///             A literal NSString with optional string format specifiers.
#define AssertNoDeath(expr, ...) \
FORK_ASSERT(expr, 127, 127, true, "does not die", "died", ##__VA_ARGS__)

#endif /* DEATH_TEST_H */
