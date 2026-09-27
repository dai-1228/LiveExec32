#ifndef LC32_DEBUG_LOG_H
#define LC32_DEBUG_LOG_H

#include <stdio.h>

/* Opt-in at build time; disabled logs do not evaluate their arguments. Keep
 * failures and actionable warnings outside these verbose trace macros. */
#ifndef LC32_DEBUG_LOGS
#define LC32_DEBUG_LOGS 0
#endif

#if LC32_DEBUG_LOGS
#define LC32_DEBUG_PRINTF(...) do { (void)printf(__VA_ARGS__); } while(0)
#define LC32_DEBUG_FPRINTF(...) do { (void)fprintf(__VA_ARGS__); } while(0)
#else
#define LC32_DEBUG_PRINTF(...) do {} while(0)
#define LC32_DEBUG_FPRINTF(...) do {} while(0)
#endif

#endif
