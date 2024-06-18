
#ifndef _RENOGY_INFLUX_LOG_H_
#define _RENOGY_INFLUX_LOG_H_

#define LOG_FLAG_FILE   1
#define LOG_FLAG_STDOUT 2

#define LOG_ERROR   0
#define LOG_WARN    1
#define LOG_INFO    2
#define LOG_DEBUG   3

#define LOGS "[%s][%d][%s]:"
#define LOGP __FILE__, __LINE__, __FUNCTION__

#if !defined(__FUNCTION__) && defined(__FUNC__)
#define LOG_PRE const char* __FUNCTION__ = __FUNC__; (void)__FUNCTION__;
#else
#define LOG_PRE
#endif

#define LOG_LEVEL 1
#if LOG_LEVEL > 0
#define LOGLN0(_args) do { LOG_PRE logln _args ; } while (0)
#else
#define LOGLN0(_args)
#endif
#if LOG_LEVEL > 10
#define LOGLN10(_args) do { LOG_PRE logln _args ; } while (0)
#else
#define LOGLN10(_args)
#endif

int
get_mstime(int* mstime);
int
log_init(int flags, int log_level, const char* filename);
int
log_deinit(void);
int
logln(int log_level, const char* format, ...);

#endif
