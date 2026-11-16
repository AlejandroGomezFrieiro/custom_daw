cmake_minimum_required(VERSION 3.22)
project(te_bench VERSION 0.1.0)

# Tracktion Engine and its JUCE submodule, cloned by build.sh into the
# untracked third_party directory.
set(TE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/tracktion_engine" CACHE PATH "tracktion_engine checkout")
add_subdirectory(${TE_DIR}/modules/juce ${CMAKE_BINARY_DIR}/juce)
add_subdirectory(${TE_DIR}/modules ${CMAKE_BINARY_DIR}/tracktion)

juce_add_console_app(te_bench NEEDS_CURL FALSE NEEDS_WEB_BROWSER FALSE)
juce_generate_juce_header(te_bench)
target_compile_features(te_bench PRIVATE cxx_std_20)
target_sources(te_bench PRIVATE te_bench.cpp)

target_compile_definitions(te_bench PRIVATE
    JUCE_USE_CURL=0
    JUCE_WEB_BROWSER=0
    JUCE_STRICT_REFCOUNTEDPOINTER=1
    JUCE_MODAL_LOOPS_PERMITTED=1
    JUCE_PLUGINHOST_VST3=0
    JUCE_PLUGINHOST_LV2=0
    JUCE_PLUGINHOST_LADSPA=0
    JUCE_DISPLAY_SPLASH_SCREEN=0
    TRACKTION_LOG_DEVICES=0)

target_link_libraries(te_bench PRIVATE
    tracktion::tracktion_core
    tracktion::tracktion_engine
    tracktion::tracktion_graph
    juce::juce_audio_devices
    juce::juce_audio_processors
    juce::juce_audio_utils
    juce::juce_recommended_config_flags)

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_link_libraries(te_bench PRIVATE "-latomic")
endif()
