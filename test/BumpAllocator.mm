//
//  Neovim Mac Test
//  BumpAllocator.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <XCTest/XCTest.h>
#include <random>
#include "DeathTest.h"
#include "bump_allocator.hpp"

@interface testBumpAllocator : XCTestCase
@end

@implementation testBumpAllocator

#if __has_feature(address_sanitizer)

- (void)testDeallocAllPoisions {
    bump_allocator allocator(512);
    char *ptr = static_cast<char*>(allocator.alloc(24));
    allocator.dealloc_all();
    
    AssertDies(*(ptr + 5) = 'x');
}

- (void)testDestructorPoisions {
    char *ptr;

    {
        bump_allocator allocator(512);
        ptr = static_cast<char*>(allocator.alloc(24));
    }

    AssertDies(*(ptr + 5) = 'x');
}

- (void)testMoveAssigmentPoisions {
    bump_allocator allocator(512);
    char *ptr = static_cast<char*>(allocator.alloc(24));
    allocator = bump_allocator();

    AssertDies(*(ptr + 5) = 'x');
}

- (void)testAbortsOnOverflow {
    bump_allocator allocator(512);
    AssertAborts(allocator.alloc(SIZE_T_MAX));
    AssertAborts(allocator.alloc(SIZE_T_MAX - 8));
}

- (void)testMemoryIsGuarded {
    bump_allocator allocator(512);
    char *test = static_cast<char*>(allocator.alloc(64));

    AssertDies(*(test - 1)  = 'x');
    AssertDies(*(test + 65) = 'x');
}

#endif // __has_feature(address_sanitizer)

- (void)testDeallocAllRestoresRemaining {
    bump_allocator allocator(512);
    size_t remaining = allocator.remaining();
    
    allocator.alloc(24);
    XCTAssertGreaterThanOrEqual(remaining - allocator.remaining(), 24);
    
    allocator.dealloc_all();
    XCTAssertEqual(allocator.remaining(), remaining);
}

- (void)testDefaultContructor {
    bump_allocator default_contructed;
    XCTAssertEqual(default_contructed.capacity(), 0);
    XCTAssertEqual(default_contructed.remaining(), 0);
}

- (void)testDefaultContructedAllocatorCanAlloc {
    bump_allocator default_constructed;
    void *ptr = default_constructed.alloc(24);
    
    XCTAssertGreaterThan(default_constructed.capacity(), 24);
    AssertNoDeath(memset(ptr, 'x', 24));
}

- (void)testInitialCapacityConstructor {
    bump_allocator allocator(512);
    XCTAssertEqual(allocator.capacity(), 512);
    XCTAssertGreaterThan(allocator.remaining(), 0);
}

- (void)testMoveAssignment {
    bump_allocator moved_to;
    bump_allocator moved_from(512);
    
    void *ptr = moved_from.alloc(24);
    size_t remaining = moved_from.remaining();
    
    moved_to = std::move(moved_from);
    
    XCTAssertEqual(moved_from.remaining(), 0);
    XCTAssertEqual(moved_from.capacity(), 0);
    XCTAssertEqual(moved_to.capacity(), 512);
    XCTAssertEqual(moved_to.remaining(), remaining);

    AssertNoDeath(memset(ptr, 'x', 24));
}

- (void)testMoveContructor {
    bump_allocator moved_from(512);
    
    void *ptr = moved_from.alloc(24);
    size_t remaining = moved_from.remaining();
    
    bump_allocator moved_to = std::move(moved_from);
    
    XCTAssertEqual(moved_from.remaining(), 0);
    XCTAssertEqual(moved_from.capacity(), 0);
    XCTAssertEqual(moved_to.capacity(), 512);
    XCTAssertEqual(moved_to.remaining(), remaining);
    
    AssertNoDeath(memset(ptr, 'x', 24));
}

- (void)testCapacityExpandsAsNeeded {
    bump_allocator allocator(512);
    
    void *ptr = allocator.alloc(24);
    XCTAssertEqual(allocator.capacity(), 512);
    
    allocator.alloc(1024);
    XCTAssertGreaterThanOrEqual(allocator.capacity(), 1024);
    AssertNoDeath(memset(ptr, 'x', 24));
}

- (void)testReserveResizesAsNeeded {
    bump_allocator allocator;
    allocator.reserve(512);
    size_t capacity = allocator.capacity();
    size_t remaining = allocator.remaining();
    
    XCTAssertGreaterThanOrEqual(capacity, 512);
    XCTAssertGreaterThanOrEqual(remaining, 512);

    allocator.reserve(128);
    XCTAssertEqual(allocator.capacity(), capacity);
    XCTAssertEqual(allocator.remaining(), remaining);
}

- (void)testMemoryIsAligned {
    bump_allocator allocator(512);
    
    std::mt19937_64 mt;
    std::uniform_int_distribution<size_t> dist(1, 10000);
    
    for (int i=0; i<16; ++i) {
        XCTAssertFalse((uintptr_t)allocator.alloc(dist(mt)) % 8);
    }
}

- (void)testMemoryIsValid {
    bump_allocator allocator(512);
    
    std::mt19937_64 mt;
    std::uniform_int_distribution<size_t> dist(8, 8192);
    
    AssertNoDeath({
        for (int i=0; i<128; ++i) {
            size_t size = dist(mt);
            void *ptr = allocator.alloc(size);
            memset(ptr, 'x', size);
        }
    });
}

@end
