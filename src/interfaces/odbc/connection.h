
/* File:            connection.h
 *
 * Description:     See "connection.c"
 *
 * Comments:        See "notice.txt" for copyright and license information.
 *
 */

#ifndef __CONNECTION_H__
#define __CONNECTION_H__

#include <windows.h>
#include <sql.h>
#include <sqlext.h>
#include "psqlodbc.h"

typedef enum {
    CONN_NOT_CONNECTED,      /* Connection has not been established */
    CONN_CONNECTED,      /* Connection is up and has been established */
    CONN_DOWN,            /* Connection is broken */
    CONN_EXECUTING     /* the connection is currently executing a statement */
} CONN_Status;

/*	These errors have general sql error state */
#define CONNECTION_SERVER_NOT_REACHED 1
#define CONNECTION_MSG_TOO_LONG 3
#define CONNECTION_COULD_NOT_SEND 4
#define CONNECTION_NO_SUCH_DATABASE 5
#define CONNECTION_BACKEND_CRAZY 6
#define CONNECTION_NO_RESPONSE 7
#define CONNECTION_SERVER_REPORTED_ERROR 8
#define CONNECTION_COULD_NOT_RECEIVE 9
#define CONNECTION_SERVER_REPORTED_WARNING 10
#define CONNECTION_NEED_PASSWORD 12

/*	These errors correspond to specific SQL states */
#define CONN_INIREAD_ERROR 1
#define CONN_OPENDB_ERROR 2
#define CONN_STMT_ALLOC_ERROR 3
#define CONN_IN_USE 4 
#define CONN_UNSUPPORTED_OPTION 5
/* Used by SetConnectoption to indicate unsupported options */
#define CONN_INVALID_ARGUMENT_NO 6
/* SetConnectOption: corresponds to ODBC--"S1009" */
#define CONN_TRANSACT_IN_PROGRES 7
#define CONN_NO_MEMORY_ERROR 8
#define CONN_NOT_IMPLEMENTED_ERROR 9
#define CONN_INVALID_AUTHENTICATION 10
#define CONN_AUTH_TYPE_UNSUPPORTED 11


/* Conn_status defines */
#define CONN_IN_AUTOCOMMIT 0x01
#define CONN_IN_TRANSACTION 0x02

/* AutoCommit functions */
#define CC_set_autocommit_off(x)	(x->transact_status &= ~CONN_IN_AUTOCOMMIT)
#define CC_set_autocommit_on(x)		(x->transact_status |= CONN_IN_AUTOCOMMIT)
#define CC_is_in_autocommit(x)		(x->transact_status & CONN_IN_AUTOCOMMIT)

/* Transaction in/not functions */
#define CC_set_in_trans(x)	(x->transact_status |= CONN_IN_TRANSACTION)
#define CC_set_no_trans(x)	(x->transact_status &= ~CONN_IN_TRANSACTION)
#define CC_is_in_trans(x)	(x->transact_status & CONN_IN_TRANSACTION)


/* Authentication types */
#define AUTH_REQ_OK			0
#define AUTH_REQ_KRB4		1
#define AUTH_REQ_KRB5		2
#define AUTH_REQ_PASSWORD	3
#define AUTH_REQ_CRYPT		4

/*	Startup Packet sizes */
#define SM_DATABASE		64
#define SM_USER			32
#define SM_OPTIONS		64
#define SM_UNUSED		64
#define SM_TTY			64

/*	Old 6.2 protocol defines */
#define NO_AUTHENTICATION	7
#define PATH_SIZE			64
#define ARGV_SIZE			64
#define NAMEDATALEN			16

typedef unsigned int ProtocolVersion;

#define PG_PROTOCOL(major, minor)	(((major) << 16) | (minor))
#define PG_PROTOCOL_LATEST		PG_PROTOCOL(1, 0)
#define PG_PROTOCOL_EARLIEST	PG_PROTOCOL(0, 0)

/*	This startup packet is to support latest Postgres protocol (6.3) */
typedef struct _StartupPacket
{
	ProtocolVersion	protoVersion;
	char			database[SM_DATABASE];
	char			user[SM_USER];
	char			options[SM_OPTIONS];
	char			unused[SM_UNUSED];
	char			tty[SM_TTY];
} StartupPacket;


/*	This startup packet is to support pre-Postgres 6.3 protocol */
typedef struct _StartupPacket6_2
{
	unsigned int	authtype;
	char			database[PATH_SIZE];
	char			user[NAMEDATALEN];
	char			options[ARGV_SIZE];
	char			execfile[ARGV_SIZE];
	char			tty[PATH_SIZE];
} StartupPacket6_2;


/*	Structure to hold all the connection attributes for a specific
	connection (used for both registry and file, DSN and DRIVER)
*/
typedef struct {
	char	dsn[MEDIUM_REGISTRY_LEN];
	char	desc[MEDIUM_REGISTRY_LEN];
	char	driver[MEDIUM_REGISTRY_LEN];
	char	server[MEDIUM_REGISTRY_LEN];
	char	database[MEDIUM_REGISTRY_LEN];
	char	username[MEDIUM_REGISTRY_LEN];
	char	password[MEDIUM_REGISTRY_LEN];
	char	conn_settings[LARGE_REGISTRY_LEN];
	char	protocol[SMALL_REGISTRY_LEN];
	char	port[SMALL_REGISTRY_LEN];
	char	readonly[SMALL_REGISTRY_LEN];	
//	char	unknown_sizes[SMALL_REGISTRY_LEN];
	char	fake_oid_index[SMALL_REGISTRY_LEN];
	char	show_oid_column[SMALL_REGISTRY_LEN];
	char	show_system_tables[SMALL_REGISTRY_LEN];
	char	focus_password;
} ConnInfo;

/*	Macro to determine is the connection using 6.2 protocol? */
#define PROTOCOL_62(conninfo_)		(strncmp((conninfo_)->protocol, PG62, strlen(PG62)) == 0)



/*******	The Connection handle	************/
struct ConnectionClass_ {
	HENV			henv;					/* environment this connection was created on */
	char			*errormsg;
	int				errornumber;
	CONN_Status		status;
	ConnInfo		connInfo;
	StatementClass	**stmts;
	int				num_stmts;
	SocketClass		*sock;
	int				lobj_type;
	char			transact_status;		/* Is a transaction is currently in progress */
	char			errormsg_created;		/* has an informative error msg been created?  */
};


/* Accessor functions */
#define CC_get_socket(x)	(x->sock)
#define CC_get_database(x)	(x->connInfo.database)
#define CC_get_server(x)	(x->connInfo.server)
#define CC_get_DSN(x)		(x->connInfo.dsn)
#define CC_get_username(x)	(x->connInfo.username)
#define CC_is_readonly(x)	(x->connInfo.readonly[0] == '1')


/*  for CC_DSN_info */
#define CONN_DONT_OVERWRITE		0
#define CONN_OVERWRITE			1 


/*	prototypes */
ConnectionClass *CC_Constructor();
char CC_Destructor(ConnectionClass *self);
int CC_cursor_count(ConnectionClass *self);
char CC_cleanup(ConnectionClass *self);
char CC_abort(ConnectionClass *self);
char CC_connect(ConnectionClass *self, char do_password);
char CC_add_statement(ConnectionClass *self, StatementClass *stmt);
char CC_remove_statement(ConnectionClass *self, StatementClass *stmt);
char CC_get_error(ConnectionClass *self, int *number, char **message);
QResultClass *CC_send_query(ConnectionClass *self, char *query, QResultClass *result_in, char *cursor);
void CC_clear_error(ConnectionClass *self);
char *CC_create_errormsg(ConnectionClass *self);
int CC_send_function(ConnectionClass *conn, int fnid, void *result_buf, int *actual_result_len, int result_is_int, LO_ARG *argv, int nargs);
char CC_send_settings(ConnectionClass *self);
void CC_lookup_lo(ConnectionClass *conn);

#endif
