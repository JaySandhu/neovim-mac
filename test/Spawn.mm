//
//  Neovim Mac Test
//  Spawn.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <XCTest/XCTest.h>
#include "spawn.hpp"

static int exitcode(int pid) {
    int status;

    for (;;) {
        int result = waitpid(pid, &status, 0);
        
        if (result != -1) {
            return WEXITSTATUS(status);
        } else if (errno != EINTR) {
            return false;
        }
    }
}

@interface testSpawn : XCTestCase
@end

// Tests are a bit finicky, they rely heavily on unmocked system calls.
@implementation testSpawn : XCTestCase

 - (void)setUp {
    [super setUp];
    [self setContinueAfterFailure:NO];
}

- (void)testExecutesFile {
    auto process = process_spawn("/bin/zsh", {"zsh", "-c", "exit 42"}, {}, {});
    XCTAssertEqual(process.error, 0);

    int code = exitcode(process.pid);
    XCTAssertEqual(code, 42);
}

- (void)testExecutesFileInPATH {
    auto process = process_spawnp("zsh", {"zsh", "-c", "exit 42"}, {}, {});
    XCTAssertEqual(process.error, 0);

    int code = exitcode(process.pid);
    XCTAssertEqual(code, 42);;
}

- (void)testSetsStandardOutput {
    unnamed_pipe pipe;
    int error = pipe.open();
    XCTAssertFalse(error, @"Pipe failed: %s", strerror(error));
    
    subprocess process = process_spawnp({"printf"},
                                        {"printf", "test"}, {},
                                        {.output = pipe.write_end()});

    XCTAssertFalse(process.error, "Spawn failed: %s", strerror(process.error));
    
    int code = exitcode(process.pid);
    XCTAssertFalse(code, "Non zero exitcode: %i", code);
    
    char buffer[256];
    ssize_t read_bytes = read(pipe.read_end(), buffer, sizeof(buffer));
    XCTAssertNotEqual(read_bytes, -1, "Read failed: %s", strerror(errno));
    
    XCTAssertEqual(std::string_view(buffer, read_bytes), "test");
}

- (void)testChildInheritsEnvironment {
    unnamed_pipe pipe;
    int error = pipe.open();
    XCTAssertFalse(error, @"Pipe failed: %s", strerror(error));;
    
    subprocess process = process_spawnp({"zsh"},
                                        {"zsh", "-c", "printf $HOME"},
                                        {"ENVTEST=test"},
                                        {.output = pipe.write_end()});
    
    XCTAssertFalse(process.error, "Spawn failed: %s", strerror(process.error));
    
    int code = exitcode(process.pid);
    XCTAssertFalse(code, "Non zero exitcode: %i", code);
    
    char buffer[256];
    ssize_t read_bytes = read(pipe.read_end(), buffer, sizeof(buffer));
    XCTAssertNotEqual(read_bytes, -1, "Read failed: %s", strerror(errno));
    
    XCTAssertEqual(std::string_view(buffer, read_bytes), getenv("HOME"));
}

- (void)testChildEnvironment {
    unnamed_pipe pipe;
    int error = pipe.open();
    XCTAssertFalse(error, @"Pipe failed: %s", strerror(error));;
    
    subprocess process = process_spawnp({"zsh"},
                                        {"zsh", "-c", "printf $ENVTEST"},
                                        {"ENVTEST=test"},
                                        {.output = pipe.write_end()});
    
    XCTAssertFalse(process.error, "Spawn failed: %s", strerror(process.error));
    
    int code = exitcode(process.pid);
    XCTAssertFalse(code, "Non zero exitcode: %i", code);
    
    char buffer[256];
    ssize_t read_bytes = read(pipe.read_end(), buffer, sizeof(buffer));
    XCTAssertNotEqual(read_bytes, -1, "Read failed: %s", strerror(errno));
    
    XCTAssertEqual(std::string_view(buffer, read_bytes), "test");
}

@end
