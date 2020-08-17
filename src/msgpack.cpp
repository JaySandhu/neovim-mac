//
//  Neovim Mac
//  msgpack.cpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <limits>
#include "msgpack.hpp"

namespace msg {

using detail::unsigned_equivalent;
using detail::byteswap;

namespace {

struct base_visitor {
    std::string buffer;
    
    template<typename Container, typename Callable>
    void append_container(const Container &container, char begin,
                          char end, Callable callback) {
        auto size = container.size();
        auto *ptr = container.begin();

        buffer.push_back(begin);
        
        if (size) {
            callback(ptr[0]);
            
            for (int i=1; i<size; ++i) {
                buffer.append(", ");
                callback(ptr[i]);
            }
        }
            
        buffer.push_back(end);
    }
};

struct to_string_visitor : base_visitor {
    void operator()(msg::null val) {
        buffer.append("null");
    }

    void operator()(msg::integer val) {
        buffer.append(std::to_string((uint64_t)val));
    }

    void operator()(msg::float64 val) {
        buffer.append(std::to_string(val));
    }

    void operator()(msg::boolean val) {
        buffer.append(val ? "True" : "False");
    }

    void operator()(msg::string val) {
        buffer.push_back('"');
        buffer.append(val);
        buffer.push_back('"');
    }

    void operator()(msg::binary val) {
        buffer.push_back('b');
        
        append_container(val, '\'', '\'', [this](unsigned char byte) {
            static constexpr char digits[] = "0123456789abcdef";
            buffer.push_back(digits[byte >> 4]);
            buffer.push_back(digits[byte & 15]);
        });
    }

    void operator()(msg::extension val) {
        buffer.append("(extension)");
    }

    void operator()(msg::array val) {
        append_container(val, '[', ']', [this](const msg::object &obj){
            std::visit(*this, obj);
        });
    }

    void operator()(msg::map val) {
        append_container(val, '{', '}', [this](const msg::pair &pair){
            std::visit(*this, pair.first);
            buffer.append(" : ");
            std::visit(*this, pair.second);
        });
    }

    void operator()(msg::invalid val) {
        buffer.append("(invalid)");
    }
};

struct type_string_visitor : base_visitor {
    void operator()(const msg::invalid&) {
        buffer.append("invalid");
    }
    
    void operator()(const msg::null&) {
        buffer.append("null");
    }

    void operator()(const msg::integer&) {
        buffer.append("integer");
    }
    
    void operator()(const msg::float64&) {
        buffer.append("float64");
    }

    void operator()(const msg::boolean&) {
        buffer.append("boolean");
    }

    void operator()(const msg::string&) {
        buffer.append("string");
    }

    void operator()(const msg::binary&) {
        buffer.append("binary");
    }

    void operator()(const msg::extension&) {
        buffer.append("extension");
    }

    void operator()(const msg::array &array) {
        append_container(array, '[', ']', [this](const msg::object &obj) {
            std::visit(*this, obj);
        });
    }

    void operator()(const msg::map &map) {
        append_container(map, '{', '}', [this](const msg::pair &pair) {
            std::visit(*this, pair.first);
            buffer.append(" : ");
            std::visit(*this, pair.second);
        });
    }
};

// Returns a reference to the promise_type of the current coroutine.
template<typename Promise>
auto get_current_promise() {
    struct promise_awaiter {
        Promise *promise;

        bool await_ready() {
            return false;
        }

        bool await_suspend(std::experimental::coroutine_handle<Promise> coro) {
            promise = &coro.promise();
            return false;
        }

        Promise& await_resume() {
            return *promise;
        }
    };

    return promise_awaiter();
}

class unpack_stack {
private:
    // Sanity checks for pointer arithmetic.
    static_assert(sizeof(object) * 2 == sizeof(pair));
    static_assert(offsetof(pair, first) == 0);
    static_assert(offsetof(pair, second) == sizeof(object));

    struct range {
        object *begin;
        object *end;
    };

    std::vector<range> stack;

public:
    unpack_stack() {
        stack.reserve(32);
    }

    void push_array(object *obj, object *dest, size_t count) {
        obj->emplace<array>(dest, count);
        stack.push_back(range{dest, dest + count});
    }

    void push_map(object *obj, pair *dest, size_t count) {
        obj->emplace<map>(dest, count);
        object *begin = reinterpret_cast<object*>(dest);
        stack.push_back(range{begin, begin + (count * 2)});
    }

    // Returns the next object to unpack. nullptr when done.
    object* pop() {
        while (!stack.empty()) {
            range &back = stack.back();
            object *ret = back.begin;

            if (++back.begin == back.end) {
                stack.pop_back();
            }

            return ret;
        }
        
        return nullptr;
    }
};

} // namespace

std::string to_string(const object &obj) {
    to_string_visitor visitor;
    std::visit(visitor, obj);
    return visitor.buffer;
}

std::string type_string(const object &obj) {
    type_string_visitor visitor;
    std::visit(visitor, obj);
    return visitor.buffer;
}

// Returns an Awaitable that reads size bytes into dest from the input buffer
auto unpacker::promise_type::read_bytes(void *dest, size_t size) {
    struct byte_reader {
        promise_type *self;
        void *dest;
        size_t size;

        // Try and complete the read without suspending if possible.
        bool await_ready() {
            if (self->length < size) return false;

            memcpy(dest, self->buffer, size);
            self->buffer += size;
            self->length -= size;
            return true;
        }

        // Called when await_read() returns false. I.e. when we need to read
        // more bytes than we have.
        void await_suspend(handle_type awaiter) {
            const size_t len = self->length;

            // Copy what we have, clear the input buffer, and set waitbuff and
            // waitlen to finish the memcpy.
            memcpy(dest, self->buffer, len);
            self->buffer = nullptr;
            self->length = 0;
            self->waitbuff = static_cast<char*>(dest) + len;
            self->waitlen = size - len;
        }

        void await_resume() const {}
    };

    return byte_reader{this, dest, size};
}

// Returns an Awaitable that reads a numeric Type T from the input buffer
template<typename T>
auto unpacker::promise_type::read_numeric() {
    struct numeric_reader {
        promise_type *self;
        unsigned_equivalent<T> storage;

        bool await_ready() {
            if (self->length < sizeof(T)) return false;

            memcpy(&storage, self->buffer, sizeof(T));
            self->buffer += sizeof(T);
            self->length -= sizeof(T);
            return true;
        }

        void await_suspend(handle_type handle) {
            const size_t len = self->length;

            memcpy(&storage, self->buffer, len);
            self->buffer = nullptr;
            self->length = 0;
            self->waitbuff = reinterpret_cast<char*>(&storage) + len;
            self->waitlen = sizeof(T) - len;
        }

        // Called when the coroutine is resumed. At this stage storage is
        // guaranteed to have been filled.
        T await_resume() {
            unsigned_equivalent<T> swapped = byteswap(storage);
            T ret;
            memcpy(&ret, &swapped, sizeof(T));
            return ret;
        }
    };

    return numeric_reader{this};
}

unpacker unpacker::make() {
    auto &promise = co_await get_current_promise<unpacker::promise_type>();

    bump_allocator allocator(16384);
    unpack_stack stack;

    object top_level_object;
    object *obj = &top_level_object;

unpack_object: // Label avoids excess indentation
    const unsigned char byte = co_await promise.read_numeric<unsigned char>();
    size_t length;

    switch (byte) {
        case 0x00 ... 0x7f:
            obj->emplace<integer>(byte);
            break;

        case 0x80 ... 0x8f:
            length = byte & 0b00001111u;
            goto unpack_map;

        case 0x90 ... 0x9f:
            length = byte & 0b00001111u;
            goto unpack_array;

        case 0xa0 ... 0xbf:
            length = byte & 0b00011111u;
            goto unpack_string;

        case 0xc0:
            obj->emplace<null>();
            break;

        case 0xc1:
            obj->emplace<invalid>();
            break;

        case 0xc2:
            obj->emplace<boolean>(false);
            break;

        case 0xc3:
            obj->emplace<boolean>(true);
            break;

        case 0xc4:
            length = co_await promise.read_numeric<uint8_t>();
            goto unpack_binary;

        case 0xc5:
            length = co_await promise.read_numeric<uint16_t>();
            goto unpack_binary;

        case 0xc6:
            length = co_await promise.read_numeric<uint32_t>();
            goto unpack_binary;

        case 0xc7:
            length = 1 + co_await promise.read_numeric<uint8_t>();
            goto unpack_extension;

        case 0xc8:
            length = 1 + co_await promise.read_numeric<uint16_t>();
            goto unpack_extension;

        case 0xc9:
            length = 1 + co_await promise.read_numeric<uint32_t>();
            goto unpack_extension;

        case 0xca:
            obj->emplace<float64>(co_await promise.read_numeric<float>());
            break;

        case 0xcb:
            obj->emplace<float64>(co_await promise.read_numeric<double>());
            break;

        case 0xcc:
            obj->emplace<integer>(co_await promise.read_numeric<uint8_t>());
            break;

        case 0xcd:
            obj->emplace<integer>(co_await promise.read_numeric<uint16_t>());
            break;

        case 0xce:
            obj->emplace<integer>(co_await promise.read_numeric<uint32_t>());
            break;

        case 0xcf:
            obj->emplace<integer>(co_await promise.read_numeric<uint64_t>());
            break;

        case 0xd0:
            obj->emplace<integer>(co_await promise.read_numeric<int8_t>());
            break;

        case 0xd1:
            obj->emplace<integer>(co_await promise.read_numeric<int16_t>());
            break;

        case 0xd2:
            obj->emplace<integer>(co_await promise.read_numeric<int32_t>());
            break;

        case 0xd3:
            obj->emplace<integer>(co_await promise.read_numeric<int64_t>());
            break;

        case 0xd4:
            length = 2;
            goto unpack_extension;

        case 0xd5:
            length = 3;
            goto unpack_extension;

        case 0xd6:
            length = 5;
            goto unpack_extension;

        case 0xd7:
            length = 9;
            goto unpack_extension;

        case 0xd8:
            length = 17;
            goto unpack_extension;

        case 0xd9:
            length = co_await promise.read_numeric<uint8_t>();
            goto unpack_string;

        case 0xda:
            length = co_await promise.read_numeric<uint16_t>();
            goto unpack_string;

        case 0xdb:
            length = co_await promise.read_numeric<uint32_t>();
            goto unpack_string;

        case 0xdc:
            length = co_await promise.read_numeric<uint16_t>();
            goto unpack_array;

        case 0xdd:
            length = co_await promise.read_numeric<uint32_t>();
            goto unpack_array;

        case 0xde:
            length = co_await promise.read_numeric<uint16_t>();
            goto unpack_map;

        case 0xdf:
            length = co_await promise.read_numeric<uint32_t>();
            goto unpack_map;

        case 0xe0 ... 0xff:
            obj->emplace<integer>(-256 | byte);
            break;

        unpack_binary: {
            if (length == 0) {
                obj->emplace<binary>();
                break;
            }

            auto *data = new (allocator) unsigned char[length];
            obj->emplace<binary>(data, length);
            co_await promise.read_bytes(data, length);
            break;
        }

        unpack_extension: {
            if (length == 0) {
                obj->emplace<extension>();
                break;
            }

            auto *data = new (allocator) char[length];
            obj->emplace<extension>(data, length);
            co_await promise.read_bytes(data, length);
            break;
        }

        unpack_string: {
            if (length == 0) {
                obj->emplace<string>();
                break;
            }

            auto *data = new (allocator) char[length];
            obj->emplace<string>(data, length);
            co_await promise.read_bytes(data, length);
            break;
        }

        unpack_array: {
            if (length == 0) {
                obj->emplace<array>();
                break;
            }

            object *data = new (allocator) object[length];
            stack.push_array(obj, data, length);
            break;
        }

        unpack_map: {
            if (length == 0) {
                obj->emplace<map>();
                break;
            }

            auto *pairs = new (allocator) pair[length];
            stack.push_map(obj, pairs, length);
            break;
        }

        default:
            __builtin_unreachable();
    }

    obj = stack.pop();

    if (!obj) {
        // stack.pop() returned nullptr - nothing is left to unpack.
        co_yield &top_level_object;

        // We've been resumed reset everything before we restart.
        allocator.dealloc_all();
        promise.obj = nullptr;
        obj = &top_level_object;
    }

    // Do it all over again.
    goto unpack_object;
}

} // namespace msg
