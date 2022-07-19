//
//  Neovim Mac Test
//  BumpAllocator.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <random>
#include <XCTest/XCTest.h>
#include "AsanAssert.h"
#include "bump_allocator.hpp"

@interface testBumpAllocator : XCTestCase
@end

@implementation testBumpAllocator

- (void)testDeallocAllPoisions {
    bump_allocator allocator(512);
    char *ptr = static_cast<char*>(allocator.alloc(24));
    allocator.dealloc_all();

    AssertRegionPoisoned(ptr, 24);
}

- (void)testDestructorPoisions {
    char *ptr;

    {
        bump_allocator allocator(512);
        ptr = static_cast<char*>(allocator.alloc(24));
    }

    AssertRegionPoisoned(ptr, 24);
}

- (void)testMoveAssigmentPoisions {
    bump_allocator allocator(512);
    char *ptr = static_cast<char*>(allocator.alloc(24));
    allocator = bump_allocator();

    AssertRegionPoisoned(ptr, 24);
}

- (void)testMemoryIsGuarded {
    bump_allocator allocator(512);
    char *test = static_cast<char*>(allocator.alloc(64));

    AssertAddressPoisoned(test - 1);
    AssertAddressPoisoned(test + 65);
}

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
    AssertRegionValid(ptr, 24);
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

    AssertRegionValid(ptr, 24);
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
    
    AssertRegionValid(ptr, 24);
}

- (void)testCapacityExpandsAsNeeded {
    bump_allocator allocator(512);
    
    void *ptr = allocator.alloc(24);
    XCTAssertEqual(allocator.capacity(), 512);
    
    allocator.alloc(1024);
    XCTAssertGreaterThanOrEqual(allocator.capacity(), 1024);
    AssertRegionValid(ptr, 24);
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

    for (int i=0; i<128; ++i) {
        size_t size = dist(mt);
        void *ptr = allocator.alloc(size);
        AssertRegionValid(ptr, size);
    }
}

@end
