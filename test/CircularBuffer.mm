//
//  Neovim Mac Test
//  CircularBuffer.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <algorithm>
#include <string>
#include <vector>
#include <XCTest/XCTest.h>

#include "AsanAssert.h"
#include "circular_buffer.hpp"

template<typename Range1, typename Range2>
static bool operator!=(const Range1 &r1, const Range2 &r2) {
    return !std::equal(r1.begin(), r1.end(), r2.begin(), r2.end());
}

static inline bool all_of(const circular_buffer &buffer, char val) {
    return std::all_of(buffer.begin(), buffer.end(), [val](char x){
        return x == val;
    });
}

@interface testCircularBuffer : XCTestCase
@end

@implementation testCircularBuffer

- (void)testDefaultContructor {
    circular_buffer buffer;
    XCTAssertEqual(buffer.size(), 0);
    XCTAssertEqual(buffer.capacity(), 0);
    XCTAssertEqual(buffer.data(), nullptr);
    XCTAssertEqual(buffer.begin(), buffer.end());
}

- (void)testInitialCapacityConstructor {
    circular_buffer buffer(1024);
    XCTAssertGreaterThanOrEqual(buffer.capacity(), 1024);
    XCTAssertEqual(buffer.size(), 0);
    XCTAssertEqual(buffer.begin(), buffer.end());
    XCTAssertTrue(buffer.data());
}

- (void)testDestructorDeallocates {
    char *data;
    
    {
        circular_buffer buffer(1024);
        data = buffer.data();
    }

    AssertAddressPoisoned(data);
}

- (void)testMoveConstructor {
    std::string_view input("input");
    
    circular_buffer moved_from;
    moved_from.insert(input.data(), input.size());
    
    size_t size = moved_from.size();
    size_t capacity = moved_from.capacity();
    const char *data = moved_from.data();

    circular_buffer moved_to(std::move(moved_from));
    
    XCTAssertEqual(moved_from.size(), 0);
    XCTAssertEqual(moved_from.capacity(), 0);
    XCTAssertEqual(moved_from.data(), nullptr);
    XCTAssertEqual(moved_from.begin(), moved_from.end());
    
    XCTAssertEqual(moved_to.size(), size);
    XCTAssertEqual(moved_to.capacity(), capacity);
    XCTAssertEqual(moved_to.data(), data);
    XCTAssertEqual(moved_to, input);
}

- (void)testMoveAssignment {
    std::string_view input("input");
    
    circular_buffer moved_to;
    circular_buffer moved_from;
    moved_from.insert(input.data(), input.size());
    
    size_t size = moved_from.size();
    size_t capacity = moved_from.capacity();
    const char *data = moved_from.data();
    
    moved_to = std::move(moved_from);
    
    XCTAssertEqual(moved_from.size(), 0);
    XCTAssertEqual(moved_from.capacity(), 0);
    XCTAssertEqual(moved_from.data(), nullptr);
    XCTAssertEqual(moved_from.begin(), moved_from.end());
    
    XCTAssertEqual(moved_to.size(), size);
    XCTAssertEqual(moved_to.capacity(), capacity);
    XCTAssertEqual(moved_to.data(), data);
    XCTAssertEqual(moved_to, input);
}

- (void)testMoveAssignmentDeallocates {
    circular_buffer moved_to(1024);
    char *ptr = moved_to.data();
    moved_to = circular_buffer();
    
    AssertAddressPoisoned(ptr);
}

- (void)testCopyConstructor {
    const char input[] = "input";
    
    circular_buffer original;
    original.insert(input, sizeof(input));
    circular_buffer copy(original);
    
    XCTAssertEqual(original, copy);
    XCTAssertEqual(original.size(), copy.size());
    XCTAssertEqual(original.capacity(), copy.capacity());
    XCTAssertNotEqual(original.data(), copy.data());
}

- (void)testCopyAssigment {
    std::string_view input("input");
    
    circular_buffer original;
    original.insert(input.data(), input.size());
    
    circular_buffer copy;
    copy = original;
    
    XCTAssertEqual(original, copy);
    XCTAssertEqual(original.size(), copy.size());
    XCTAssertEqual(original.capacity(), copy.capacity());
    XCTAssertNotEqual(original.data(), copy.data());
}

- (void)testCopyAssingmentReusesBufferWhenPossible {
    std::string_view input("input");
    circular_buffer original;
    original.insert(input.data(), input.size());
    
    circular_buffer copy(1024);
    char *old_data = copy.data();
    copy = original;
    
    XCTAssertEqual(copy.data(), old_data);
}

- (void)testCopyAssigmentDeallocatesWhenResizing {
    circular_buffer small(1024);
    size_t large_capacity = small.capacity() + 1024;
    
    circular_buffer large(large_capacity);
    
    for (int i=0; i<large_capacity; ++i) {
        large.push_back('x');
    }
    
    char *old_data = small.data();
    size_t old_capacity = small.capacity();
    small = large;
    
    XCTAssertGreaterThan(small.capacity(), old_capacity);
    XCTAssertNotEqual(old_data, small.data());
    AssertAddressPoisoned(old_data);
}

- (void)testClearResetsBuffer {
    circular_buffer buffer(1024);
    char *data = buffer.data();
    
    buffer.push_back('x');
    buffer.push_back('x');
    buffer.consume(1);
    buffer.clear();
    
    XCTAssertEqual(buffer.size(), 0);
    XCTAssertEqual(buffer.data(), data);
}

- (void)testReserveResizesAsNeeded {
    circular_buffer buffer(1024);
    size_t capacity = buffer.capacity();
    char *data = buffer.data();
    
    buffer.reserve(capacity - 1);
    XCTAssertEqual(buffer.capacity(), capacity);
    
    buffer.reserve(capacity);
    XCTAssertEqual(buffer.capacity(), capacity);
    
    buffer.reserve(capacity + 1);
    XCTAssertGreaterThan(buffer.capacity(), capacity);
    XCTAssertNotEqual(buffer.data(), data);
    
    AssertAddressPoisoned(data, "Buffer not deallocated");
}

- (void)testCanInsertIntoDefaultConstructedBuffer {
    std::string_view input("input");
    circular_buffer buffer;
    
    buffer.insert(input.data(), input.size());
    
    XCTAssertGreaterThanOrEqual(buffer.capacity(), input.size());
    XCTAssertEqual(buffer.size(), input.size());
    XCTAssertEqual(buffer, input);
}

- (void)testCanPushBackIntoDefaultConstructedBuffer {
    circular_buffer buffer;
    buffer.push_back('x');
    
    XCTAssertGreaterThanOrEqual(buffer.capacity(), 1);
    XCTAssertEqual(buffer.size(), 1);
    XCTAssertEqual(buffer[0], 'x');
    XCTAssertTrue(buffer.data());
}

- (void)testPushBackWithinCapacityDoesNotResize {
    circular_buffer buffer(1024);
    size_t capacity = buffer.capacity();
    char *data = buffer.data();
    
    for (int i=0; i<capacity; ++i) {
        buffer.push_back('x');
    }
    
    XCTAssertEqual(buffer.capacity(), capacity);
    XCTAssertEqual(buffer.size(), capacity);
    XCTAssertEqual(buffer.data(), data);
    XCTAssertTrue(all_of(buffer, 'x'));
}

- (void)testPushBackAtCapacityResizes {
    circular_buffer buffer(1024);
    size_t capacity = buffer.capacity();
    char *data = buffer.data();
    
    for (int i=0; i<=capacity; ++i) {
        buffer.push_back('x');
    }
    
    XCTAssertGreaterThan(buffer.capacity(), capacity);
    XCTAssertNotEqual(buffer.data(), data);
    XCTAssertTrue(all_of(buffer, 'x'));
    AssertAddressPoisoned(data, "Buffer not deallocated");
}

- (void)testInsertingCapacityDoesNotResize {
    circular_buffer buffer(1024);
    
    char *data = buffer.data();
    size_t capacity = buffer.capacity();
    std::string input(capacity, 'x');
    
    buffer.insert(input.data(), input.size());
    
    XCTAssertEqual(buffer.capacity(), capacity);
    XCTAssertEqual(buffer.data(), data);
    XCTAssertEqual(buffer.size(), input.size());
    XCTAssertEqual(buffer, input);
}

- (void)testInsertingMoreThanCapacityResizes {
    circular_buffer buffer(1024);
    
    char *data = buffer.data();
    size_t capacity = buffer.capacity();
    std::string input(capacity + 64, 'x');
    
    buffer.insert(input.data(), input.size());
    
    XCTAssertGreaterThan(buffer.capacity(), capacity);
    XCTAssertNotEqual(buffer.data(), data);
    XCTAssertEqual(buffer.size(), input.size());
    XCTAssertEqual(buffer, input);
    AssertAddressPoisoned(data, "Buffer not deallocated");
}

- (void)testCanPushBackMultiple {
    circular_buffer buffer;
    
    for (int i=0; i<16384; ++i) {
        buffer.push_back('x');
    }
    
    XCTAssertEqual(buffer.size(), 16384);
    XCTAssertTrue(all_of(buffer, 'x'));
}

- (void)testCanInsertMultiple {
    std::string_view input("1234567890123");
    std::vector<char> vector;
    circular_buffer buffer;

    for (int i=0; i<128; ++i) {
        buffer.insert(input.data(), input.size());
        vector.insert(vector.end(), input.data(), input.end());
    }
    
    XCTAssertEqual(buffer, vector);
}

- (void)testCanConsumeMultiple {
    circular_buffer buffer;
    
    for (int i=0; i<256; ++i) {
        buffer.push_back('x');
    }
    
    for (int i=256; i; --i) {
        buffer.consume(1);
        XCTAssertEqual(buffer.size(), i - 1);
    }
}

- (void)testPushBackAndConsumeDoesNotResize {
    circular_buffer buffer(1024);
    size_t capacity = buffer.capacity();
    size_t lim = capacity * 4;

    for (int i=0; i<lim; ++i) {
        char c = i % 256;
        
        buffer.push_back(c);
        XCTAssertEqual(buffer.size(), 1);
        XCTAssertEqual(buffer[0], c);
        
        buffer.consume(1);
        XCTAssertEqual(buffer.size(), 0);
        XCTAssertEqual(buffer.capacity(), capacity);
    }
}

- (void)testInsertAndConsumeDoesNotResize {
    std::string_view input("1234567890123");
    
    circular_buffer buffer(1024);
    size_t capacity = buffer.capacity();
    size_t lim = capacity * 4;

    for (int i=0; i<lim; ++i) {
        buffer.insert(input.data(), input.size());
        XCTAssertEqual(buffer.size(), input.size());
        XCTAssertEqual(buffer, input);
        
        buffer.consume(input.size());
        XCTAssertEqual(buffer.size(), 0);
        XCTAssertEqual(buffer.capacity(), capacity);
    }
}

@end
