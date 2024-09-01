
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>

#include "libcm11a.h"

static const char* g_desired_port = "/dev/ttyS0";

#define STATE_START		  	     	((void*)1)
#define STATE_SENT_ADDRESS       	((void*)2)
#define STATE_SENT_COMMAND 			((void*)3)
#define STATE_DONE 					((void*)4)

/*****************************************************************************/
static int
test1_interface_poll(struct libcm11a_t *libcm11a)
{
    (void)libcm11a;
    printf("test1_interface_poll:\n");
    return 0;
}

/*****************************************************************************/
static int
test1_time_request(struct libcm11a_t *libcm11a)
{
    printf("test1_time_request:\n");
	unsigned char mydata[1];
   	mydata[0] = 0x9B;
	libcm11a_write_data(libcm11a, mydata, 1);
    return 0;
}

/*****************************************************************************/
static int
test1_crc_ok(struct libcm11a_t* libcm11a)
{
    unsigned char mydata[1];
	(void)libcm11a;
    printf("test1_crc_ok:\n");
	mydata[0] = 0x00;
	libcm11a_write_data(libcm11a, mydata, 1);
	return 0;
}

/*****************************************************************************/
static int
test1_crc_not_ok(struct libcm11a_t* libcm11a)
{
	(void)libcm11a;
	printf("test1_crc_not_ok:\n");
	return 0;
}

/*****************************************************************************/
static int
test1_interface_ready(struct libcm11a_t* libcm11a)
{
	unsigned char mydata[2];

	printf("test1_interface_ready:\n");
	if (libcm11a->user[0] == STATE_SENT_ADDRESS)
	{
        mydata[0] = 0x06;
        mydata[1] = 0x62; /* on */
        //mydata[1] = 0x63; /* off */
		libcm11a_write_data_crc(libcm11a, mydata, 2);
		libcm11a->user[0] = STATE_SENT_COMMAND;
	}
	else if (libcm11a->user[0] == STATE_SENT_COMMAND)
	{
		libcm11a->user[0] = STATE_DONE;
	}

	return 0;
}

/*****************************************************************************/
static int
test1_done_write(struct libcm11a_t* libcm11a)
{
	(void)libcm11a;
	printf("test1_done_write:\n");
	return 0;
}

/*****************************************************************************/
int
main_loop(struct libcm11a_t* cm11a)
{
    fd_set rfds;
    fd_set wfds;
	int robjs[32];
    int wobjs[32];
	int robj_count;
	int wobj_count;
	int timeout;
	int error;
	int index;
	int max_fd;
    struct timeval time;
    struct timeval* ptime;

	cm11a->user[0] = STATE_START;
	for (;;)
	{
		FD_ZERO(&rfds);
		FD_ZERO(&wfds);
		max_fd = 0;
		timeout = 1000;
		robj_count = 0;
		wobj_count = 0;
		error = libcm11a_get_wait_objs_rw(cm11a,
		                                  robjs, &robj_count,
										  wobjs, &wobj_count,
										  &timeout);
		printf("main_loop: libcm11a_get_wait_objs_rw rv %d "
		       "robj_count %d wobj_count %d\n",
			   error, robj_count, wobj_count);
		if (error != 0)
		{
			break;
		}
		for (index = 0; index < robj_count; index++)
		{
			FD_SET(robjs[index], &rfds);
			if (robjs[index] > max_fd)
			{
				max_fd = robjs[index];
			}
		}
		for (index = 0; index < wobj_count; index++)
		{
			FD_SET(wobjs[index], &wfds);
			if (wobjs[index] > max_fd)
			{
				max_fd = wobjs[index];
			}
		}
		ptime = NULL;
		if (timeout >= 0)
		{
        	time.tv_sec = timeout / 1000;
        	time.tv_usec = (timeout * 1000) % 1000000;
			ptime = &time;
		}
		error = select(max_fd + 1, &rfds, &wfds, NULL, ptime);
		printf("main_loop: select rv %d\n", error);
		error = libcm11a_check_wait_objs(cm11a);
		printf("main_loop: libcm11a_check_wait_objs rv %d\n", error);
		if (error != 0)
		{
			break;
		}
		if (cm11a->user[0] == STATE_START)
		{
    		printf("main_loop: STATE_START sending adress\n");
			unsigned char mydata[2];
			mydata[0] = 0x04;
			mydata[1] = 0x6E;
			libcm11a_write_data_crc(cm11a, mydata, 2);
			cm11a->user[0] = STATE_SENT_ADDRESS;
			timeout = -1;
		}
		if (cm11a->user[0] == STATE_DONE)
		{
			break;
		}
	}
	return 0;
}

/*****************************************************************************/
int
main(int argc, char** argv)
{
    struct libcm11a_t* cm11a;
	int error;

	(void)argc;
	(void)argv;

	error = libcm11a_create(g_desired_port, &cm11a);
	printf("main: libcm11a_create rv %d\n", error);
	if (error == 0)
	{
		cm11a->interface_ready = test1_interface_ready;
		cm11a->interface_poll = test1_interface_poll;
		cm11a->time_request = test1_time_request;
	    cm11a->crc_ok = test1_crc_ok;
	    cm11a->crc_not_ok = test1_crc_not_ok;
		cm11a->done_write = test1_done_write;
		main_loop(cm11a);
		error = libcm11a_destroy(cm11a);
    	printf("main: libcm11a_destroy rv %d\n", error);
	}
    return 0;
}