//
//  Neovim Mac Test
//  Msgpack.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <XCTest/XCTest.h>
#include "DeathTest.h"
#include "msgpack.hpp"

template<size_t N>
static constexpr std::string_view packed_data(const char (&string)[N]) {
    return std::string_view(string, N - 1);
}

static inline bool all_a(const char *begin, const char *end) {
    while (begin != end) {
        if (*begin++ != 'a') return false;
    }
    
    return true;
}

@interface testMsgpack : XCTestCase
@end

@implementation testMsgpack : XCTestCase

 - (void)setUp {
    [super setUp];
    [self setContinueAfterFailure:NO];
}

- (void)testArrayViewDefaultConstructor {
    msg::array_view<int> view;
    XCTAssertEqual(view.data(), nullptr);
    XCTAssertEqual(view.size(), 0);
    XCTAssertEqual(view.begin(), view.end());
}

- (void)testArrayViewConstructor {
    int array[10] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    msg::array_view<int> view(array, 10);
    XCTAssertEqual(view.data(), +array);
    XCTAssertEqual(view.size(), 10);
    XCTAssertEqual(std::distance(view.begin(), view.end()), 10);
}

- (void)testArrayViewEquality {
    int array1[10] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    int array2[10] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    int array3[10] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 0};
    
    msg::array_view<int> empty;
    msg::array_view<int> view1(array1, 10);
    msg::array_view<int> view2(array2, 10);
    msg::array_view<int> view3(array3, 10);
    msg::array_view<int> subview1(array1, 5);
    
    XCTAssertTrue(view1 == view2);
    XCTAssertFalse(view1 == empty);
    XCTAssertFalse(view1 == subview1);
    XCTAssertFalse(view1 == view3);
}

- (void)testArrayViewComparisons {
    int array1[10] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    int array2[10] = {1, 2, 3, 0, 0, 0, 0, 0, 0, 0};
    
    msg::array_view<int> empty;
    msg::array_view<int> view1(array1, 10);
    msg::array_view<int> view2(array2, 10);
    msg::array_view<int> subview1(array1, 5);
    
    XCTAssertTrue(empty < view1);
    XCTAssertTrue(subview1 < view1);
    XCTAssertTrue(view2 < view1);
    XCTAssertTrue(view2 < subview1);
}

- (void)testMapViewDefaultConstructor {
    msg::map_view<msg::string, int> view;
    XCTAssertEqual(view.data(), nullptr);
    XCTAssertEqual(view.size(), 0);
    XCTAssertEqual(view.begin(), view.end());
}

- (void)testMapViewConstructor {
    using map_view = msg::map_view<msg::string, int>;
    
    map_view::value_type pairs[5] = {
        {"one", 1}, {"two", 2}, {"three", 3}, {"four", 4}, {"five", 5}
    };
    
    map_view view(pairs, 5);
    
    XCTAssertEqual(view.data(), +pairs);
    XCTAssertEqual(view.size(), 5);
    XCTAssertEqual(std::distance(view.begin(), view.end()), 5);
    XCTAssertTrue(std::is_sorted(view.begin(), view.end()));
}

- (void)testMapViewEquality {
    using map_view = msg::map_view<msg::string, int>;
    
    map_view::value_type pairs1[5] = {
        {"one", 1}, {"two", 2}, {"three", 3}, {"four", 4}, {"five", 5}
    };
    
    map_view::value_type pairs2[5] = {
        {"one", 1}, {"two", 2}, {"three", 3}, {"four", 4}, {"five", 5}
    };
    
    map_view::value_type pairs3[5] = {
        {"one", 1}, {"two", 2}, {"three", 3}, {"four", 4}, {"ten", 10}
    };
    
    map_view empty;
    map_view view1(pairs1, 5);
    map_view view2(pairs2, 5);
    map_view view3(pairs3, 5);
    map_view subview1(pairs1, 3);
    
    XCTAssertTrue(empty == empty);
    XCTAssertTrue(view1 == view2);
    XCTAssertFalse(view1 == view3);
    XCTAssertFalse(view1 == empty);
    XCTAssertFalse(view1 == subview1);
}

- (void)testMapViewComparisons {
    using map_view = msg::map_view<msg::string, int>;
    
    map_view::value_type pairs1[5] = {
        {"one", 1}, {"two", 2}, {"three", 3}, {"four", 4}, {"five", 5}
    };
    
    map_view::value_type pairs2[5] = {
        {"one", 1}, {"two", 2}, {"three", 3}, {"four", 4}, {"ten", 10}
    };
    
    map_view empty;
    map_view view1(pairs1, 5);
    map_view view2(pairs2, 5);
    map_view subview1(pairs1, 3);
    
    XCTAssertTrue(empty < view1);
    XCTAssertTrue(subview1 < view1);
    XCTAssertTrue(view1 < view2);
    XCTAssertFalse(empty < empty);
    XCTAssertFalse(view1 < view1);
}

- (void)testMapViewGet {
    using map_view = msg::map_view<msg::string, int>;
    using pair = std::pair<msg::string, int>;
    
    pair pairs[5] = {
        {"one", 1}, {"two", 2}, {"three", 3}, {"four", 4}, {"five", 5}
    };
    
    map_view view(pairs, 5);
    
    XCTAssertFalse(view.get("invalid"));
    XCTAssertEqual(1, *view.get("one"));
    XCTAssertEqual(2, *view.get("two"));
    XCTAssertEqual(3, *view.get("three"));
    XCTAssertEqual(4, *view.get("four"));
    XCTAssertEqual(5, *view.get("five"));
}

- (void)testObjectDefaultConstructor {
    msg::object object;
    XCTAssertTrue(object.is<msg::invalid>());
}

- (void)testObjectEquality {
    msg::object uniques[] = {
        msg::make_object<msg::boolean>(true),
        msg::make_object<msg::boolean>(false),
        msg::make_object<msg::integer>(128),
        msg::make_object<msg::integer>(256),
        msg::make_object<msg::string>("string"),
        msg::make_object<msg::null>(),
        msg::make_object<msg::array>()
    };

    constexpr auto size = std::size(uniques);
    auto begin = std::begin(uniques);
    auto end = std::end(uniques);
    
    msg::object copies[size];
    std::copy(begin, end, copies);
    
    for (int i=0; i<size; ++i) {
        XCTAssertTrue(std::count(begin, end, uniques[i]) == 1);
        XCTAssertTrue(uniques[i] == copies[i]);
    }
}

- (void)testObjectComparisons {
    msg::object sorted[] = {
        msg::make_object<msg::integer>(1),
        msg::make_object<msg::integer>(1),
        msg::make_object<msg::integer>(2),
        msg::make_object<msg::integer>(3),
        msg::make_object<msg::integer>(4),
    };
    
    msg::object unsorted[] = {
        msg::make_object<msg::integer>(1),
        msg::make_object<msg::integer>(3),
        msg::make_object<msg::integer>(4),
        msg::make_object<msg::integer>(1),
        msg::make_object<msg::integer>(2),
    };
    
    auto begin = std::begin(sorted);
    auto end = std::end(sorted);
    XCTAssertTrue(std::is_sorted(begin, end));
    
    std::sort(std::begin(unsorted), std::end(unsorted));
    XCTAssertTrue(std::equal(std::begin(unsorted), std::end(unsorted), sorted));
    
    sorted[3] = msg::make_object<msg::integer>(0);
    XCTAssertFalse(std::is_sorted(begin, end));
}

- (void)testUnpackerMoveConstruction {
    std::string_view string_test("\xa4test");
    
    msg::unpacker moved_from;
    moved_from.feed(string_test.data(), string_test.size());
    msg::string &str = moved_from.unpack()->get<msg::string>();

    {
        msg::unpacker moved_to(std::move(moved_from));
        AssertNoDeath(str[0] == 'x');
    }

    AssertDies(str[0] == 'x');
}

- (void)testUnpackerMoveAssignment {
    std::string_view string_test("\xa4test");
    
    msg::unpacker moved_from;
    moved_from.feed(string_test.data(), string_test.size());
    msg::string &str = moved_from.unpack()->get<msg::string>();

    {
        msg::unpacker moved_to;
        moved_to = std::move(moved_from);
        AssertNoDeath(str[0] == 'x');
    }

    AssertDies(str[0] == 'x');
}

- (void)testUnpackerMoveAssignmentDestroysObjects {
    std::string_view string_test("\xa4test");
    
    msg::unpacker moved_to;
    moved_to.feed(string_test.data(), string_test.size());
    msg::string &str = moved_to.unpack()->get<msg::string>();

    moved_to = msg::unpacker();
    AssertDies(str[0] == 'x');
}

- (void)testUnpackInvalid {
    auto packed = packed_data("\xc1");
    auto value = msg::make_object<msg::invalid>();

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackNull {
    auto packed = packed_data("\xc0");
    auto value = msg::make_object<msg::null>();

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackBooleanTrue {
    auto packed = packed_data("\xc3");
    auto value = msg::make_object<msg::boolean>(true);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackBooleanFalse {
    auto packed = packed_data("\xc2");
    auto value = msg::make_object<msg::boolean>(false);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackUnsignedIntegerFixedMin {
    auto packed = packed_data("\x00");
    auto value = msg::make_object<msg::integer>(0);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackUnsignedIntegerFixedMax {
    auto packed = packed_data("\x7f");
    auto value = msg::make_object<msg::integer>(127);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackUnsignedInteger8bit {
    auto packed = packed_data("\xcc\x80");
    auto value = msg::make_object<msg::integer>(128);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackUnsignedInteger16bit {
    auto packed = packed_data("\xcd\x01\x00");
    auto value = msg::make_object<msg::integer>(256);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackUnsignedInteger32bit {
    auto packed = packed_data("\xce\x00\x01\x00\x00");
    auto value = msg::make_object<msg::integer>(65536);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackUnsignedInteger64bit {
    auto packed = packed_data("\xcf\x00\x00\x00\x01\x00\x00\x00\x00");
    auto value = msg::make_object<msg::integer>(4294967296);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackNegativeIntegerFixedMin {
    auto packed = packed_data("\xff");
    auto value = msg::make_object<msg::integer>(-1);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackNegativeIntegerFixedMax {
    auto packed = packed_data("\xe0");
    auto value = msg::make_object<msg::integer>(-32);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackNegativeInteger8bit {
    auto packed = packed_data("\xd0\x80");
    auto value = msg::make_object<msg::integer>(-128);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackNegativeInteger16bit {
    auto packed = packed_data("\xd1\x80\x00");
    auto value = msg::make_object<msg::integer>(-32768);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackNegativeInteger32bit {
    auto packed = packed_data("\xd2\x80\x00\x00\x00");
    auto value = msg::make_object<msg::integer>(-2147483648);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackNegativeInteger64bit {
    auto packed = packed_data("\xd3\xff\xff\xff\xff\x00\x00\x00\x00");
    auto value = msg::make_object<msg::integer>(-4294967296);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackFloatZero {
    auto packed = packed_data("\xcb\x00\x00\x00\x00\x00\x00\x00\x00");
    auto value = msg::make_object<msg::float64>(0.0);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackFloatMin {
    auto packed = packed_data("\xcb\xff\xef\xff\xff\xff\xff\xff\xff");
    auto value = msg::make_object<msg::float64>(-1.7976931348623157e+308);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackFloatMax {
    auto packed = packed_data("\xcb\x7f\xef\xff\xff\xff\xff\xff\xff");
    auto value = msg::make_object<msg::float64>(1.7976931348623157e+308);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackFloatSmallest {
    auto packed = packed_data("\xcb\x00\x10\x00\x00\x00\x00\x00\x00");
    auto value = msg::make_object<msg::float64>(2.2250738585072014e-308);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackStringEmpty {
    auto packed = packed_data("\xa0");
    auto value = msg::make_object<msg::string>();

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackStringFixedMin {
    auto packed = packed_data("\xa1\x61");
    auto value = msg::make_object<msg::string>("a");

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackStringFixedMax {
    std::string string(31, 'a');
    auto packed = packed_data("\xbf\x61\x61\x61\x61\x61\x61\x61\x61\x61"
                              "\x61\x61\x61\x61\x61\x61\x61\x61\x61\x61"
                              "\x61\x61\x61\x61\x61\x61\x61\x61\x61\x61"
                              "\x61\x61");
    auto value = msg::make_object<msg::string>(string);

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackString8bitLength {
    auto packed = packed_data("\xd9\x04\x74\x65\x73\x74");
    auto value = msg::make_object<msg::string>("test");

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackString16bitLength {
    auto packed = packed_data("\xda\x00\x04\x74\x65\x73\x74");
    auto value = msg::make_object<msg::string>("test");

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackString32bitLength {
    auto packed = packed_data("\xdb\x00\x00\x00\x04\x74\x65\x73\x74");
    auto value = msg::make_object<msg::string>("test");

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackArrayEmpty {
    auto packed = packed_data("\x90");
    auto value = msg::make_object<msg::array>();

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackArrayFixedMin {
    std::array<msg::object, 1> array = {
        msg::integer(0)
    };

    auto packed = packed_data("\x91\x00");
    auto value = msg::make_object<msg::array>(array.data(), array.size());

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackArrayFixedMax {
    std::array<msg::object, 15> array = {
        msg::integer(0),
        msg::integer(1),
        msg::integer(2),
        msg::integer(3),
        msg::integer(4),
        msg::integer(5),
        msg::integer(6),
        msg::integer(7),
        msg::integer(8),
        msg::integer(9),
        msg::integer(10),
        msg::integer(11),
        msg::integer(12),
        msg::integer(13),
        msg::integer(14)
    };

    auto packed = packed_data("\x9f\x00\x01\x02\x03\x04\x05\x06\x07\x08"
                              "\x09\x0a\x0b\x0c\x0d\x0e");
    auto value = msg::make_object<msg::array>(array.data(), array.size());

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackArray16bitLength {
    std::array<msg::object, 4> array = {
        msg::integer(0),
        msg::integer(1),
        msg::integer(2),
        msg::integer(3)
    };

    auto packed = packed_data("\xdc\x00\x04\x00\x01\x02\x03");
    auto value = msg::make_object<msg::array>(array.data(), array.size());

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackArray32bitLength {
    std::array<msg::object, 4> array = {
        msg::integer(0),
        msg::integer(1),
        msg::integer(2),
        msg::integer(3)
    };

    auto packed = packed_data("\xdd\x00\x00\x00\x04\x00\x01\x02\x03");
    auto value = msg::make_object<msg::array>(array.data(), array.size());

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackArrayRecursive {
    std::array<msg::object, 1> rec1{{
        msg::make_object<msg::array>()
    }};
    
    std::array<msg::object, 1> rec2{{
        msg::make_object<msg::array>(rec1.data(), rec1.size())
    }};
    
    std::array<msg::object, 1> rec3{{
        msg::make_object<msg::array>(rec2.data(), rec2.size())
    }};
    
    std::array<msg::object, 1> rec4{{
        msg::make_object<msg::array>(rec3.data(), rec3.size())
    }};
    
    auto packed = packed_data("\x91\x91\x91\x91\x90");
    auto value = msg::make_object<msg::array>(rec4.data(), rec4.size());

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackArrayHeterogeneous {
    std::array<msg::object, 3> array{{
        msg::make_object<msg::integer>(123),
        msg::make_object<msg::string>("test"),
        msg::make_object<msg::boolean>(true)
    }};
    
    auto packed = packed_data("\x93\x7b\xa4\x74\x65\x73\x74\xc3");
    auto value = msg::make_object<msg::array>(array.data(), array.size());

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackMapEmpty {
    auto packed = packed_data("\x80");
    auto value = msg::make_object<msg::map>();

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackMapFixedMin {
    std::array<msg::pair, 1> map = {{
        {msg::string("0"), msg::integer(0)}
    }};

    auto packed = packed_data("\x81\xa1\x30\x00");
    auto value = msg::make_object<msg::map>(map.data(), map.size());

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackMapFixedMax {
    std::array<msg::pair, 15> map = {{
        {msg::string("0"), msg::integer(0)},
        {msg::string("1"), msg::integer(1)},
        {msg::string("2"), msg::integer(2)},
        {msg::string("3"), msg::integer(3)},
        {msg::string("4"), msg::integer(4)},
        {msg::string("5"), msg::integer(5)},
        {msg::string("6"), msg::integer(6)},
        {msg::string("7"), msg::integer(7)},
        {msg::string("8"), msg::integer(8)},
        {msg::string("9"), msg::integer(9)},
        {msg::string("10"), msg::integer(10)},
        {msg::string("11"), msg::integer(11)},
        {msg::string("12"), msg::integer(12)},
        {msg::string("13"), msg::integer(13)},
        {msg::string("14"), msg::integer(14)}
    }};

    auto packed = packed_data("\x8f\xa1\x30\x00\xa1\x31\x01\xa1\x32\x02"
                              "\xa1\x33\x03\xa1\x34\x04\xa1\x35\x05\xa1"
                              "\x36\x06\xa1\x37\x07\xa1\x38\x08\xa1\x39"
                              "\x09\xa2\x31\x30\x0a\xa2\x31\x31\x0b\xa2"
                              "\x31\x32\x0c\xa2\x31\x33\x0d\xa2\x31\x34"
                              "\x0e");
    auto value = msg::make_object<msg::map>(map.data(), map.size());

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackMap16bitLength {
    std::array<msg::pair, 3> map = {{
        {msg::string("0"), msg::integer(0)},
        {msg::string("1"), msg::integer(1)},
        {msg::string("2"), msg::integer(2)}
    }};

    auto packed = packed_data("\xde\x00\x03\xa1\x30\x00\xa1\x31\x01\xa1"
                              "\x32\x02");
    auto value = msg::make_object<msg::map>(map.data(), map.size());

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testUnpackMap32bitLength {
    std::array<msg::pair, 3> map = {{
        {msg::string("0"), msg::integer(0)},
        {msg::string("1"), msg::integer(1)},
        {msg::string("2"), msg::integer(2)}
    }};

    auto packed = packed_data("\xdf\x00\x00\x00\x03\xa1\x30\x00\xa1\x31"
                              "\x01\xa1\x32\x02");
    auto value = msg::make_object<msg::map>(map.data(), map.size());

    msg::unpacker unpacker;
    unpacker.feed(packed.data(), packed.size());
    msg::object *obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());

    for (const char &byte : packed) {
        XCTAssertFalse(unpacker.unpack());
        unpacker.feed(&byte, 1);
    }

    obj = unpacker.unpack();

    XCTAssertTrue(obj);
    XCTAssertTrue(*obj == value);
    XCTAssertFalse(unpacker.unpack());
}

- (void)testPackNull {
    auto packed = packed_data("\xc0");
    msg::packer packer;
    packer.pack_null();

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackBooleanTrue {
    auto packed = packed_data("\xc3");
    msg::packer packer;
    packer.pack_bool(true);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackBooleanFalse {
    auto packed = packed_data("\xc2");
    msg::packer packer;
    packer.pack_bool(false);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackUnsignedIntegerZero {
    auto packed = packed_data("\x00");
    msg::packer packer;
    packer.pack_uint64(0);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackUnsignedIntegerOne {
    auto packed = packed_data("\x01");
    msg::packer packer;
    packer.pack_uint64(1);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackUnsignedIntegerFixedMax {
    auto packed = packed_data("\x7f");
    msg::packer packer;
    packer.pack_uint64(127);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackUnsignedInteger8bitMin {
    auto packed = packed_data("\xcc\x80");
    msg::packer packer;
    packer.pack_uint64(128);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackUnsignedInteger8bitMax {
    auto packed = packed_data("\xcc\xff");
    msg::packer packer;
    packer.pack_uint64(255);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackUnsignedInteger16bitMin {
    auto packed = packed_data("\xcd\x01\x00");
    msg::packer packer;
    packer.pack_uint64(256);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackUnsignedInteger16bitMax {
    auto packed = packed_data("\xcd\xff\xff");
    msg::packer packer;
    packer.pack_uint64(65535);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackUnsignedInteger32bitMin {
    auto packed = packed_data("\xce\x00\x01\x00\x00");
    msg::packer packer;
    packer.pack_uint64(65536);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackUnsignedInteger32bitMax {
    auto packed = packed_data("\xce\xff\xff\xff\xff");
    msg::packer packer;
    packer.pack_uint64(4294967295);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackUnsignedInteger64bitMin {
    auto packed = packed_data("\xcf\x00\x00\x00\x01\x00\x00\x00\x00");
    msg::packer packer;
    packer.pack_uint64(4294967296);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackUnsignedInteger64bitMax {
    auto packed = packed_data("\xcf\xff\xff\xff\xff\xff\xff\xff\xff");
    msg::packer packer;
    packer.pack_uint64(18446744073709551615u);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackSignedIntegerZero {
    auto packed = packed_data("\x00");
    msg::packer packer;
    packer.pack_int64(0);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackSingedIntegerPositive {
    auto packed = packed_data("\x01");
    msg::packer packer;
    packer.pack_int64(1);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackNegativeIntegerFixedMax {
    auto packed = packed_data("\xff");
    msg::packer packer;
    packer.pack_int64(-1);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackNegativeIntegerFixedMin {
    auto packed = packed_data("\xe0");
    msg::packer packer;
    packer.pack_int64(-32);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackNegativeInteger8bitMax {
    auto packed = packed_data("\xd0\xdf");
    msg::packer packer;
    packer.pack_int64(-33);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackNegativeInteger8bitMin {
    auto packed = packed_data("\xd0\x80");
    msg::packer packer;
    packer.pack_int64(-128);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackNegativeInteger16bitMax {
    auto packed = packed_data("\xd1\xff\x7f");
    msg::packer packer;
    packer.pack_int64(-129);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackNegativeInteger16bitMin {
    auto packed = packed_data("\xd1\x80\x00");
    msg::packer packer;
    packer.pack_int64(-32768);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackNegativeInteger32bitMax {
    auto packed = packed_data("\xd2\xff\xff\x7f\xff");
    msg::packer packer;
    packer.pack_int64(-32769);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackNegativeInteger32bitMin {
    auto packed = packed_data("\xd2\x80\x00\x00\x00");
    msg::packer packer;
    packer.pack_int64(-2147483648);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackNegativeInteger64bitMax {
    auto packed = packed_data("\xd3\xff\xff\xff\xff\x7f\xff\xff\xff");
    msg::packer packer;
    packer.pack_int64(-2147483649);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackNegativeInteger64bitMin {
    auto packed = packed_data("\xd3\x80\x00\x00\x00\x00\x00\x00\x00");
    msg::packer packer;
    packer.pack_int64(-9223372036854775808u);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackFloatZero {
    auto packed = packed_data("\xcb\x00\x00\x00\x00\x00\x00\x00\x00");
    msg::packer packer;
    packer.pack_float64(0.0);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackFloatMin {
    auto packed = packed_data("\xcb\xff\xef\xff\xff\xff\xff\xff\xff");
    msg::packer packer;
    packer.pack_float64(-1.7976931348623157e+308);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackFloatMax {
    auto packed = packed_data("\xcb\x7f\xef\xff\xff\xff\xff\xff\xff");
    msg::packer packer;
    packer.pack_float64(1.7976931348623157e+308);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackFloatSmallest {
    auto packed = packed_data("\xcb\x00\x10\x00\x00\x00\x00\x00\x00");
    msg::packer packer;
    packer.pack_float64(2.2250738585072014e-308);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStringLiteral {
    auto packed = packed_data("\xa4\x74\x65\x73\x74");
    msg::packer packer;
    packer.pack_string("test");

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStringView {
    auto packed = packed_data("\xa4\x74\x65\x73\x74");
    msg::packer packer;
    packer.pack_string(std::string_view("test"));

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackString {
    auto packed = packed_data("\xa4\x74\x65\x73\x74");
    msg::packer packer;
    packer.pack_string(std::string("test"));

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStringEmpty {
    auto packed = packed_data("\xa0");
    msg::packer packer;
    packer.pack_string(msg::string());

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStringFixedMin {
    auto packed = packed_data("\xa1");
    msg::packer packer;
    std::string string(1, 'a');
    packer.pack_string(string);

    XCTAssertEqual(packer.size(), packed.size() + string.size());
    XCTAssertEqual(msg::string(packer.data(), packed.size()), packed);
    XCTAssertTrue(all_a(packer.begin() + packed.size(), packer.end()));
}

- (void)testPackStringFixedMax {
    auto packed = packed_data("\xbf");
    msg::packer packer;
    std::string string(31, 'a');
    packer.pack_string(string);

    XCTAssertEqual(packer.size(), packed.size() + string.size());
    XCTAssertEqual(msg::string(packer.data(), packed.size()), packed);
    XCTAssertTrue(all_a(packer.begin() + packed.size(), packer.end()));
}

- (void)testPackString8bitMin {
    auto packed = packed_data("\xd9\x20");
    msg::packer packer;
    std::string string(32, 'a');
    packer.pack_string(string);

    XCTAssertEqual(packer.size(), packed.size() + string.size());
    XCTAssertEqual(msg::string(packer.data(), packed.size()), packed);
    XCTAssertTrue(all_a(packer.begin() + packed.size(), packer.end()));
}

- (void)testPackString8bitMax {
    auto packed = packed_data("\xd9\xff");
    msg::packer packer;
    std::string string(255, 'a');
    packer.pack_string(string);

    XCTAssertEqual(packer.size(), packed.size() + string.size());
    XCTAssertEqual(msg::string(packer.data(), packed.size()), packed);
    XCTAssertTrue(all_a(packer.begin() + packed.size(), packer.end()));
}

- (void)testPackString16bitMin {
    auto packed = packed_data("\xda\x01\x00");
    msg::packer packer;
    std::string string(256, 'a');
    packer.pack_string(string);

    XCTAssertEqual(packer.size(), packed.size() + string.size());
    XCTAssertEqual(msg::string(packer.data(), packed.size()), packed);
    XCTAssertTrue(all_a(packer.begin() + packed.size(), packer.end()));
}

- (void)testPackString16bitMax {
    auto packed = packed_data("\xda\xff\xff");
    msg::packer packer;
    std::string string(65535, 'a');
    packer.pack_string(string);

    XCTAssertEqual(packer.size(), packed.size() + string.size());
    XCTAssertEqual(msg::string(packer.data(), packed.size()), packed);
    XCTAssertTrue(all_a(packer.begin() + packed.size(), packer.end()));
}

- (void)testPackString32bitMin {
    auto packed = packed_data("\xdb\x00\x01\x00\x00");
    msg::packer packer;
    std::string string(65536, 'a');
    packer.pack_string(string);

    XCTAssertEqual(packer.size(), packed.size() + string.size());
    XCTAssertEqual(msg::string(packer.data(), packed.size()), packed);
    XCTAssertTrue(all_a(packer.begin() + packed.size(), packer.end()));
}

- (void)testPackArray {
    auto packed = packed_data("\x94\x01\x02\x03\x04");
    msg::packer packer;
    packer.pack_array(std::vector{1, 2, 3, 4});
    
    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackArrayTuple {
    auto packed = packed_data("\x92\xa3\x6f\x6e\x65\x01");
    msg::packer packer;
    packer.pack_tuple(std::tuple<std::string, int>("one", 1));

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackArrayEmpty {
    auto packed = packed_data("\x90");
    msg::packer packer;
    packer.pack_array(std::vector<uint64_t>());

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackArrayRecursive {
    auto packed = packed_data("\x91\x91\x91\x91\x90");
    msg::packer packer;
    packer.start_array(1);
    packer.start_array(1);
    packer.start_array(1);
    packer.start_array(1);
    packer.start_array(0);
    
    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testStartPackArrayEmpty {
    auto packed = packed_data("\x90");
    msg::packer packer;
    packer.start_array(0);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartArrayFixedMin {
    auto packed = packed_data("\x91");
    msg::packer packer;
    packer.start_array(1);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartArrayFixedMax {
    auto packed = packed_data("\x9f");
    msg::packer packer;
    packer.start_array(15);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartArray16bitMin {
    auto packed = packed_data("\xdc\x01\x00");
    msg::packer packer;
    packer.start_array(256);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartArray16bitMax {
    auto packed = packed_data("\xdc\xff\xff");
    msg::packer packer;
    packer.start_array(65535);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartArray32bitMin {
    auto packed = packed_data("\xdd\x00\x01\x00\x00");
    msg::packer packer;
    packer.start_array(65536);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartArray32bitMax {
    auto packed = packed_data("\xdd\xff\xff\xff\xff");
    msg::packer packer;
    packer.start_array(4294967295);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackMap {
    auto packed = packed_data("\x83\xa1\x30\x00\xa1\x31\x01\xa1\x32\x02");
    msg::packer packer;
    packer.pack_map(std::vector{
        std::pair("0", 0),
        std::pair("1", 1),
        std::pair("2", 2)
    });

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackMapEmpty {
    auto packed = packed_data("\x80");
    msg::packer packer;
    packer.pack_map(std::vector<std::pair<int, int>>());

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartMapEmpty {
    auto packed = packed_data("\x80");
    msg::packer packer;
    packer.start_map(0);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartMapFixedMin {
    auto packed = packed_data("\x81");
    msg::packer packer;
    packer.start_map(1);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartMapFixedMax {
    auto packed = packed_data("\x8f");
    msg::packer packer;
    packer.start_map(15);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartMap16bitMin {
    auto packed = packed_data("\xde\x01\x00");
    msg::packer packer;
    packer.start_map(256);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartMap16bitMax {
    auto packed = packed_data("\xde\xff\xff");
    msg::packer packer;
    packer.start_map(65535);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartMap32bitMin {
    auto packed = packed_data("\xdf\x00\x01\x00\x00");
    msg::packer packer;
    packer.start_map(65536);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackStartMap32bitMax {
    auto packed = packed_data("\xdf\xff\xff\xff\xff");
    msg::packer packer;
    packer.start_map(4294967295);

    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

- (void)testPackGeneric {
    auto packed = packed_data("\xc3\xcd\x01\xb0\xcb\x40\x09\x1e\xb8\x51"
                              "\xeb\x85\x1f\xa6\x73\x74\x72\x69\x6e\x67"
                              "\x94\x01\x02\x03\x04\x83\xa1\x30\x00\xa1"
                              "\x31\x01\xa1\x32\x02\x92\xa5\x74\x75\x70"
                              "\x6c\x65\x01");

    msg::packer packer;
    packer.pack(true);
    packer.pack(432);
    packer.pack(3.14);
    packer.pack("string");
    packer.pack(std::vector{1, 2, 3, 4});

    packer.pack(std::vector{
        std::pair("0", 0),
        std::pair("1", 1),
        std::pair("2", 2)
    });

    packer.pack(std::tuple<std::string, int>("tuple", 1));
    
    XCTAssertEqual(msg::string(packer.data(), packer.size()), packed);
}

@end
