//
//  Neovim Mac
//  msgpack.hpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef MSGPACK_HPP
#define MSGPACK_HPP

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <variant>
#include <vector>
#include <experimental/coroutine>

#include "bump_allocator.hpp"
#include "circular_buffer.hpp"

/// MessagePack Serialization
///
/// Summary:
///   msg::object   - Represents a MessagePack Object.
///   msg::unpacker - Deserializes a MessagePack byte stream into C++ objects.
///   msg::packer   - Serializes C++ objects into a MessagePack byte stream.

namespace msg {

/// Holds a contiguous sequence of objects of type T.
template<typename T>
class array_view {
private:
    T *ptr;
    size_t length;

public:
    using value_type = T;

    array_view(): ptr(nullptr), length(0) {}
    array_view(T *ptr, size_t size): ptr(ptr), length(size) {}

    T* data() {
        return ptr;
    }

    const T* data() const {
        return ptr;
    }

    T* begin() {
        return ptr;
    }

    const T* begin() const {
        return ptr;
    }

    T* end() {
        return ptr + length;
    }

    const T* end() const {
        return ptr + length;
    }

    size_t size() const {
        return length;
    }
    
    T& at(size_t index) {
        return ptr[index];
    }

    const T& at(size_t index) const {
        return ptr[index];
    }

    T& operator[](size_t index) {
        return ptr[index];
    }

    const T& operator[](size_t index) const {
        return ptr[index];
    }
    
    array_view subarray(size_t start) const {
        return array_view(ptr + start, length - start);
    }
    
    array_view subarray(size_t start, size_t size) const {
        return array_view(ptr + start, size);
    }
};

template<typename T>
bool operator==(const array_view<T> &left, const array_view<T> &right) {
    return std::equal(left.begin(), left.end(), right.begin(), right.end());
}

template<typename T>
bool operator<(const array_view<T> &left, const array_view<T> &right) {
    return std::lexicographical_compare(left.begin(), left.end(),
                                        right.begin(), right.end());
}

/// Holds a contiguous sequence of Key Value pairs.
template<typename Key, typename Value>
class map_view : public array_view<std::pair<Key, Value>> {
public:
    using array_view<std::pair<Key, Value>>::array_view;

    const Value* get(const Key &key) const {
        for (const auto &pair : *this) {
            if (pair.first == key) {
                return &pair.second;
            }
        }

        return nullptr;
    }

    /// Returns A pointer to the value mapped to key.
    /// If no such value exists, returns nullptr.
    /// Note: get() is implemented as a linear search. For perfomant lookup on
    /// large maps, sort the underlying array and use a binary search.
    Value* get(const Key &key) {
        return const_cast<Value*>(std::as_const(*this).get(key));
    }
};

/// Represents a msgpack integer.
///
/// Note: Sign information is lost when unpacking. We could add a boolean to
/// preserve signedness, but it seems pointless. We usually know if we require
/// a signed or unsigned representation at the point of use.
class integer {
private:
    char storage[8];

public:
    template<typename Int, std::enable_if_t<std::is_integral_v<Int>, int> = 0>
    integer(Int val) {
        if constexpr (std::is_signed_v<Int>) {
            int64_t val64 = val;
            memcpy(storage, &val64, 8);
        } else {
            uint64_t val64 = val;
            memcpy(storage, &val64, 8);
        }
    }

    /// Get the value of integer as a signed 64bit integer.
    int64_t signed_value() const {
        int64_t ret;
        memcpy(&ret, storage, 8);
        return ret;
    }

    /// Get the value of integer as a unsigned 64bit integer.
    uint64_t unsigned_value() const {
        uint64_t ret;
        memcpy(&ret, storage, 8);
        return ret;
    }

    /// Get the value of integer as a T.
    template<typename T>
    T as() const {
        static_assert(std::is_integral_v<T>, "Integral types only!");

        if constexpr (std::is_signed_v<T>) {
            return static_cast<T>(signed_value());
        } else {
            return static_cast<T>(unsigned_value());
        }
    }

    /// Implicitly convert to an unsigned 64bit integer.
    /// Note: Equality and comparisons is done in terms of unsigned values.
    operator uint64_t() const {
        return unsigned_value();
    }
};

struct extension : msg::array_view<char> {
    using array_view::array_view;
};

struct object;
struct invalid : std::monostate {};
struct null    : std::monostate {};

using boolean = bool;
using float64 = double;
using string  = std::string_view;
using binary  = msg::array_view<unsigned char>;
using array   = msg::array_view<object>;
using map     = msg::map_view<object, object>;
using pair    = std::pair<object, object>;

/// Represents a MessagePack Object. A variant of all MessagePack types.
///
/// Type mappings:
///
/// | MessagePack Type | C++ Type         |
/// | ---------------- | ---------------- |
/// | Nil              | msg::null        |
/// | Boolean          | msg::boolean     |
/// | Integer          | msg::integer     |
/// | Float            | msg::float64     |
/// | String           | msg::string      |
/// | Binary           | msg::binary      |
/// | Array            | msg::array       |
/// | Map              | msg::map         |
/// | Extension        | msg::extension   |
///
/// Objects are trivial and cheap to copy reference types. They do not manage
/// any underlying memory. Inherits from std::variant, and can be used as such.
struct object : std::variant<msg::invalid,
                             msg::null,
                             msg::integer,
                             msg::float64,
                             msg::boolean,
                             msg::string,
                             msg::binary,
                             msg::extension,
                             msg::array,
                             msg::map> {
    using variant::variant;
    using variant_type = variant;
                                 
    /// Test if the currently held object is of type T.
    /// @returns True if object currently holds a T else false.
    template<typename T>
    bool is() const {
        return std::holds_alternative<T>(*this);
    }

    /// Precondition: this->is<T>() returns true.
    /// @returns A reference to the currently held object.
    template<typename T>
    const T& get() const {
        return std::get<T>(*this);
    }

    template<typename T>
    T& get() {
        return std::get<T>(*this);
    }
                                 
    template<typename T>
    T* get_if() {
        return std::get_if<T>(this);
    }
                                 
    template<typename T>
    const T* get_if() const {
        return std::get_if<T>(this);
    }
};

/// Factory function for nicer syntax.
template<typename T, typename ...Args>
object make_object(const Args& ...args) {
    return msg::object(T(args...));
}

/// Convert an object to a string representation.
std::string to_string(const msg::object &obj);

/// @returns A string representation of the objects type.
std::string type_string(const msg::object &obj);

/// Deserializes a stream of MessagePack encoded bytes into C++ objects.
///
/// The unpacker interface is split into two parts, feeding and unpacking.
/// MessagePack data, possibly incomplete, possibly multiple objects, is fed to
/// the unpacker. This data is then unpacked one object at a time by repeatedly
/// calling unpack. Once the data has been fully unpacked, unpack returns
/// nullptr. Example:
///
///     msg::unpacker unpacker;
///     unpacker.feed(data, length);
///
///     while (msg::object *obj = unpacker.unpack()) {
///         use_object(*obj);
///     }
///
/// Unpackers manage the underlying memory of the objects they produce. At most
/// one object - the last unpacked object - is valid at any given time.
class unpacker {
public:
    class promise_type;
    using handle_type = std::experimental::coroutine_handle<promise_type>;

    // Unpacking is implemented as a C++20 coroutine. Clang complains if the
    // promise type is not public. Hopefully that changes soon.
    //
    // The coroutine is an infinite loop that reads data and produces objects.
    // Data is read from the input buffer via read_bytes and read_numeric.
    //
    // The coroutine suspends itself in two cases:
    //   1. When it has finished unpacking an object.
    //   2. A call to read_bytes or read_numeric ran out of input data.
    //
    // In the first case, the coroutine co_yields a pointer to the unpacked
    // object, we store it in the promise_type and return it to the caller of
    // unpack().
    //
    // In the second case, a read operation stalled because it ran out of data.
    // A description of the remaining operation is stored in the promise_type.
    // Before the coroutine is resumed we ensure this operation is completed.
    //
    // @field obj       Pointer to the unpacked object.
    // @field buffer    Pointer to the input buffer.
    // @field length    Size of the input buffer.
    // @field waitbuff  Pointer to the destination of an outstanding copy.
    // @field waitlen   Size of the outstanding copy.
    class promise_type {
    private:
        object *obj;
        const char *buffer;
        size_t length;
        char *waitbuff;
        size_t waitlen;

        promise_type():
            obj(nullptr),
            buffer(nullptr),
            length(0),
            waitbuff(nullptr),
            waitlen(0) {}

        unpacker get_return_object() noexcept {
            return unpacker(this, handle_type::from_promise(*this));
        }

        auto initial_suspend() noexcept {
            return std::experimental::suspend_never();
        }

        auto final_suspend() noexcept {
            return std::experimental::suspend_never();
        }

        auto yield_value(msg::object *value) noexcept {
            // We've unpacked an object. Store a pointer to it and suspend.
            obj = value;
            return std::experimental::suspend_always();
        }

        void unhandled_exception() {
            std::abort();
        }

        void return_void() {}

        object* unpack(handle_type handle) {
            // Before we can resume the coroutine, we've got to complete any
            // outstanding copy operations it's waiting on.
            if (UNLIKELY(waitlen > length)) {
                // We don't have enough data to finish the copy. Copy what we
                // have and return nullptr. The input buffer has been exhausted.
                memcpy(waitbuff, buffer, length);
                waitbuff += length;
                waitlen -= length;
                length = 0;

                return nullptr;
            }

            // Complete the copy and resume.
            memcpy(waitbuff, buffer, waitlen);
            buffer += waitlen;
            length -= waitlen;
            waitlen = 0;

            handle.resume();
            return obj;
        }

        auto read_bytes(void *dest, size_t size);

        template<typename T>
        auto read_numeric();

        friend class unpacker;
    };

private:
    promise_type *promise;
    handle_type handle;

    // The actual coroutine
    static unpacker make();

    unpacker(promise_type *promise, handle_type handle):
        promise(promise), handle(handle) {}

public:
    unpacker() {
        *this = make();
    }

    unpacker(const unpacker&) = delete;
    unpacker& operator=(const unpacker&) = delete;

    unpacker(unpacker &&other) {
        promise = other.promise;
        handle = other.handle;
        other.handle = nullptr;
    }

    unpacker& operator=(unpacker &&other) {
        if (handle) handle.destroy();

        promise = other.promise;
        handle = other.handle;
        other.handle = nullptr;

        return *this;
    }

    ~unpacker() {
        if (handle) handle.destroy();
    }

    /// Feed an input buffer to the unpacker. Feeding further data before
    /// the previous input buffer has been exhausted is undefined.
    ///
    /// The unpacker will not take ownership of the input buffer, it is the
    /// responsibility the caller to ensure the buffer lives until it has been
    /// fully unpacked.
    void feed(const void *buffer, size_t length) {
        assert(!promise->length && "Not completely unpacked");
        promise->buffer = static_cast<const char*>(buffer);
        promise->length = length;
    }

    /// Unpacks any data that was previously fed to the unpacker.
    ///
    /// Objects produced by this function are valid until:
    ///   * Subsequent calls to unpack().
    ///   * The lifetime of the unpacker ends.
    ///
    /// Once this function returns nullptr:
    ///   * The underlying input buffer is safe to free.
    ///   * The unpacker can be fed more data.
    ///
    /// @returns A pointer to an unpacked object, or nullptr if the input
    ///          buffer has been exhausted.
    object* unpack() {
        return promise->unpack(handle);
    }
};

namespace detail {

// Helper template that maps numeric types to an unsigned type of equal size.
template<size_t> struct unsigned_equivalent_impl {};
template<> struct unsigned_equivalent_impl<1> { using type = uint8_t;  };
template<> struct unsigned_equivalent_impl<2> { using type = uint16_t; };
template<> struct unsigned_equivalent_impl<4> { using type = uint32_t; };
template<> struct unsigned_equivalent_impl<8> { using type = uint64_t; };

template<typename T>
using unsigned_equivalent = typename unsigned_equivalent_impl<sizeof(T)>::type;

// Byteswapping functions to wrap compiler intrinsics.
inline uint8_t byteswap(uint8_t val) {
    return val;
}

inline uint16_t byteswap(uint16_t val) {
    return __builtin_bswap16(val);
}

inline uint32_t byteswap(uint32_t val) {
    return __builtin_bswap32(val);
}

inline uint64_t byteswap(uint64_t val) {
    return __builtin_bswap64(val);
}

} // namesapce detail

/// Serializes C++ objects into a stream of MessagePack encoded bytes.
///
/// Packers store their output stream in a circular_buffer. The interface of the
/// underlying buffer is forwarded by the packer object.
class packer {
private:
    circular_buffer buffer;

    // Returns the first byte of MessagePack
    template<typename T>
    static constexpr unsigned char first_byte() {
        static_assert(std::is_arithmetic_v<T>, "Numeric types only");

        constexpr int offsets[] = {
            [1] = 0, [2] = 1, [4] = 2, [8] = 3
        };

        if (std::is_floating_point_v<T>) {
            return 0xca + offsets[sizeof(T)] - 2;
        } else if (std::is_unsigned_v<T>) {
            return 0xcc + offsets[sizeof(T)];
        } else {
            return 0xd0 + offsets[sizeof(T)];
        }
    }

    template<typename PackType, unsigned char FirstByte, typename T>
    void pack_numeric_impl(T val) {
        // Explicit conversion avoids compiler warnings
        const PackType converted = static_cast<PackType>(val);

        // Byteswapping functions work with unsigned types, so we use an
        // unsigned equivalent. We memcpy into the unsigned type to avoid
        // float to integer conversions.
        detail::unsigned_equivalent<PackType> swapped;
        memcpy(&swapped, &converted, sizeof(PackType));
        swapped = detail::byteswap(swapped);

        unsigned char append[sizeof(PackType) + 1] = {FirstByte};
        memcpy(append + 1, &swapped, sizeof(PackType));
        buffer.insert(append, sizeof(PackType) + 1);
    }

    // Type trait to detect if T is a std::pair
    template <typename T>
    struct is_pair : std::false_type {};

    template <typename T, typename U>
    struct is_pair<std::pair<T, U>> : std::true_type {};

    // Type trait to detect if T is a std::tuple
    template <typename T>
    struct is_tuple : std::false_type {};

    template <typename ...Ts>
    struct is_tuple<std::tuple<Ts...>> : std::true_type {};

public:
    packer(): buffer(4096) {}

    explicit packer(size_t initial_capacity): buffer(initial_capacity) {}

    /// Returns the number of unconsumed bytes.
    size_t size() const {
        return buffer.size();
    }

    /// Returns a pointer to the byte stream. Valid up to data() + size().
    const char* data() const {
        return buffer.data();
    }

    char* data() {
        return buffer.data();
    }

    /// Begin iterator to the packed byte stream.
    const char* begin() const {
        return buffer.begin();
    }

    char* begin() {
        return buffer.begin();
    }

    /// End iterator to the packed byte stream.
    const char* end() const {
        return buffer.end();
    }

    char* end() {
        return buffer.end();
    }

    /// Consume size bytes from the packed byte stream.
    void consume(size_t size) {
        buffer.consume(size);
    }

    /// Clear all packed data. After this call size() returns 0.
    void clear() {
        buffer.clear();
    }

    /// Explicitly pack a numeric value as PackType. This function does not
    /// optimize for the number of bytes it produces - it will always produce
    /// sizeof(T) + 1 bytes. This avoids some overhead.
    template<typename PackType, typename T>
    void pack_numeric(T val) {
        pack_numeric_impl<PackType, first_byte<PackType>()>(val);
    }

    void pack_uint64(uint64_t val) {
        if (val < 128) {
            buffer.push_back(val);
        } else if (val <= std::numeric_limits<uint8_t>::max()) {
            pack_numeric<uint8_t>(val);
        } else if (val <= std::numeric_limits<uint16_t>::max()) {
            pack_numeric<uint16_t>(val);
        } else if (val <= std::numeric_limits<uint32_t>::max()) {
            pack_numeric<uint32_t>(val);
        } else {
            pack_numeric<uint64_t>(val);
        }
    }

    void pack_int64(int64_t val) {
        if (val >= 0) {
            pack_uint64(val);
        } else if (val >= -32) {
            buffer.push_back(val);
        } else if (val >= std::numeric_limits<int8_t>::min()) {
            pack_numeric<int8_t>(val);
        } else if (val >= std::numeric_limits<int16_t>::min()) {
            pack_numeric<int16_t>(val);
        } else if (val >= std::numeric_limits<int32_t>::min()) {
            pack_numeric<int32_t>(val);
        } else {
            pack_numeric<int64_t>(val);
        }
    }

    void pack_float64(float64 val) {
        pack_numeric<float64>(val);
    }

    /// Generic pack function. Packs as the most suitable type.
    template<typename A>
    void pack(const A &val) {
        // Overloading on these types would be a mess.
        // So we're doing this instead.
        if constexpr (std::is_same_v<A, boolean>) {
            pack_bool(val);
        } else if constexpr (std::is_floating_point_v<A>) {
            pack_float64(val);
        } else if constexpr (std::is_unsigned_v<A>) {
            pack_uint64(val);
        } else if constexpr (std::is_signed_v<A>) {
            pack_int64(val);
        } else if constexpr (std::is_constructible_v<string, A>) {
            pack_string(val);
        } else if constexpr (is_tuple<A>::value) {
            pack_tuple(val);
        } else if constexpr (is_pair<typename A::value_type>::value) {
            pack_map(val);
        } else {
            pack_array(val);
        }
    }

    void pack_string(string val) {
        size_t size = val.size();

        if (size <= 31) {
            buffer.push_back(0b10100000u | size);
        } else if (size <= std::numeric_limits<uint8_t>::max()) {
            pack_numeric_impl<uint8_t, 0xd9>(size);
        } else if (size <= std::numeric_limits<uint16_t>::max()) {
            pack_numeric_impl<uint16_t, 0xda>(size);
        } else {
            pack_numeric_impl<uint32_t, 0xdb>(size);
        }

        buffer.insert(val.data(), val.size());
    }

    void pack_bool(boolean val) {
        buffer.push_back(0xc2 + val);
    }

    void pack_null() {
        buffer.push_back(0xc0);
    }

    /// Start an array with n objects.
    /// Note: Must be followed by packing n objects.
    void start_array(uint32_t len) {
        if (len <= 15) {
            buffer.push_back(0b10010000u | len);
        } else if (len <= std::numeric_limits<uint16_t>::max()) {
            pack_numeric_impl<uint16_t, 0xdc>(len);
        } else {
            pack_numeric_impl<uint32_t, 0xdd>(len);
        }
    }

    /// Start a map with n key value pairs.
    /// Note: Must be followed by packing n*2 objects.
    void start_map(uint32_t len) {
        if (len <= 15) {
            buffer.push_back(0b10000000u | len);
        } else if (len <= std::numeric_limits<uint16_t>::max()) {
            pack_numeric_impl<uint16_t, 0xde>(len);
        } else {
            pack_numeric_impl<uint32_t, 0xdf>(len);
        }
    }

    /// Pack a container of objects as an array.
    template<typename Array>
    void pack_array(const Array &array) {
        start_array((uint32_t)array.size());

        for (const auto &value : array) {
            pack(value);
        }
    }

    /// Pack a container of key value pairs as a map.
    template<typename Map>
    void pack_map(const Map &map) {
        start_map((uint32_t)map.size());

        for (const auto &[key, value] : map) {
            pack(key);
            pack(value);
        }
    }

    /// Pack a tuple as a heterogenous array.
    template<typename ...Ts>
    void pack_tuple(const std::tuple<Ts...> &tuple) {
        start_array((uint32_t)sizeof...(Ts));

        std::apply([this](Ts const& ...args) {
            (pack(args), ...);
        }, tuple);
    }
};

} // namespace msg

#endif // MSGPACK_HPP
