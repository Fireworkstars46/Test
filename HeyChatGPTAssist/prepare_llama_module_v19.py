from pathlib import Path

p = Path('llama.cpp/examples/llama.android/lib/build.gradle.kts')
s = p.read_text()
# Replace version-catalog plugin aliases with root-provided plugin IDs.
start = s.index('plugins {')
end = s.index('}\n\nandroid {', start) + 1
s = s[:start] + '''plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}''' + s[end:]
s = s.replace('compileSdk = 36', 'compileSdk = 35')
s = s.replace('minSdk = 33', 'minSdk = 31')
s = s.replace('abiFilters += listOf("arm64-v8a", "x86_64")', 'abiFilters += listOf("arm64-v8a")')
s = s.replace('arguments += "-DGGML_OPENMP=ON"', 'arguments += "-DGGML_OPENMP=OFF"')
# Avoid version-catalog dependencies. Keep only what the library needs.
dep = s.index('dependencies {')
s = s[:dep] + '''dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.datastore:datastore-preferences:1.1.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}
'''
# Use SDK CMake 3.22.1, available on CI.
s = s.replace('version = "3.31.6"', 'version = "3.22.1"')
p.write_text(s)

# Android-safe CMake settings. The example currently enables OpenMP for arm64;
# force it off for NDK packaging and lower the minimum CMake version.
p = Path('llama.cpp/examples/llama.android/lib/src/main/cpp/CMakeLists.txt')
s = p.read_text()
s = s.replace('cmake_minimum_required(VERSION 3.31.6)', 'cmake_minimum_required(VERSION 3.22.1)')
s = s.replace('set(GGML_OPENMP ON)', 'set(GGML_OPENMP OFF)')
p.write_text(s)
