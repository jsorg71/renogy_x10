
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <netdb.h>
#include <fcntl.h>
#include <sys/errno.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <modbus.h>

#include "renogy_influx_log.h"

#define RENOGY_SERIAL_INFO ("/dev/ttyS0", 9600, 'N', 8, 1)
static const int g_renogy_id = 1;
static const int g_renogy_voltage_reg = 0x0101;

static const char* g_influx_database = "voltages";
static const char* g_influx_token =
    "Wh4XF_BN120-dvfZiI0T6L7DIdG7Ma8JnSMW6GnMTpT5"
    "uG4qDlBFsEGS_jwo9eBD2pf2jtra7sgi0ajl5R-oEA==";
static const char* g_influx_hostname = "server3.xrdp.org";
static const int g_influx_port = 8086;
static const int g_secs = 60;

static int g_term_pipe[2];

struct settings_info
{
    char log_filename[256];
    int daemonize;
    int pad0;
};

struct buffers_t
{
    char buffer_out[2048];
    char buffer_con[64];
    char buffer_in[1024];
    char influx_ip[64];
};

/*****************************************************************************/
static void
sig_int(int sig)
{
    (void)sig;
    if (write(g_term_pipe[1], "sig", 4) != 4)
    {
    }
}

/*****************************************************************************/
static void
sig_pipe(int sig)
{
    (void)sig;
}

/*****************************************************************************/
static int
process_args(int argc, char** argv, struct settings_info* settings)
{
    int index;

    if (argc < 2)
    {
        return 1;
    }
    for (index = 1; index < argc; index++)
    {
        if (strcmp("-D", argv[index]) == 0)
        {
            settings->daemonize = 1;
        }
        else if (strcmp("-F", argv[index]) == 0)
        {
        }
        else
        {
            return 1;
        }
    }
    return 0;
}

/*****************************************************************************/
static int
printf_help(int argc, char** argv)
{
    if (argc < 1)
    {
        return 0;
    }
    printf("%s: command line options\n", argv[0]);
    printf("    -D      run daemon, example -D\n");
    printf("    -F      run forground, example -F\n");
    return 0;
}

/*****************************************************************************/
static int
main_send_recv_loop(struct buffers_t* buffers, int sck, int end_send_time)
{
    int error;
    int buffer_out_bytes;
    int buffer_out_sent;
    int buffer_in_read;
    int now;
    int wait_mstime;
    int rv;
    int bm1;
    int max_fd;
    fd_set rfds;
    fd_set wfds;
    struct timeval time;

    memset(buffers->buffer_in, 0, sizeof(buffers->buffer_in));
    buffer_out_bytes = strlen(buffers->buffer_out);
    buffer_out_sent = 0;
    buffer_in_read = 0;
    for (;;)
    {
        rv = 1;
        FD_ZERO(&rfds);
        FD_ZERO(&wfds);
        FD_SET(sck, &rfds);
        max_fd = sck;
        if (buffer_out_sent < buffer_out_bytes)
        {
            FD_SET(sck, &wfds);
        }
        if (g_term_pipe[0] > max_fd)
        {
            max_fd = g_term_pipe[0];
        }
        FD_SET(g_term_pipe[0], &rfds);
        now = 0;
        if (get_mstime(&now) != 0)
        {
            LOGLN0((LOG_ERROR, LOGS "get_mstime failed", LOGP));
            break;
        }
        wait_mstime = end_send_time - now;
        if (wait_mstime < 0)
        {
            LOGLN0((LOG_ERROR, LOGS "out of time", LOGP));
            break;
        }
        time.tv_sec = wait_mstime / 1000;
        time.tv_usec = (wait_mstime * 1000) % 1000000;
        error = select(max_fd + 1, &rfds, &wfds, NULL, &time);
        if (error < 1)
        {
            if (error == 0)
            {
                /* timeout */
                if (strstr(buffers->buffer_in, "204 No Content") != NULL)
                {
                    /* all ok */
                    LOGLN10((LOG_INFO, LOGS "ok", LOGP));
                    rv = 0;
                    break;
                }
                LOGLN0((LOG_ERROR, LOGS "some http error [%s]", LOGP,
                        buffers->buffer_in));
                break;
            }
            LOGLN0((LOG_ERROR, LOGS "select failed", LOGP));
            break;
        }
        if (FD_ISSET(g_term_pipe[0], &rfds))
        {
            LOGLN0((LOG_INFO, LOGS "term set", LOGP));
            break;
        }
        if (FD_ISSET(sck, &rfds))
        {
            bm1 = sizeof(buffers->buffer_in) - 1;
            if (buffer_in_read >= bm1)
            {
                LOGLN0((LOG_ERROR, LOGS "too big read", LOGP));
                break;
            }
            error = recv(sck, buffers->buffer_in + buffer_in_read,
                         bm1 - buffer_in_read, 0);
            if (error < 1)
            {
                LOGLN0((LOG_ERROR, LOGS "read failed", LOGP));
                break;
            }
            buffer_in_read += error;
            LOGLN10((LOG_INFO, LOGS "read %d", LOGP, error));
        }
        if (FD_ISSET(sck, &wfds))
        {
            if (buffer_out_sent < buffer_out_bytes)
            {
                error = send(sck, buffers->buffer_out + buffer_out_sent,
                             buffer_out_bytes - buffer_out_sent, 0);
                if (error < 1)
                {
                    LOGLN0((LOG_ERROR, LOGS "write failed", LOGP));
                    break;
                }
                buffer_out_sent += error;
                LOGLN10((LOG_INFO, LOGS "write %d", LOGP, error));
            }
        }
    }
    return rv;
}

/*****************************************************************************/
static int
main_modbus_loop(struct buffers_t* buffers, modbus_t* ctx, int sck)
{
    int now;
    int start_send_time;
    int buffer_con_bytes;
    int error;
    int value;
    int end_send_time;
    int rv;
    uint16_t tab_rp_registers[4];

    for (;;)
    {
        rv = 1;
        now = 0;
        if (get_mstime(&now) != 0)
        {
            LOGLN0((LOG_ERROR, LOGS "get_mstime failed", LOGP));
            break;
        }
        start_send_time = now;
        memset(tab_rp_registers, 0, sizeof(tab_rp_registers));
        error = modbus_read_registers(ctx, g_renogy_voltage_reg, 1,
                                      tab_rp_registers);
        if (error == -1)
        {
            LOGLN0((LOG_ERROR, LOGS "modbus_read_registers failed", LOGP));
            break;
        }
        value = tab_rp_registers[0];
        snprintf(buffers->buffer_con, sizeof(buffers->buffer_con),
                 "renogy,host=serverA value=%d\n", value);
        buffer_con_bytes = strlen(buffers->buffer_con);
        snprintf(buffers->buffer_out, sizeof(buffers->buffer_out),
                 "POST /api/v2/write?org=org1&bucket=%s HTTP/1.1\r\n"
                 "Host: %s:%d\r\n"
                 "Authorization: Token %s\r\n"
                 "Content-Type: text/plain; charset=utf-8\r\n"
                 "Accept: application/json\r\n"
                 "Content-Length: %d\r\n\r\n%s",
                 g_influx_database,
                 g_influx_hostname,
                 g_influx_port,
                 g_influx_token,
                 buffer_con_bytes, buffers->buffer_con);
        end_send_time = start_send_time + g_secs * 1000;
        rv = main_send_recv_loop(buffers, sck, end_send_time);
        if (rv != 0)
        {
            break;
        }
    }
    LOGLN0((LOG_INFO, LOGS "cleanup", LOGP));
    return rv;
}

/*****************************************************************************/
static int
main_connect(struct buffers_t* buffers, modbus_t* ctx)
{
    int sck;
    int rv;
    int error;
    struct sockaddr_in serv_addr;
    struct hostent* he;

    rv = 1;
    sck = socket(AF_INET, SOCK_STREAM, 0);
    if (sck != -1)
    {
        LOGLN0((LOG_INFO, LOGS "tcp sck created ok", LOGP));
        he = gethostbyname(g_influx_hostname);
        if ((he != NULL) &&
            (he->h_addr_list != NULL) &&
            (he->h_addr_list[0] != NULL))
        {
            snprintf(buffers->influx_ip, sizeof(buffers->influx_ip), "%s",
                     inet_ntoa(*((struct in_addr*)(he->h_addr_list[0]))));
            memset(&serv_addr, 0, sizeof(serv_addr));
            serv_addr.sin_family = AF_INET;
            serv_addr.sin_addr.s_addr = inet_addr(buffers->influx_ip);
            serv_addr.sin_port = htons(g_influx_port);
            LOGLN0((LOG_INFO, LOGS "starting tcp connect", LOGP));
            error = connect(sck, (struct sockaddr*)&serv_addr,
                            sizeof(serv_addr));
            if (error == 0)
            {
                LOGLN0((LOG_INFO, LOGS "tcp connected", LOGP));
                rv = main_modbus_loop(buffers, ctx, sck);
            }
            else
            {
                LOGLN0((LOG_ERROR, LOGS "tcp connect failed", LOGP));
            }
        }
        else
        {
            LOGLN0((LOG_ERROR, LOGS "gethostbyname failed", LOGP));
        }
        close(sck);
    }
    else
    {
        LOGLN0((LOG_ERROR, LOGS "tcp socket create failed", LOGP));
    }
    return rv;
}

/*****************************************************************************/
static int
main_modbus(void)
{
    int rv;
    int error;
    struct buffers_t* buffers;
    modbus_t* ctx;
    modbus_error_recovery_mode er_mode;

    rv = 1;
    buffers = (struct buffers_t*)malloc(sizeof(struct buffers_t));
    if (buffers != NULL)
    {
        ctx = modbus_new_rtu RENOGY_SERIAL_INFO;
        if (ctx != NULL)
        {
            LOGLN0((LOG_INFO, LOGS "modbus_new_rtu ok", LOGP));
            er_mode = MODBUS_ERROR_RECOVERY_LINK |
                      MODBUS_ERROR_RECOVERY_PROTOCOL;
            error = modbus_set_error_recovery(ctx, er_mode);
            LOGLN0((LOG_INFO, LOGS "modbus_set_error_recovery error %d",
                    LOGP, error));
            modbus_set_slave(ctx, g_renogy_id);
            error = modbus_connect(ctx);
            if (error != -1)
            {
                LOGLN0((LOG_INFO, LOGS "connection ok", LOGP));
                rv = main_connect(buffers, ctx);
            }
            else
            {
                LOGLN0((LOG_ERROR, LOGS "connection failed [%s]", LOGP,
                        modbus_strerror(errno)));
            }
            modbus_free(ctx);
        }
        else
        {
            LOGLN0((LOG_ERROR, LOGS "modbus_new_rtu failed", LOGP));
        }
        free(buffers);
    }
    else
    {
        LOGLN0((LOG_ERROR, LOGS "malloc failed", LOGP));
    }
    return rv;
}


/*****************************************************************************/
static int
main_fgbg(struct settings_info* settings)
{
    int rv;
    int error;

    rv = 1;
    if (settings->daemonize)
    {
        error = fork();
        if (error == 0)
        { /* child */
            close(0);
            close(1);
            close(2);
            open("/dev/null", O_RDONLY);
            open("/dev/null", O_WRONLY);
            open("/dev/null", O_WRONLY);
            if (settings->log_filename[0] == 0)
            {
                snprintf(settings->log_filename,
                         sizeof(settings->log_filename),
                         "/tmp/renogy_influx_%d.log", getpid());
            }
            log_init(LOG_FLAG_FILE, 4, settings->log_filename);
            rv = main_modbus();
            log_deinit();
        }
        else if (error > 0)
        { /* parent */
            printf("start daemon with pid %d\n", error);
            rv = 0;
        }
        else
        {
            printf("fork failed\n");
        }
    }
    else
    {
        log_init(LOG_FLAG_STDOUT, 4, NULL);
        rv = main_modbus();
        log_deinit();
    }
    return rv;
}

/*****************************************************************************/
static int
main_settings(int argc, char** argv)
{
    int rv;
    struct settings_info* settings;

    rv = 1;
    settings = (struct settings_info*)calloc(1, sizeof(struct settings_info));
    if (settings != NULL)
    {
        if (process_args(argc, argv, settings) == 0)
        {
            rv = main_fgbg(settings);
        }
        else
        {
            printf_help(argc, argv);
            rv = 0;
        }
        free(settings);
    }
    return rv;
}

/*****************************************************************************/
int
main(int argc, char** argv)
{
    int rv;

    rv = 1;
    if (signal(SIGINT, sig_int) != SIG_ERR)
    {
        if (signal(SIGTERM, sig_int) != SIG_ERR)
        {
            if (signal(SIGPIPE, sig_pipe) != SIG_ERR)
            {
                if (pipe(g_term_pipe) == 0)
                {
                    rv = main_settings(argc, argv);
                    close(g_term_pipe[0]);
                    close(g_term_pipe[1]);
                }
            }
        }
    }
    return rv;
}
