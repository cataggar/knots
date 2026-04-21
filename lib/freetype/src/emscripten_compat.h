#pragma once
// PNG loading is disabled via ftoption.h, so setjmp/longjmp are unreachable;
// stubbing avoids pulling in emcc's instrumented sjlj runtime.
#include <setjmp.h>
#undef setjmp
#define setjmp(x) 0
#undef longjmp
#define longjmp(x, y) __builtin_trap()
