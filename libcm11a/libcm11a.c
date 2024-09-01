
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <libserialport.h>

#include "libcm11a.h"

/*****************************************************************************/
/* wait 'millis' milliseconds for the socket to be able to write */
/* returns boolean */
static int
fd_can_write(int fd, int millis)
{
    fd_set wfds;
    struct timeval time;
    int rv;

    time.tv_sec = millis / 1000;
    time.tv_usec = (millis * 1000) % 1000000;
    FD_ZERO(&wfds);
    if (fd >= 0)
    {
        FD_SET(fd, &wfds);
        rv = select(fd + 1, 0, &wfds, 0, &time);
        if (rv > 0)
        {
            return 1;
        }
    }
    return 0;
}

/*****************************************************************************/
/* wait 'millis' milliseconds for the socket to be able to read */
/* returns boolean */
static int
fd_can_read(int fd, int millis)
{
    fd_set rfds;
    struct timeval time;
    int rv;

    time.tv_sec = millis / 1000;
    time.tv_usec = (millis * 1000) % 1000000;
    FD_ZERO(&rfds);
    if (fd >= 0)
    {
        FD_SET(fd, &rfds);
        rv = select(fd + 1, &rfds, 0, 0, &time);
        if (rv > 0)
        {
            return 1;
        }
    }
    return 0;
}

/*****************************************************************************/
static int
libcm11a_interface_ready(struct libcm11a_t *libcm11a)
{
    (void)libcm11a;
    return 0;
}

/*****************************************************************************/
static int
libcm11a_interface_poll(struct libcm11a_t *libcm11a)
{
    (void)libcm11a;
    return 0;
}

/*****************************************************************************/
static int
libcm11a_time_request(struct libcm11a_t *libcm11a)
{
    (void)libcm11a;
    return 0;
}

/*****************************************************************************/
static int
libcm11a_crc_ok(struct libcm11a_t *libcm11a)
{
    (void)libcm11a;
    return 0;
}

/*****************************************************************************/
static int
libcm11a_crc_not_ok(struct libcm11a_t *libcm11a)
{
    (void)libcm11a;
    return 0;
}

/*****************************************************************************/
static int
libcm11a_done_write(struct libcm11a_t *libcm11a)
{
    (void)libcm11a;
    return 0;
}

/*****************************************************************************/
int
libcm11a_create(const char* port_name, struct libcm11a_t** libcm11a)
{
    struct libcm11a_t* self;
    enum sp_return error;
    struct sp_port* port;
    int ok;
    int fd;

    if (port_name == NULL)
    {
        return 1;
    }
    if (libcm11a == NULL)
    {
        return 1;
    }
    ok = 0;
    error = sp_get_port_by_name(port_name, &port);
    if (error == SP_OK)
    {
        error = sp_open(port, SP_MODE_READ_WRITE);
        if (error == SP_OK)
        {
            error = sp_set_baudrate(port, 4800);
            if (error == SP_OK)
            {
                error = sp_set_stopbits(port, 1);
                if (error == SP_OK)
                {
                    error = sp_set_parity(port, SP_PARITY_NONE);
                    if (error == SP_OK)
                    {
                        error = sp_set_bits(port, 8);
                        if (error == SP_OK)
                        {
                            error = sp_get_port_handle(port, &fd);
                            if (error == SP_OK)
                            {
                                ok = 1;
                            }
                        }
                    }
                }
            }
        }
    }
    if (!ok)
    {
        return 1;
    }
    self = (struct libcm11a_t*)calloc(1, sizeof(struct libcm11a_t));
    if (self == NULL)
    {
        sp_close(self->port);
        return 1;
    }
    self->version = LIBCM11A_VERSION;
    self->fd = fd;
    self->port = port;
    self->port_name = strdup(port_name);
    /* app callbacks, set defaults */
    self->interface_ready = libcm11a_interface_ready;
    self->interface_poll = libcm11a_interface_poll;
    self->time_request = libcm11a_time_request;
    self->crc_ok = libcm11a_crc_ok;
    self->crc_not_ok = libcm11a_crc_not_ok;
	self->done_write = libcm11a_done_write;
    *libcm11a = self;
    return 0;
}

/*****************************************************************************/
int
libcm11a_destroy(struct libcm11a_t* libcm11a)
{
    if (libcm11a == NULL)
    {
        return 0;
    }
    sp_close(libcm11a->port);
    free(libcm11a->port_name);
    free(libcm11a);
    return 0;
}

/*****************************************************************************/
int
libcm11a_get_wait_objs_rw(struct libcm11a_t *libcm11a,
                          int *robjs, int *robj_count,
                          int *wobjs, int *wobj_count,
                          int *timeout)
{
    (void)timeout;
    robjs[*robj_count] = libcm11a->fd;
    (*robj_count)++;
	if (libcm11a->data != NULL)
	{
        wobjs[*wobj_count] = libcm11a->fd;
        (*wobj_count)++;
	}
    return 0;
}

/*****************************************************************************/
int
libcm11a_check_wait_objs(struct libcm11a_t *libcm11a)
{
    enum sp_return error;
    unsigned char in_buff[8];
    int rv;
	int to_send;

    rv = 0;
    if (fd_can_read(libcm11a->fd, 0))
    {
		error = sp_blocking_read(libcm11a->port, in_buff, 1, 0);
		if (error == 1)
		{
			if (libcm11a->want_crc)
			{
				if (in_buff[0] == libcm11a->crc)
				{
					rv = libcm11a->crc_ok(libcm11a);
				}
				else
				{
					rv = libcm11a->crc_not_ok(libcm11a);
				}
				libcm11a->want_crc = 0;
			}
			else
			{
				switch (in_buff[0])
				{
					case 0x55: /* interface ready */
						rv = libcm11a->interface_ready(libcm11a);
						break;
					case 0x5A: /* interface poll */
						rv = libcm11a->interface_poll(libcm11a);
						break;
					case 0xA5: /* time request */
						rv = libcm11a->time_request(libcm11a);
						break;
					default:
						rv = 1;
						break;
				}
			}
		}
		else
		{
			rv = 1;
		}
	}
	if (rv == 0)
	{
		if (libcm11a->data != NULL)
		{
		    if (fd_can_write(libcm11a->fd, 0))
			{
			    to_send = libcm11a->data_bytes - libcm11a->data_sent;
				error = sp_blocking_write(libcm11a->port,
				                          libcm11a->data,
										  to_send, 0);
				if (error > 0)
				{
				    libcm11a->data_sent += error;
					if (libcm11a->data_sent >= libcm11a->data_bytes)
					{
						free(libcm11a->data);
						libcm11a->data = NULL;
						libcm11a->data_sent = 0;
						libcm11a->data_bytes = 0;
						rv = libcm11a->done_write(libcm11a);
					}
				}
				else
				{
				 	rv = 1;
				}
			}
		}
	}
    return rv;
}

/*****************************************************************************/
int
libcm11a_write_data_crc(struct libcm11a_t *libcm11a,
                        const void* data, int data_bytes)
{
	int index;
 	unsigned int crc;

	if (libcm11a->data != NULL)
	{
		return 1;
	}
	libcm11a->data = (unsigned char*)malloc(data_bytes);
	libcm11a->data_bytes = data_bytes;
	libcm11a->data_sent = 0;
	memcpy(libcm11a->data, data, data_bytes);
	crc = 0;
	for (index = 0; index < data_bytes; index++)
	{
		crc += ((const unsigned char*)data)[index];
	}
	libcm11a->crc = crc & 0xFF;
	libcm11a->want_crc = 1;
	return 0;
}

/*****************************************************************************/
int
libcm11a_write_data(struct libcm11a_t *libcm11a,
                    const void* data, int data_bytes)
{
	if (libcm11a->data != NULL)
	{
		return 1;
	}
	libcm11a->data = (unsigned char*)malloc(data_bytes);
	libcm11a->data_bytes = data_bytes;
	libcm11a->data_sent = 0;
	memcpy(libcm11a->data, data, data_bytes);
	libcm11a->want_crc = 0;
	return 0;
}
