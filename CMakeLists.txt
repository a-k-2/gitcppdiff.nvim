cmake_minimum_required(VERSION 3.20)
project(gitcppdiff VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(FetchContent)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

FetchContent_Declare(tree_sitter
  GIT_REPOSITORY https://github.com/tree-sitter/tree-sitter.git
  GIT_TAG v0.25.9 GIT_SHALLOW TRUE
  SOURCE_SUBDIR lib)
# The C++ grammar ships pre-generated sources; we compile them ourselves.
FetchContent_Declare(tree_sitter_cpp
  GIT_REPOSITORY https://github.com/tree-sitter/tree-sitter-cpp.git
  GIT_TAG v0.23.4 GIT_SHALLOW TRUE
  SOURCE_SUBDIR does-not-exist)
FetchContent_MakeAvailable(tree_sitter tree_sitter_cpp)

add_library(ts_cpp STATIC
  ${tree_sitter_cpp_SOURCE_DIR}/src/parser.c
  ${tree_sitter_cpp_SOURCE_DIR}/src/scanner.c)
target_include_directories(ts_cpp PUBLIC ${tree_sitter_cpp_SOURCE_DIR}/src)

add_executable(gitcppdiff
  src/main.cpp src/git.cpp src/parse.cpp src/diff.cpp src/projconfig.cpp src/companion.cpp
  src/render_pretty.cpp src/render_json.cpp)
target_compile_options(gitcppdiff PRIVATE -Wall -Wextra)
target_include_directories(gitcppdiff PRIVATE ${tree_sitter_SOURCE_DIR}/lib/include)
target_link_libraries(gitcppdiff PRIVATE tree-sitter ts_cpp)
install(TARGETS gitcppdiff RUNTIME DESTINATION bin)
