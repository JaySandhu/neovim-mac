//
//  Neovim Mac Test
//  AsanAssert.h
//
//  Copyright © 2022 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef ASAN_ASSERT_H
#define ASAN_ASSERT_H

#include <sanitizer/asan_interface.h>
#include <XCTest/XCTest.h>

#ifdef __cplusplus
extern "C" {
#endif

#if __has_feature(address_sanitizer)

bool asan_region_is_all_poisoned(void *ptr, size_t length);
void asan_assert_report_issue(XCTestCase *test,
                              NSString *message, NSString *user_message,
                              NSString *filename, NSUInteger line);

/// Asserts that the given address is valid.
/// @param addr:    Pointer to test.
/// @param ...      An optional supplementary description of the failure.
///                 A literal NSString with optional string format specifiers.
#define AssertAddressValid(addr, ...)                                          \
if (__asan_address_is_poisoned((addr)) == 1)                                   \
    asan_assert_report_issue(self,                                             \
        [NSString stringWithFormat:@"((%s (%p)) "                              \
                                    "address is valid) failed: "               \
                                    "address is poisoned", #addr, (addr)],     \
        ([NSString stringWithFormat:@"" __VA_ARGS__]),                         \
        @__FILE__, __LINE__)

/// Asserts that the given address has been poisoned.
/// @param addr:    Pointer to test.
/// @param ...      An optional supplementary description of the failure.
///                 A literal NSString with optional string format specifiers.
#define AssertAddressPoisoned(addr, ...)                                       \
if (__asan_address_is_poisoned((addr)) == 0)                                   \
    asan_assert_report_issue(self,                                             \
        [NSString stringWithFormat:@"((%s (%p)) "                              \
                                    "address is poisoned) failed: "            \
                                    "address is valid", #addr, (addr)],        \
        ([NSString stringWithFormat:@"" __VA_ARGS__]),                         \
        @__FILE__, __LINE__)

/// Asserts that the given memory region is valid.
/// @param addr:    Pointer to start of the region.
/// @param len:     Length in bytes of the region.
/// @param ...      An optional supplementary description of the failure.
///                 A literal NSString with optional string format specifiers.
#define AssertRegionValid(ptr, len, ...)                                       \
if (__asan_region_is_poisoned((ptr), (len)))                                   \
    asan_assert_report_issue(self,                                             \
        [NSString stringWithFormat:@"((start=%s, length=%s ([%p - %p))) "      \
                                     "region is valid) failed: "               \
                                     "region is poisoned",                     \
                                     #ptr, #len, (ptr), (char*)ptr + len],     \
        ([NSString stringWithFormat:@"" __VA_ARGS__]),                         \
        @__FILE__, __LINE__)

/// Asserts that all bytes in the given memory region have been poisioned.
/// @param addr:    Pointer to start of the region.
/// @param len:     Length in bytes of the region.
/// @param ...      An optional supplementary description of the failure.
///                 A literal NSString with optional string format specifiers.
#define AssertRegionPoisoned(ptr, len, ...)                                    \
if (!asan_region_is_all_poisoned((ptr), (len)))                                \
    asan_assert_report_issue(self,                                             \
        [NSString stringWithFormat:@"((start=%s, length=%s ([%p - %p))) "      \
                                     "region is poisoned) failed: "            \
                                     "memory in region is valid",              \
                                     #ptr, #len, (ptr), (char*)ptr + len],     \
        ([NSString stringWithFormat:@"" __VA_ARGS__]),                         \
        @__FILE__, __LINE__)

#else
// No-ops if address sanitizer is not available.
#define AssertAddressValid(addr, ...) (void)(addr)
#define AssertAddressPoisoned(addr, ...) (void)(addr)
#define AssertRegionValid(ptr, len, ...) ((void)(ptr), (void)(len))
#define AssertRegionPoisoned(ptr, len, ...) ((void)(ptr), (void)(len))
#endif // __has_feature(address_sanitizer)

#ifdef __cplusplus
} // extern C
#endif

#endif // ASAN_ASSERT_H
