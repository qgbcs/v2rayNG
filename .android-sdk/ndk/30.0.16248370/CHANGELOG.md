# Changelog

Report issues to [GitHub].

For Android Studio issues, go to https://b.android.com and file a bug using the
Android Studio component, not the NDK component.

If you're a build system maintainer that needs to use the tools in the NDK
directly, see the [build system maintainers guide].

[GitHub]: https://github.com/android/ndk/issues
[build system maintainers guide]:
  https://android.googlesource.com/platform/ndk/+/mirror-goog-main-ndk/docs/BuildSystemMaintainers.md

## Announcements

## Changes

- Updated LLVM to clang-r574158c. See `clang_source_info.md` in the toolchain
  directory for version information.
  - [Issue 2073]: Fixed runtime segfault when using LTO and nested exception
    handlers.
  - [Issue 2172]: Fixed backend crash for ablas.
  - [Issue 2160]: Fixed Clang crash on invalid code.
  - [Issue 2204]: Fixed Clang-Tidy Segfault.
  - [Issue 2208]: Fixed false positive nodiscard warning on static member function calls.
  - [Issue 2215]: Fixed a compiler hang when compiling with `-O3` for ARM.
  - [Issue 2225]: Fixed compiler miscompilation involving references and pointers.
  - [Issue 2226]: Fixed compiler crash when compiling defaulted equality operator for AArch64.
  - [Issue 2230]: Fixed Clang modules compilation failure involving `wchar.h` redefinitions.
  - [Issue 2234]: Fixed LLDB not being able to read a shared library if it is the last entry in the APK.
  - [Issue 2243]: Fixed internal linkage functions in global module fragments.
  - Improved ARM code generation for dot product instructions.
- [Issue 2198]: Landed simpleperf prebuilts to work on Android 10.
- Upgraded the max API to 37 for NDK sysroots.

[Issue 2073]: https://github.com/android/ndk/issues/2073
[Issue 2160]: https://github.com/android/ndk/issues/2160
[Issue 2172]: https://github.com/android/ndk/issues/2172
[Issue 2198]: https://github.com/android/ndk/issues/2198
[Issue 2204]: https://github.com/android/ndk/issues/2204
[Issue 2208]: https://github.com/android/ndk/issues/2208
[Issue 2215]: https://github.com/android/ndk/issues/2215
[Issue 2225]: https://github.com/android/ndk/issues/2225
[Issue 2226]: https://github.com/android/ndk/issues/2226
[Issue 2230]: https://github.com/android/ndk/issues/2230
[Issue 2234]: https://github.com/android/ndk/issues/2234
[Issue 2243]: https://github.com/android/ndk/issues/2243
