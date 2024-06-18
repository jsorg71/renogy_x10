
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>

#include "renogy_influx_log.h"

static int g_log_level = 4;
static const char g_log_pre[][8] =
{
    "ERROR",
    "WARN",
    "INFO",
    "DEBUG"
};
static int g_log_fd = -1;
static int g_log_flags = LOG_FLAG_STDOUT;
static char g_log_filename[256];

struct log_line_t
{
    char line1[1024];
    char line2[2048];
};

/*****************************************************************************/
int
get_mstime(int* mstime)
{
    struct timespec ts;
    int the_tick;

    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    {
        return 1;
    }
    the_tick = ts.tv_nsec / 1000000;
    the_tick += ts.tv_sec * 1000;
    *mstime = the_tick;
    return 0;
}

/*****************************************************************************/
int
log_init(int flags, int log_level, const char* filename)
{
    g_log_flags = flags;
    g_log_level = log_level;
    if (flags & LOG_FLAG_FILE)
    {
        g_log_fd = open(filename,
                        O_WRONLY | O_CREAT | O_TRUNC,
                        S_IRUSR | S_IWUSR);
        if (g_log_fd == -1)
        {
            return 1;
        }
        if (chmod(filename, 0666) != 0)
        {
            close(g_log_fd);
            g_log_fd = -1;
            return 1;
        }
        strncpy(g_log_filename, filename, 255);
        g_log_filename[255] = 0;
    }
    return 0;
}

/*****************************************************************************/
int
log_deinit(void)
{
    if (g_log_fd != -1)
    {
        close(g_log_fd);
        unlink(g_log_filename);
    }
    return 0;
}

/*****************************************************************************/
int
logln(int log_level, const char* format, ...)
{
    va_list ap;
    int mstime;
    int len;
    struct log_line_t* log_line;

    if (log_level < g_log_level)
    {
        log_line = (struct log_line_t*)malloc(sizeof(struct log_line_t));
        if (log_line == NULL)
        {
            return 1;
        }
        va_start(ap, format);
        vsnprintf(log_line->line1, sizeof(log_line->line1), format, ap);
        va_end(ap);
        if (get_mstime(&mstime) != 0)
        {
            free(log_line);
            return 1;
        }
        len = snprintf(log_line->line2, sizeof(log_line->line2),
                       "[%10.10u][%s]%s\n",
                       mstime, g_log_pre[log_level % 4], log_line->line1);
        if (g_log_flags & LOG_FLAG_FILE)
        {
            if (g_log_fd == -1)
            {
                free(log_line);
                return 1;
            }
            if (len != write(g_log_fd, log_line->line2, len))
            {
                free(log_line);
                return 1;
            }
        }
        if (g_log_flags & LOG_FLAG_STDOUT)
        {
            printf("%s", log_line->line2);
        }
        free(log_line);
    }
    return 0;
}
