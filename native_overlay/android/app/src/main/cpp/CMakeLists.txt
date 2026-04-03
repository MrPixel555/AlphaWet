cmake_minimum_required(VERSION 3.18.1)
project(xrayjni)

add_library(xrayjni SHARED xray_jni.cpp)

find_library(log-lib log)

target_link_libraries(xrayjni ${log-lib})
