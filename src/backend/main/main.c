/*-------------------------------------------------------------------------
 *
 * main.c
 *	  Stub main() routine for the postgres executable.
 *
 * This does some essential startup tasks for any incarnation of postgres
 * (postmaster, standalone backend, or standalone bootstrap mode) and then
 * dispatches to the proper FooMain() routine for the incarnation.
 *
 *
 * Portions Copyright (c) 1996-2001, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  $Header$
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <pwd.h>
#include <unistd.h>
#if defined(USE_LOCALE) || defined(ENABLE_NLS)
#include <locale.h>
#endif

#if defined(__alpha) && defined(__osf__)
#include <sys/sysinfo.h>
#include "machine/hal_sysinfo.h"
#define ASSEMBLER
#include <sys/proc.h>
#undef ASSEMBLER
#endif
#if defined(__NetBSD__)
#include <sys/param.h>
#endif

#include "miscadmin.h"
#include "bootstrap/bootstrap.h"
#include "tcop/tcopprot.h"



int
main(int argc, char *argv[])
{
	int			len;
	struct passwd *pw;
	char	   *pw_name_persist;

	/*
	 * Place platform-specific startup hacks here.	This is the right
	 * place to put code that must be executed early in launch of either a
	 * postmaster, a standalone backend, or a standalone bootstrap run.
	 * Note that this code will NOT be executed when a backend or
	 * sub-bootstrap run is forked by the postmaster.
	 *
	 * XXX The need for code here is proof that the platform in question is
	 * too brain-dead to provide a standard C execution environment
	 * without help.  Avoid adding more here, if you can.
	 */

#if defined(__alpha)
#ifdef NOFIXADE
	int			buffer[] = {SSIN_UACPROC, UAC_SIGBUS};

#endif	 /* NOFIXADE */
#ifdef NOPRINTADE
	int			buffer[] = {SSIN_UACPROC, UAC_NOPRINT};

#endif	 /* NOPRINTADE */
#endif	 /* __alpha */

#if defined(NOFIXADE) || defined(NOPRINTADE)

#if defined(ultrix4)
	syscall(SYS_sysmips, MIPS_FIXADE, 0, NULL, NULL, NULL);
#endif

#if defined(__alpha)
	if (setsysinfo(SSI_NVPAIRS, buffer, 1, (caddr_t) NULL,
				   (unsigned long) NULL) < 0)
		fprintf(stderr, gettext("%s: setsysinfo failed: %s\n"), argv[0], strerror(errno));
#endif

#endif	 /* NOFIXADE || NOPRINTADE */

#ifdef __BEOS__
	/* BeOS-specific actions on startup */
	beos_startup(argc, argv);
#endif

#ifdef ENABLE_NLS
#ifdef LC_MESSAGES
	setlocale(LC_MESSAGES, "");
#endif
	bindtextdomain("postgres", LOCALEDIR);
	textdomain("postgres");
#endif

	/*
	 * Not-quite-so-platform-specific startup environment checks. Still
	 * best to minimize these.
	 */

	/*
	 * Skip permission checks if we're just trying to do --help or --version;
	 * otherwise root will get unhelpful failure messages from initdb.
	 */
	if (!(argc > 1
		  && (strcmp(argv[1], "--help") == 0 ||
			  strcmp(argv[1], "-?") == 0 ||
			  strcmp(argv[1], "--version") == 0 ||
			  strcmp(argv[1], "-V") == 0)))
	{
		/*
		 * Make sure we are not running as root.
		 *
		 * BeOS currently runs everything as root :-(, so this check must be
		 * temporarily disabled there...
		 */
#ifndef __BEOS__
		if (geteuid() == 0)
		{
			fprintf(stderr, gettext(
				"\"root\" execution of the PostgreSQL server is not permitted.\n\n"
				"The server must be started under an unprivileged user id to prevent\n"
				"a possible system security compromise.  See the documentation for\n"
				"more information on how to properly start the server.\n\n"
				));
			exit(1);
		}
#endif	 /* __BEOS__ */

		/*
		 * Also make sure that real and effective uids are the same.
		 * Executing Postgres as a setuid program from a root shell is a
		 * security hole, since on many platforms a nefarious subroutine could
		 * setuid back to root if real uid is root.  (Since nobody actually
		 * uses Postgres as a setuid program, trying to actively fix this
		 * situation seems more trouble than it's worth; we'll just expend the
		 * effort to check for it.)
		 */
		if (getuid() != geteuid())
		{
			fprintf(stderr, gettext("%s: real and effective user ids must match\n"),
					argv[0]);
			exit(1);
		}
	}

	/*
	 * Set up locale information from environment, in only the categories
	 * needed by Postgres; leave other categories set to default "C".
	 * (Note that CTYPE and COLLATE will be overridden later from
	 * pg_control if we are in an already-initialized database.  We set
	 * them here so that they will be available to fill pg_control during
	 * initdb.)
	 */
#ifdef USE_LOCALE
	setlocale(LC_CTYPE, "");
	setlocale(LC_COLLATE, "");
	setlocale(LC_MONETARY, "");
#endif

	/*
	 * Now dispatch to one of PostmasterMain, PostgresMain, or
	 * BootstrapMain depending on the program name (and possibly first
	 * argument) we were called with.  The lack of consistency here is
	 * historical.
	 */
	len = strlen(argv[0]);

	if (len >= 10 && strcmp(argv[0] + len - 10, "postmaster") == 0)
	{
		/* Called as "postmaster" */
		exit(PostmasterMain(argc, argv));
	}

	/*
	 * If the first argument is "-boot", then invoke bootstrap mode. Note
	 * we remove "-boot" from the arguments passed on to BootstrapMain.
	 */
	if (argc > 1 && strcmp(argv[1], "-boot") == 0)
		exit(BootstrapMain(argc - 1, argv + 1));

	/*
	 * Otherwise we're a standalone backend.  Invoke PostgresMain,
	 * specifying current userid as the "authenticated" Postgres user
	 * name.
	 */
	pw = getpwuid(geteuid());
	if (pw == NULL)
	{
		fprintf(stderr, gettext("%s: invalid current euid %d\n"),
				argv[0], (int) geteuid());
		exit(1);
	}
	/* Allocate new memory because later getpwuid() calls can overwrite it */
	pw_name_persist = strdup(pw->pw_name);

	exit(PostgresMain(argc, argv, argc, argv, pw_name_persist));
}
