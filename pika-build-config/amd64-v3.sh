#! /bin/bash
export PIKA_BUILD_ARCH="amd64-v3"
export DEBIAN_FRONTEND="noninteractive"
export DEB_BUILD_MAINT_OPTIONS="optimize=+lto -march=x86-64-v3 -O3 -flto=auto"
export DEB_CFLAGS_MAINT_APPEND="-march=x86-64-v3 -O3 -flto=auto"
export DEB_CPPFLAGS_MAINT_APPEND="-march=x86-64-v3 -O3 -flto=auto"
export DEB_CXXFLAGS_MAINT_APPEND="-march=x86-64-v3 -O3 -flto=auto"
export DEB_LDFLAGS_MAINT_APPEND="-march=x86-64-v3 -O3 -flto=auto"
export DEB_BUILD_OPTIONS="nocheck notest terse"
export DPKG_GENSYMBOLS_CHECK_LEVEL=0
