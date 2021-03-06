// Duck low-level runtime system

#include "runtime.h"
#ifdef USE_BOEHM
#include <gc/gc.h>
#endif
#include <stdio.h>
#include <stdlib.h>

// Unfortunately, the Boehm GC doesn't seem to like the Haskell runtime,
// which causes values to be incorrectly freed.  The cabal boehm flag
// can enable it.

#ifdef USE_BOEHM
static void duck_runtime_init() __attribute__ ((constructor))
{
	GC_INIT();
}
#endif

value duck_malloc(size_t n)
{
#ifdef USE_BOEHM
    return GC_MALLOC(n);
#else
    return malloc(n);
#endif
}

value duck_malloc_atomic(size_t n)
{
#ifdef USE_BOEHM
    return GC_MALLOC_ATOMIC(n);
#else
	return malloc(n);
#endif
}
