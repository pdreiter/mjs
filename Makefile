MAKEFLAGS += --warn-undefined-variables
SRCPATH = src
BUILD_DIR = build

RD ?= docker run -v $(CURDIR):$(CURDIR) --user=$(shell id -u):$(shell id -g) -w $(CURDIR)
DOCKER_GCC = clang
DOCKER_CLANG = clang

include $(SRCPATH)/mjs_sources.mk

TOP_HEADERS = $(addprefix $(SRCPATH)/, $(HEADERS))
TOP_MJS_PUBLIC_HEADERS = $(addprefix $(SRCPATH)/, $(MJS_PUBLIC_HEADERS))
TOP_MJS_SOURCES = $(addprefix $(SRCPATH)/, $(MJS_SOURCES))
TOP_COMMON_SOURCES = $(addprefix $(SRCPATH)/, $(COMMON_SOURCES))

CFLAGS_EXTRA ?=
MFLAGS += -I. -Isrc -Isrc/frozen
MFLAGS += -DMJS_MAIN -DMJS_EXPOSE_PRIVATE -DCS_ENABLE_STDIO -DMJS_ENABLE_DEBUG -I../frozen
MFLAGS += $(CFLAGS_EXTRA)
CFLAGS += -lm -std=c99 -Wall -Wextra -pedantic -g $(MFLAGS)
COMMON_CFLAGS = -DCS_MMAP -DMJS_MODULE_LINES
ASAN_CFLAGS = -fsanitize=address

.PHONY: all test test_full difftest ci-test

VERBOSE ?=
ifeq ($(VERBOSE),1)
Q :=
else
Q := @
endif

ifeq ($(OS),Windows_NT)
  UNAME_S := Windows
else
  UNAME_S := $(shell uname -s)
endif

ifeq ($(UNAME_S),Linux)
  COMMON_CFLAGS += -Wl,--no-as-needed -ldl
  ASAN_CFLAGS += -fsanitize=leak
endif

ifeq ($(UNAME_S),Darwin)
  MFLAGS += -D_DARWIN_C_SOURCE
endif

PROG = $(BUILD_DIR)/mjs

all: mjs.c mjs_no_common.c $(PROG)

TESTUTIL_FILES = $(SRCPATH)/common/cs_dirent.c \
                 $(SRCPATH)/common/cs_time.c   \
                 $(SRCPATH)/common/test_main.c \
                 $(SRCPATH)/common/test_util.c

mjs.h: $(TOP_MJS_PUBLIC_HEADERS) Makefile tools/amalgam.py
	@printf "AMALGAMATING $@\n"
	$(Q) (tools/amalgam.py \
    --autoinc -I src --prefix MJS --strict --license src/mjs_license.h \
    --first common/platform.h $(TOP_MJS_PUBLIC_HEADERS)) > $@

mjs.c: $(TOP_COMMON_SOURCES) $(TOP_MJS_SOURCES) mjs.h Makefile
	@printf "AMALGAMATING $@\n"
	$(Q) (tools/amalgam.py \
    --autoinc -I src -I src/frozen --prefix MJS --license src/mjs_license.h \
    --license src/mjs_license.h --public-header mjs.h --autoinc-ignore mjs_*_public.h \
    --first mjs_common_guard_begin.h,common/platform.h,common/platforms/platform_windows.h,common/platforms/platform_unix.h,common/platforms/platform_esp_lwip.h \
    $(TOP_COMMON_SOURCES) $(TOP_MJS_SOURCES)) > $@

mjs_no_common.c: $(TOP_MJS_SOURCES) mjs.h Makefile
	@printf "AMALGAMATING $@\n"
	$(Q) (tools/amalgam.py \
    --autoinc -I src -I src/frozen --prefix MJS --license src/mjs_license.h \
    --public-header mjs.h --ignore mjs.h,*common/*,*frozen.[ch] \
    --first mjs_common_guard_begin.h,common/platform.h,common/platforms/platform_windows.h,common/platforms/platform_unix.h,common/platforms/platform_esp_lwip.h \
    $(TOP_MJS_SOURCES)) > $@

CFLAGS += $(COMMON_CFLAGS)

# NOTE: we compile straight from sources, not from the single amalgamated file,
# in order to make sure that all sources include the right headers
$(PROG): $(TOP_MJS_SOURCES) $(TOP_COMMON_SOURCES) $(TOP_HEADERS) $(BUILD_DIR)
	clang $(CFLAGS) $(TOP_MJS_SOURCES) $(TOP_COMMON_SOURCES) -o $(PROG)

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/%.o: %.c $(TOP_HEADERS) mjs.h
	clang $(CFLAGS) $(CPPFLAGS) -c -o $@ $<

COMMON_TEST_FLAGS = -W -Wall -I. -Isrc -g3 -O0 $(COMMON_CFLAGS) $< $(TESTUTIL_FILES) -DMJS_MEMORY_STATS

#include $(REPO_ROOT)/common.mk

# ==== Test Variants ====
#
# We want to build tests with various combinations of different compilers and
# different options. In order to do that, there is some simple makefile magic:
#
# There is a function compile_test_with_compiler which takes compiler name, any
# compile flags, name for the binary, and declares a rule for building that
# binary.
#
# Now, there is a higher level function: compile_test_with_opt, which takes the
# optimization flag to use, binary name component, and it declares a rule for
# both clang and for gcc with given optimization flags (by means of the
# aforementioned compile_test_with_compiler). And there are more higher level
# function which add more flags, etc etc.
#
# ========================================
# Suppose you want to add more build variants, say with flags -DFOO=1 and
# -DFOO=2. Here's what you need to do:
#
# - Rename compile_test_all to compile_test_with_foo
# - Inside of your new fancy compile_test_with_foo function, adjust a bit each
#   invocation of the lower-level function, whatever it is:
#   to the arg 2, add "_$2", and replace empty arg 3 with this: "$1 $3".
# - Write new compile_test_all, which should call your new
#   compile_test_with_foo, like this:
#
#       define compile_test_all
#       $(eval $(call compile_test_with_foo,-DFOO=1,foo_1,))
#       $(eval $(call compile_test_with_foo,-DFOO=2,foo_2,))
#       endef
#
# - Done!
#
# ========================================

# test variants, will be populated by compile_test, called by
# compile_test_with_compiler, called by compile_test_with_opt, .... etc
TEST_VARIANTS =

# params:
#
# 1: binary name component, e.g. "clang_O1_offset_4_whatever_else"
# 2: docker image to run compiler and binary in
# 3: full path to compiler, like "/usr/bin/clang-3.6" or "/usr/bin/gcc"
# 4: compiler flags
define compile_test
$(BUILD_DIR)/unit_test_$1: tests/unit_test.c mjs.c $(TESTUTIL_FILES) $(BUILD_DIR)
	@echo BUILDING $$@ with $2[$3], flags: "'$4'"
	$(RD) --entrypoint $3 $2 $$(COMMON_TEST_FLAGS) $4 -ldl -lm -o $$@
	$(RD) --entrypoint ./$$@ $2

TEST_VARIANTS += $(BUILD_DIR)/unit_test_$1
endef

# params:
# 1: compiler to use, like "clang" or "gcc"
# 2: binary name component, typically the same as compiler: "clang" or "gcc"
# 3: additional compiler flags
define compile_test_with_compiler
$(eval $(call compile_test,$3,$1,$2,$4))
endef

# params:
# 1: optimization flag to use, like "-O0"
# 2: binary name component, like "O0" or whatever
# 3: additional compiler flags
define compile_test_with_opt
$(eval $(call compile_test_with_compiler,mgos/clang,/usr/bin/clang-3.6,clang_$2,$(ASAN_CFLAGS) $1 $3))
$(eval $(call compile_test_with_compiler,mgos/clang,/usr/bin/clang-3.6,clang_32bit_$2,-m32 $1 $3))
$(eval $(call compile_test_with_compiler,mgos/gcc,/usr/bin/gcc,gcc_$2,$1 $3))
endef

# params:
# 1: flag to use, like "-DMJS_INIT_OFFSET_SIZE=0", or just an empty string
# 2: binary name component, like "offset_something"
# 3: additional compiler flags
define compile_test_with_offset
$(eval $(call compile_test_with_opt,-O0,O0_$2,$1 $3))
$(eval $(call compile_test_with_opt,-O1,O1_$2,$1 $3))
$(eval $(call compile_test_with_opt,-O3,O3_$2,$1 $3))
endef


# params:
# 1: flag to use, like "-DMJS_AGGRESSIVE_GC", or just an empty string
# 2: binary name component, like "offset_something"
# 3: additional compiler flags
define compile_test_with_aggressive_gc
$(eval $(call compile_test_with_offset,,offset_def_$2,$1 $3))
$(eval $(call compile_test_with_offset,-DMJS_INIT_OFFSET_SIZE=0,offset_0_$2,$1 $3))
$(eval $(call compile_test_with_offset,-DMJS_INIT_OFFSET_SIZE=4,offset_4_$2,$1 $3))
endef

# compile ALL tests
define compile_test_all
$(eval $(call compile_test_with_aggressive_gc,-DMJS_AGGRESSIVE_GC,aggressive_gc_$2,$1 $3))
$(eval $(call compile_test_with_aggressive_gc,,nonaggressive_gc_$2,$1 $3))
endef

$(eval $(call compile_test_all))

# Run all tests from $(TEST_VARIANTS)
test_full: $(TEST_VARIANTS) $(PROG)
#	for f in $(TEST_VARIANTS); do \
#    echo ; echo running $$f; \
#    $$f; \
#  done

# Run just a single test (a first one from $(TEST_VARIANTS))
test: $(firstword $(TEST_VARIANTS))
#	$<

clean:
	rm -rf $(BUILD_DIR) *.obj mjs.c mjs.h _CL_*

difftest:
	@TMP=`mktemp -t checkout-diff.XXXXXX`; \
	git diff  >$$TMP ; \
	if [ -s "$$TMP" ]; then echo found diffs in checkout:; git status -s; head -n 50 "$$TMP"; exit 1; fi; \
	rm $$TMP

###################################  Windows targets for wine, with MSVC6

ci-test: $(BUILD_DIR) vc98 vc2017 test_full

$(PROG).exe: $(BUILD_DIR) $(TOP_HEADERS) mjs.c
	$(RD) mgos/vc98 wine cl mjs.c $(CLFLAGS) $(MFLAGS) /Fe$@

TEST_SOURCES = tests/unit_test.c $(TESTUTIL_FILES)
CLFLAGS = /DWIN32_LEAN_AND_MEAN /MD /O1 /TC /W2 /WX /I.. /I. /DNDEBUG /DMJS_MEMORY_STATS
vc98 vc2017: mjs.c mjs.h
	$(RD) mgos/$@ wine cl $(TEST_SOURCES) $(CLFLAGS) /Fe$@.exe
	$(RD) mgos/$@ wine ./$@.exe

