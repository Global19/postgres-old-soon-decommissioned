%{
/**********************************************************************
 * gram.y				- Parser for the PL/pgSQL
 *						  procedural language
 *
 * IDENTIFICATION
 *	  $PostgreSQL$
 *
 *	  This software is copyrighted by Jan Wieck - Hamburg.
 *
 *	  The author hereby grants permission  to  use,  copy,	modify,
 *	  distribute,  and	license this software and its documentation
 *	  for any purpose, provided that existing copyright notices are
 *	  retained	in	all  copies  and  that	this notice is included
 *	  verbatim in any distributions. No written agreement, license,
 *	  or  royalty  fee	is required for any of the authorized uses.
 *	  Modifications to this software may be  copyrighted  by  their
 *	  author  and  need  not  follow  the licensing terms described
 *	  here, provided that the new terms are  clearly  indicated  on
 *	  the first page of each file where they apply.
 *
 *	  IN NO EVENT SHALL THE AUTHOR OR DISTRIBUTORS BE LIABLE TO ANY
 *	  PARTY  FOR  DIRECT,	INDIRECT,	SPECIAL,   INCIDENTAL,	 OR
 *	  CONSEQUENTIAL   DAMAGES  ARISING	OUT  OF  THE  USE  OF  THIS
 *	  SOFTWARE, ITS DOCUMENTATION, OR ANY DERIVATIVES THEREOF, EVEN
 *	  IF  THE  AUTHOR  HAVE BEEN ADVISED OF THE POSSIBILITY OF SUCH
 *	  DAMAGE.
 *
 *	  THE  AUTHOR  AND	DISTRIBUTORS  SPECIFICALLY	 DISCLAIM	ANY
 *	  WARRANTIES,  INCLUDING,  BUT	NOT  LIMITED  TO,  THE	IMPLIED
 *	  WARRANTIES  OF  MERCHANTABILITY,	FITNESS  FOR  A  PARTICULAR
 *	  PURPOSE,	AND NON-INFRINGEMENT.  THIS SOFTWARE IS PROVIDED ON
 *	  AN "AS IS" BASIS, AND THE AUTHOR	AND  DISTRIBUTORS  HAVE  NO
 *	  OBLIGATION   TO	PROVIDE   MAINTENANCE,	 SUPPORT,  UPDATES,
 *	  ENHANCEMENTS, OR MODIFICATIONS.
 *
 **********************************************************************/

#include "plpgsql.h"

#include "parser/parser.h"

static PLpgSQL_expr		*read_sql_construct(int until,
											int until2,
											const char *expected,
											const char *sqlstart,
											bool isexpression,
											bool valid_sql,
											int *endtoken);
static	PLpgSQL_expr	*read_sql_stmt(const char *sqlstart);
static	PLpgSQL_type	*read_datatype(int tok);
static	PLpgSQL_stmt	*make_select_stmt(int lineno);
static	PLpgSQL_stmt	*make_fetch_stmt(int lineno, int curvar);
static	PLpgSQL_stmt	*make_return_stmt(int lineno);
static	PLpgSQL_stmt	*make_return_next_stmt(int lineno);
static	void			 check_assignable(PLpgSQL_datum *datum);
static	PLpgSQL_row		*read_into_scalar_list(const char *initial_name,
											   PLpgSQL_datum *initial_datum);
static	void			 check_sql_expr(const char *stmt);
static	void			 plpgsql_sql_error_callback(void *arg);
static	void			 check_labels(const char *start_label,
									  const char *end_label);

%}

%union {
		int32					ival;
		bool					boolean;
		char					*str;
		struct
		{
			char *name;
			int  lineno;
		}						varname;
		struct
		{
			char *name;
			int  lineno;
			PLpgSQL_rec     *rec;
			PLpgSQL_row     *row;
		}						forvariable;
		struct
		{
			char *label;
			int  n_initvars;
			int  *initvarnos;
		}						declhdr;
		struct
		{
			char *end_label;
			List *stmts;
		}						loop_body;
		List					*list;
		PLpgSQL_type			*dtype;
		PLpgSQL_datum			*scalar;	/* a VAR, RECFIELD, or TRIGARG */
		PLpgSQL_variable		*variable;	/* a VAR, REC, or ROW */
		PLpgSQL_var				*var;
		PLpgSQL_row				*row;
		PLpgSQL_rec				*rec;
		PLpgSQL_expr			*expr;
		PLpgSQL_stmt			*stmt;
		PLpgSQL_stmt_block		*program;
		PLpgSQL_condition		*condition;
		PLpgSQL_exception		*exception;
		PLpgSQL_exception_block	*exception_block;
		PLpgSQL_nsitem			*nsitem;
		PLpgSQL_diag_item		*diagitem;
}

%type <declhdr> decl_sect
%type <varname> decl_varname
%type <str>		decl_renname
%type <boolean>	decl_const decl_notnull exit_type
%type <expr>	decl_defval decl_cursor_query
%type <dtype>	decl_datatype
%type <row>		decl_cursor_args
%type <list>	decl_cursor_arglist
%type <nsitem>	decl_aliasitem
%type <str>		decl_stmts decl_stmt

%type <expr>	expr_until_semi expr_until_rightbracket
%type <expr>	expr_until_then expr_until_loop
%type <expr>	opt_exitcond

%type <ival>	assign_var cursor_variable
%type <var>		cursor_varptr
%type <variable>	decl_cursor_arg
%type <forvariable>	for_variable
%type <stmt>	for_control

%type <str>		opt_lblname opt_block_label opt_label
%type <str>		execsql_start

%type <list>	proc_sect proc_stmts stmt_else
%type <loop_body>	loop_body
%type <stmt>	proc_stmt pl_block
%type <stmt>	stmt_assign stmt_if stmt_loop stmt_while stmt_exit
%type <stmt>	stmt_return stmt_raise stmt_execsql
%type <stmt>	stmt_for stmt_select stmt_perform
%type <stmt>	stmt_dynexecute stmt_getdiag
%type <stmt>	stmt_open stmt_fetch stmt_close stmt_null

%type <list>	proc_exceptions
%type <exception_block> exception_sect
%type <exception>	proc_exception
%type <condition>	proc_conditions


%type <ival>	raise_level
%type <str>		raise_msg

%type <list>	getdiag_list
%type <diagitem> getdiag_list_item
%type <ival>	getdiag_kind getdiag_target

%type <ival>	lno

		/*
		 * Keyword tokens
		 */
%token	K_ALIAS
%token	K_ASSIGN
%token	K_BEGIN
%token	K_CLOSE
%token	K_CONSTANT
%token	K_CONTINUE
%token	K_CURSOR
%token	K_DEBUG
%token	K_DECLARE
%token	K_DEFAULT
%token	K_DIAGNOSTICS
%token	K_DOTDOT
%token	K_ELSE
%token	K_ELSIF
%token	K_END
%token	K_EXCEPTION
%token	K_EXECUTE
%token	K_EXIT
%token	K_FOR
%token	K_FETCH
%token	K_FROM
%token	K_GET
%token	K_IF
%token	K_IN
%token	K_INFO
%token	K_INTO
%token	K_IS
%token	K_LOG
%token	K_LOOP
%token	K_NEXT
%token	K_NOT
%token	K_NOTICE
%token	K_NULL
%token	K_OPEN
%token	K_OR
%token	K_PERFORM
%token	K_ROW_COUNT
%token	K_RAISE
%token	K_RENAME
%token	K_RESULT_OID
%token	K_RETURN
%token	K_REVERSE
%token	K_SELECT
%token	K_THEN
%token	K_TO
%token	K_TYPE
%token	K_WARNING
%token	K_WHEN
%token	K_WHILE

		/*
		 * Other tokens
		 */
%token	T_FUNCTION
%token	T_TRIGGER
%token	T_STRING
%token	T_NUMBER
%token	T_SCALAR				/* a VAR, RECFIELD, or TRIGARG */
%token	T_ROW
%token	T_RECORD
%token	T_DTYPE
%token	T_LABEL
%token	T_WORD
%token	T_ERROR

%token	O_OPTION
%token	O_DUMP

%%

pl_function		: T_FUNCTION comp_optsect pl_block opt_semi
					{
						yylval.program = (PLpgSQL_stmt_block *)$3;
					}
				| T_TRIGGER comp_optsect pl_block opt_semi
					{
						yylval.program = (PLpgSQL_stmt_block *)$3;
					}
				;

comp_optsect	:
				| comp_options
				;

comp_options	: comp_options comp_option
				| comp_option
				;

comp_option		: O_OPTION O_DUMP
					{
						plpgsql_DumpExecTree = true;
					}
				;

opt_semi		:
				| ';'
				;

pl_block		: decl_sect K_BEGIN lno proc_sect exception_sect K_END opt_label
					{
						PLpgSQL_stmt_block *new;

						new = palloc0(sizeof(PLpgSQL_stmt_block));

						new->cmd_type	= PLPGSQL_STMT_BLOCK;
						new->lineno		= $3;
						new->label		= $1.label;
						new->n_initvars = $1.n_initvars;
						new->initvarnos = $1.initvarnos;
						new->body		= $4;
						new->exceptions	= $5;

						check_labels($1.label, $7);
						plpgsql_ns_pop();

						$$ = (PLpgSQL_stmt *)new;
					}
				;


decl_sect		: opt_block_label
					{
						plpgsql_ns_setlocal(false);
						$$.label	  = $1;
						$$.n_initvars = 0;
						$$.initvarnos = NULL;
						plpgsql_add_initdatums(NULL);
					}
				| opt_block_label decl_start
					{
						plpgsql_ns_setlocal(false);
						$$.label	  = $1;
						$$.n_initvars = 0;
						$$.initvarnos = NULL;
						plpgsql_add_initdatums(NULL);
					}
				| opt_block_label decl_start decl_stmts
					{
						plpgsql_ns_setlocal(false);
						if ($3 != NULL)
							$$.label = $3;
						else
							$$.label = $1;
						$$.n_initvars = plpgsql_add_initdatums(&($$.initvarnos));
					}
				;

decl_start		: K_DECLARE
					{
						plpgsql_ns_setlocal(true);
					}
				;

decl_stmts		: decl_stmts decl_stmt
					{	$$ = $2;	}
				| decl_stmt
					{	$$ = $1;	}
				;

decl_stmt		: '<' '<' opt_lblname '>' '>'
					{	$$ = $3;	}
				| K_DECLARE
					{	$$ = NULL;	}
				| decl_statement
					{	$$ = NULL;	}
				;

decl_statement	: decl_varname decl_const decl_datatype decl_notnull decl_defval
					{
						PLpgSQL_variable	*var;

						var = plpgsql_build_variable($1.name, $1.lineno,
													 $3, true);
						if ($2)
						{
							if (var->dtype == PLPGSQL_DTYPE_VAR)
								((PLpgSQL_var *) var)->isconst = $2;
							else
								ereport(ERROR,
										(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
										 errmsg("row or record variable cannot be CONSTANT")));
						}
						if ($4)
						{
							if (var->dtype == PLPGSQL_DTYPE_VAR)
								((PLpgSQL_var *) var)->notnull = $4;
							else
								ereport(ERROR,
										(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
										 errmsg("row or record variable cannot be NOT NULL")));
						}
						if ($5 != NULL)
						{
							if (var->dtype == PLPGSQL_DTYPE_VAR)
								((PLpgSQL_var *) var)->default_val = $5;
							else
								ereport(ERROR,
										(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
										 errmsg("default value for row or record variable is not supported")));
						}
					}
				| decl_varname K_ALIAS K_FOR decl_aliasitem ';'
					{
						plpgsql_ns_additem($4->itemtype,
										   $4->itemno, $1.name);
					}
				| K_RENAME decl_renname K_TO decl_renname ';'
					{
						plpgsql_ns_rename($2, $4);
					}
				| decl_varname K_CURSOR
					{ plpgsql_ns_push(NULL); }
				  decl_cursor_args decl_is_from decl_cursor_query
					{
						PLpgSQL_var *new;
						PLpgSQL_expr *curname_def;
						char		buf[1024];
						char		*cp1;
						char		*cp2;

						/* pop local namespace for cursor args */
						plpgsql_ns_pop();

						new = (PLpgSQL_var *)
							plpgsql_build_variable($1.name, $1.lineno,
												   plpgsql_build_datatype(REFCURSOROID,
																		  -1),
												   true);

						curname_def = palloc0(sizeof(PLpgSQL_expr));

						curname_def->dtype = PLPGSQL_DTYPE_EXPR;
						strcpy(buf, "SELECT ");
						cp1 = new->refname;
						cp2 = buf + strlen(buf);
						if (strchr(cp1, '\\') != NULL)
							*cp2++ = ESCAPE_STRING_SYNTAX;
						*cp2++ = '\'';
						while (*cp1)
						{
							if (SQL_STR_DOUBLE(*cp1))
								*cp2++ = *cp1;
							*cp2++ = *cp1++;
						}
						strcpy(cp2, "'::refcursor");
						curname_def->query = pstrdup(buf);
						new->default_val = curname_def;

						new->cursor_explicit_expr = $6;
						if ($4 == NULL)
							new->cursor_explicit_argrow = -1;
						else
							new->cursor_explicit_argrow = $4->rowno;
					}
				;

decl_cursor_query :
					{
						PLpgSQL_expr *query;

						plpgsql_ns_setlocal(false);
						query = read_sql_stmt("");
						plpgsql_ns_setlocal(true);

						$$ = query;
					}
				;

decl_cursor_args :
					{
						$$ = NULL;
					}
				| '(' decl_cursor_arglist ')'
					{
						PLpgSQL_row *new;
						int i;
						ListCell *l;

						new = palloc0(sizeof(PLpgSQL_row));
						new->dtype = PLPGSQL_DTYPE_ROW;
						new->lineno = plpgsql_scanner_lineno();
						new->rowtupdesc = NULL;
						new->nfields = list_length($2);
						new->fieldnames = palloc(new->nfields * sizeof(char *));
						new->varnos = palloc(new->nfields * sizeof(int));

						i = 0;
						foreach (l, $2)
						{
							PLpgSQL_variable *arg = (PLpgSQL_variable *) lfirst(l);
							new->fieldnames[i] = arg->refname;
							new->varnos[i] = arg->dno;
							i++;
						}
						list_free($2);

						plpgsql_adddatum((PLpgSQL_datum *) new);
						$$ = new;
					}
				;

decl_cursor_arglist : decl_cursor_arg
					{
						$$ = list_make1($1);
					}
				| decl_cursor_arglist ',' decl_cursor_arg
					{
						$$ = lappend($1, $3);
					}
				;

decl_cursor_arg : decl_varname decl_datatype
					{
						$$ = plpgsql_build_variable($1.name, $1.lineno,
													$2, true);
					}
				;

decl_is_from	:	K_IS |		/* Oracle */
					K_FOR;		/* ANSI */

decl_aliasitem	: T_WORD
					{
						char	*name;
						PLpgSQL_nsitem *nsi;

						plpgsql_convert_ident(yytext, &name, 1);
						if (name[0] != '$')
							yyerror("only positional parameters may be aliased");

						plpgsql_ns_setlocal(false);
						nsi = plpgsql_ns_lookup(name, NULL);
						if (nsi == NULL)
						{
							plpgsql_error_lineno = plpgsql_scanner_lineno();
							ereport(ERROR,
									(errcode(ERRCODE_UNDEFINED_PARAMETER),
									 errmsg("function has no parameter \"%s\"",
											name)));
						}

						plpgsql_ns_setlocal(true);

						pfree(name);

						$$ = nsi;
					}
				;

decl_varname	: T_WORD
					{
						char	*name;

						plpgsql_convert_ident(yytext, &name, 1);
						$$.name = name;
						$$.lineno  = plpgsql_scanner_lineno();
					}
				;

decl_renname	: T_WORD
					{
						char	*name;

						plpgsql_convert_ident(yytext, &name, 1);
						/* the result must be palloc'd, see plpgsql_ns_rename */
						$$ = name;
					}
				;

decl_const		:
					{ $$ = false; }
				| K_CONSTANT
					{ $$ = true; }
				;

decl_datatype	:
					{
						/*
						 * If there's a lookahead token, read_datatype
						 * should consume it.
						 */
						$$ = read_datatype(yychar);
						yyclearin;
					}
				;

decl_notnull	:
					{ $$ = false; }
				| K_NOT K_NULL
					{ $$ = true; }
				;

decl_defval		: ';'
					{ $$ = NULL; }
				| decl_defkey
					{
						plpgsql_ns_setlocal(false);
						$$ = plpgsql_read_expression(';', ";");
						plpgsql_ns_setlocal(true);
					}
				;

decl_defkey		: K_ASSIGN
				| K_DEFAULT
				;

proc_sect		:
					{
						$$ = NIL;
					}
				| proc_stmts
					{ $$ = $1; }
				;

proc_stmts		: proc_stmts proc_stmt
						{
							if ($2 == NULL)
								$$ = $1;
							else
								$$ = lappend($1, $2);
						}
				| proc_stmt
						{
							if ($1 == NULL)
								$$ = NULL;
							else
								$$ = list_make1($1);
						}
				;

proc_stmt		: pl_block ';'
						{ $$ = $1; }
				| stmt_assign
						{ $$ = $1; }
				| stmt_if
						{ $$ = $1; }
				| stmt_loop
						{ $$ = $1; }
				| stmt_while
						{ $$ = $1; }
				| stmt_for
						{ $$ = $1; }
				| stmt_select
						{ $$ = $1; }
				| stmt_exit
						{ $$ = $1; }
				| stmt_return
						{ $$ = $1; }
				| stmt_raise
						{ $$ = $1; }
				| stmt_execsql
						{ $$ = $1; }
				| stmt_dynexecute
						{ $$ = $1; }
				| stmt_perform
						{ $$ = $1; }
				| stmt_getdiag
						{ $$ = $1; }
				| stmt_open
						{ $$ = $1; }
				| stmt_fetch
						{ $$ = $1; }
				| stmt_close
						{ $$ = $1; }
				| stmt_null
						{ $$ = $1; }
				;

stmt_perform	: K_PERFORM lno expr_until_semi
					{
						PLpgSQL_stmt_perform *new;

						new = palloc0(sizeof(PLpgSQL_stmt_perform));
						new->cmd_type = PLPGSQL_STMT_PERFORM;
						new->lineno   = $2;
						new->expr  = $3;

						$$ = (PLpgSQL_stmt *)new;
					}
				;

stmt_assign		: assign_var lno K_ASSIGN expr_until_semi
					{
						PLpgSQL_stmt_assign *new;

						new = palloc0(sizeof(PLpgSQL_stmt_assign));
						new->cmd_type = PLPGSQL_STMT_ASSIGN;
						new->lineno   = $2;
						new->varno = $1;
						new->expr  = $4;

						$$ = (PLpgSQL_stmt *)new;
					}
				;

stmt_getdiag	: K_GET K_DIAGNOSTICS lno getdiag_list ';'
					{
						PLpgSQL_stmt_getdiag	 *new;

						new = palloc0(sizeof(PLpgSQL_stmt_getdiag));
						new->cmd_type = PLPGSQL_STMT_GETDIAG;
						new->lineno   = $3;
						new->diag_items  = $4;

						$$ = (PLpgSQL_stmt *)new;
					}
				;

getdiag_list : getdiag_list ',' getdiag_list_item
					{
						$$ = lappend($1, $3);
					}
				| getdiag_list_item
					{
						$$ = list_make1($1);
					}
				;

getdiag_list_item : getdiag_target K_ASSIGN getdiag_kind
					{
						PLpgSQL_diag_item *new;

						new = palloc(sizeof(PLpgSQL_diag_item));
						new->target = $1;
						new->kind = $3;

						$$ = new;
					}
				;

getdiag_kind : K_ROW_COUNT
					{
						$$ = PLPGSQL_GETDIAG_ROW_COUNT;
					}
				| K_RESULT_OID
					{
						$$ = PLPGSQL_GETDIAG_RESULT_OID;
					}
				;

getdiag_target	: T_SCALAR
					{
						check_assignable(yylval.scalar);
						$$ = yylval.scalar->dno;
					}
				;


assign_var		: T_SCALAR
					{
						check_assignable(yylval.scalar);
						$$ = yylval.scalar->dno;
					}
				| T_ROW
					{
						check_assignable((PLpgSQL_datum *) yylval.row);
						$$ = yylval.row->rowno;
					}
				| T_RECORD
					{
						check_assignable((PLpgSQL_datum *) yylval.rec);
						$$ = yylval.rec->recno;
					}
				| assign_var '[' expr_until_rightbracket
					{
						PLpgSQL_arrayelem	*new;

						new = palloc0(sizeof(PLpgSQL_arrayelem));
						new->dtype		= PLPGSQL_DTYPE_ARRAYELEM;
						new->subscript	= $3;
						new->arrayparentno = $1;

						plpgsql_adddatum((PLpgSQL_datum *)new);

						$$ = new->dno;
					}
				;

stmt_if			: K_IF lno expr_until_then proc_sect stmt_else K_END K_IF ';'
					{
						PLpgSQL_stmt_if *new;

						new = palloc0(sizeof(PLpgSQL_stmt_if));
						new->cmd_type	= PLPGSQL_STMT_IF;
						new->lineno		= $2;
						new->cond		= $3;
						new->true_body	= $4;
						new->false_body = $5;

						$$ = (PLpgSQL_stmt *)new;
					}
				;

stmt_else		:
					{
						$$ = NIL;
					}
				| K_ELSIF lno expr_until_then proc_sect stmt_else
					{
						/*
						 * Translate the structure:	   into:
						 *
						 * IF c1 THEN				   IF c1 THEN
						 *	 ...						   ...
						 * ELSIF c2 THEN			   ELSE
						 *								   IF c2 THEN
						 *	 ...							   ...
						 * ELSE							   ELSE
						 *	 ...							   ...
						 * END IF						   END IF
						 *							   END IF
						 */
						PLpgSQL_stmt_if *new_if;

						/* first create a new if-statement */
						new_if = palloc0(sizeof(PLpgSQL_stmt_if));
						new_if->cmd_type	= PLPGSQL_STMT_IF;
						new_if->lineno		= $2;
						new_if->cond		= $3;
						new_if->true_body	= $4;
						new_if->false_body	= $5;

						/* wrap the if-statement in a "container" list */
						$$ = list_make1(new_if);
					}

				| K_ELSE proc_sect
					{
						$$ = $2;
					}
				;

stmt_loop		: opt_block_label K_LOOP lno loop_body
					{
						PLpgSQL_stmt_loop *new;

						new = palloc0(sizeof(PLpgSQL_stmt_loop));
						new->cmd_type = PLPGSQL_STMT_LOOP;
						new->lineno   = $3;
						new->label	  = $1;
						new->body	  = $4.stmts;

						check_labels($1, $4.end_label);
						plpgsql_ns_pop();

						$$ = (PLpgSQL_stmt *)new;
					}
				;

stmt_while		: opt_block_label K_WHILE lno expr_until_loop loop_body
					{
						PLpgSQL_stmt_while *new;

						new = palloc0(sizeof(PLpgSQL_stmt_while));
						new->cmd_type = PLPGSQL_STMT_WHILE;
						new->lineno   = $3;
						new->label	  = $1;
						new->cond	  = $4;
						new->body	  = $5.stmts;

						check_labels($1, $5.end_label);
						plpgsql_ns_pop();

						$$ = (PLpgSQL_stmt *)new;
					}
				;

stmt_for		: opt_block_label K_FOR for_control loop_body
					{
						/* This runs after we've scanned the loop body */
						if ($3->cmd_type == PLPGSQL_STMT_FORI)
						{
							PLpgSQL_stmt_fori		*new;

							new = (PLpgSQL_stmt_fori *) $3;
							new->label	  = $1;
							new->body	  = $4.stmts;
							$$ = (PLpgSQL_stmt *) new;
						}
						else if ($3->cmd_type == PLPGSQL_STMT_FORS)
						{
							PLpgSQL_stmt_fors		*new;

							new = (PLpgSQL_stmt_fors *) $3;
							new->label	  = $1;
							new->body	  = $4.stmts;
							$$ = (PLpgSQL_stmt *) new;
						}
						else
						{
							PLpgSQL_stmt_dynfors	*new;

							Assert($3->cmd_type == PLPGSQL_STMT_DYNFORS);
							new = (PLpgSQL_stmt_dynfors *) $3;
							new->label	  = $1;
							new->body	  = $4.stmts;
							$$ = (PLpgSQL_stmt *) new;
						}

						check_labels($1, $4.end_label);
						/* close namespace started in opt_label */
						plpgsql_ns_pop();
					}
				;

for_control		:
				lno for_variable K_IN
					{
						int			tok = yylex();

						/* Simple case: EXECUTE is a dynamic FOR loop */
						if (tok == K_EXECUTE)
						{
							PLpgSQL_stmt_dynfors	*new;
							PLpgSQL_expr			*expr;

							expr = plpgsql_read_expression(K_LOOP, "LOOP");

							new = palloc0(sizeof(PLpgSQL_stmt_dynfors));
							new->cmd_type = PLPGSQL_STMT_DYNFORS;
							new->lineno   = $1;
							if ($2.rec)
								new->rec = $2.rec;
							else if ($2.row)
								new->row = $2.row;
							else
							{
								plpgsql_error_lineno = $1;
								yyerror("loop variable of loop over rows must be a record or row variable");
							}
							new->query = expr;

							$$ = (PLpgSQL_stmt *) new;
						}
						else
						{
							PLpgSQL_expr	*expr1;
							bool			 reverse = false;

							/*
							 * We have to distinguish between two
							 * alternatives: FOR var IN a .. b and FOR
							 * var IN query. Unfortunately this is
							 * tricky, since the query in the second
							 * form needn't start with a SELECT
							 * keyword.  We use the ugly hack of
							 * looking for two periods after the first
							 * token. We also check for the REVERSE
							 * keyword, which means it must be an
							 * integer loop.
							 */
							if (tok == K_REVERSE)
								reverse = true;
							else
								plpgsql_push_back_token(tok);

							/*
							 * Read tokens until we see either a ".."
							 * or a LOOP. The text we read may not
							 * necessarily be a well-formed SQL
							 * statement, so we need to invoke
							 * read_sql_construct directly.
							 */
							expr1 = read_sql_construct(K_DOTDOT,
													   K_LOOP,
													   "LOOP",
													   "SELECT ",
													   true,
													   false,
													   &tok);

							if (tok == K_DOTDOT)
							{
								/* Saw "..", so it must be an integer loop */
								PLpgSQL_expr		*expr2;
								PLpgSQL_var			*fvar;
								PLpgSQL_stmt_fori	*new;

								/* First expression is well-formed */
								check_sql_expr(expr1->query);

								expr2 = plpgsql_read_expression(K_LOOP, "LOOP");

								fvar = (PLpgSQL_var *)
									plpgsql_build_variable($2.name,
														   $2.lineno,
														   plpgsql_build_datatype(INT4OID,
																				  -1),
														   true);

								/* put the for-variable into the local block */
								plpgsql_add_initdatums(NULL);

								new = palloc0(sizeof(PLpgSQL_stmt_fori));
								new->cmd_type = PLPGSQL_STMT_FORI;
								new->lineno   = $1;
								new->var	  = fvar;
								new->reverse  = reverse;
								new->lower	  = expr1;
								new->upper	  = expr2;

								$$ = (PLpgSQL_stmt *) new;
							}
							else
							{
								/*
								 * No "..", so it must be a query loop. We've prefixed an
								 * extra SELECT to the query text, so we need to remove that
								 * before performing syntax checking.
								 */
								char				*tmp_query;
								PLpgSQL_stmt_fors	*new;

								if (reverse)
									yyerror("cannot specify REVERSE in query FOR loop");

								Assert(strncmp(expr1->query, "SELECT ", 7) == 0);
								tmp_query = pstrdup(expr1->query + 7);
								pfree(expr1->query);
								expr1->query = tmp_query;

								check_sql_expr(expr1->query);

								new = palloc0(sizeof(PLpgSQL_stmt_fors));
								new->cmd_type = PLPGSQL_STMT_FORS;
								new->lineno   = $1;
								if ($2.rec)
									new->rec = $2.rec;
								else if ($2.row)
									new->row = $2.row;
								else
								{
									plpgsql_error_lineno = $1;
									yyerror("loop variable of loop over rows must be record or row variable");
								}

								new->query = expr1;
								$$ = (PLpgSQL_stmt *) new;
							}
						}
					}
				;

for_variable	: T_SCALAR
					{
						char		*name;

						plpgsql_convert_ident(yytext, &name, 1);
						$$.name = name;
						$$.lineno  = plpgsql_scanner_lineno();
						$$.rec = NULL;
						$$.row = NULL;
					}
				| T_WORD
					{
						char		*name;

						plpgsql_convert_ident(yytext, &name, 1);
						$$.name = name;
						$$.lineno  = plpgsql_scanner_lineno();
						$$.rec = NULL;
						$$.row = NULL;
					}
				| T_RECORD
					{
						char		*name;

						plpgsql_convert_ident(yytext, &name, 1);
						$$.name = name;
						$$.lineno  = plpgsql_scanner_lineno();
						$$.rec = yylval.rec;
						$$.row = NULL;
					}
				| T_ROW
					{
						char		*name;

						plpgsql_convert_ident(yytext, &name, 1);
						$$.name = name;
						$$.lineno  = plpgsql_scanner_lineno();
						$$.row = yylval.row;
						$$.rec = NULL;
					}
				;

stmt_select		: K_SELECT lno
					{
						$$ = make_select_stmt($2);
					}
				;

stmt_exit		: exit_type lno opt_label opt_exitcond
					{
						PLpgSQL_stmt_exit *new;

						new = palloc0(sizeof(PLpgSQL_stmt_exit));
						new->cmd_type = PLPGSQL_STMT_EXIT;
						new->is_exit  = $1;
						new->lineno	  = $2;
						new->label	  = $3;
						new->cond	  = $4;

						$$ = (PLpgSQL_stmt *)new;
					}
				;

exit_type		: K_EXIT
					{
						$$ = true;
					}
				| K_CONTINUE
					{
						$$ = false;
					}
				;

stmt_return		: K_RETURN lno
					{
						int	tok;

						tok = yylex();
						if (tok == K_NEXT)
						{
							$$ = make_return_next_stmt($2);
						}
						else
						{
							plpgsql_push_back_token(tok);
							$$ = make_return_stmt($2);
						}
					}
				;

stmt_raise		: K_RAISE lno raise_level raise_msg
					{
						PLpgSQL_stmt_raise		*new;
						int	tok;

						new = palloc(sizeof(PLpgSQL_stmt_raise));

						new->cmd_type	= PLPGSQL_STMT_RAISE;
						new->lineno		= $2;
						new->elog_level = $3;
						new->message	= $4;
						new->params		= NIL;

						tok = yylex();

						/*
						 * We expect either a semi-colon, which
						 * indicates no parameters, or a comma that
						 * begins the list of parameter expressions
						 */
						if (tok != ',' && tok != ';')
							yyerror("syntax error");

						if (tok == ',')
						{
							PLpgSQL_expr *expr;
							int term;

							for (;;)
							{
								expr = read_sql_construct(',', ';', ", or ;",
														  "SELECT ",
														  true, true, &term);
								new->params = lappend(new->params, expr);
								if (term == ';')
									break;
							}
						}

						$$ = (PLpgSQL_stmt *)new;
					}
				;

raise_msg		: T_STRING
					{
						$$ = plpgsql_get_string_value();
					}
				;

raise_level		: K_EXCEPTION
					{
						$$ = ERROR;
					}
				| K_WARNING
					{
						$$ = WARNING;
					}
				| K_NOTICE
					{
						$$ = NOTICE;
					}
				| K_INFO
					{
						$$ = INFO;
					}
				| K_LOG
					{
						$$ = LOG;
					}
				| K_DEBUG
					{
						$$ = DEBUG1;
					}
				;

loop_body		: proc_sect K_END K_LOOP opt_label ';'
					{
						$$.stmts = $1;
						$$.end_label = $4;
					}
				;

stmt_execsql	: execsql_start lno
					{
						PLpgSQL_stmt_execsql	*new;

						new = palloc(sizeof(PLpgSQL_stmt_execsql));
						new->cmd_type = PLPGSQL_STMT_EXECSQL;
						new->lineno   = $2;
						new->sqlstmt  = read_sql_stmt($1);

						$$ = (PLpgSQL_stmt *)new;
					}
				;

stmt_dynexecute : K_EXECUTE lno
					{
						PLpgSQL_stmt_dynexecute *new;
						PLpgSQL_expr *expr;
						int endtoken;

						expr = read_sql_construct(K_INTO, ';', "INTO|;", "SELECT ",
												  true, true, &endtoken);

						new = palloc(sizeof(PLpgSQL_stmt_dynexecute));
						new->cmd_type = PLPGSQL_STMT_DYNEXECUTE;
						new->lineno   = $2;
						new->query    = expr;
						new->rec = NULL;
						new->row = NULL;

						/*
						 * If we saw "INTO", look for a following row
						 * var, record var, or list of scalars.
						 */
						if (endtoken == K_INTO)
						{
							switch (yylex())
							{
								case T_ROW:
									check_assignable((PLpgSQL_datum *) yylval.row);
									new->row = yylval.row;
									break;

								case T_RECORD:
									check_assignable((PLpgSQL_datum *) yylval.row);
									new->rec = yylval.rec;
									break;

								case T_SCALAR:
									new->row = read_into_scalar_list(yytext, yylval.scalar);
									break;

								default:
									plpgsql_error_lineno = $2;
									ereport(ERROR,
											(errcode(ERRCODE_SYNTAX_ERROR),
											 errmsg("syntax error at \"%s\"", yytext),
											 errdetail("Expected record variable, row variable, "
													   "or list of scalar variables.")));
							}
							if (yylex() != ';')
								yyerror("syntax error");
						}

						$$ = (PLpgSQL_stmt *)new;
					}
				;


stmt_open		: K_OPEN lno cursor_varptr
					{
						PLpgSQL_stmt_open *new;
						int				  tok;

						new = palloc0(sizeof(PLpgSQL_stmt_open));
						new->cmd_type = PLPGSQL_STMT_OPEN;
						new->lineno = $2;
						new->curvar = $3->varno;

						if ($3->cursor_explicit_expr == NULL)
						{
						    tok = yylex();
							if (tok != K_FOR)
							{
								plpgsql_error_lineno = $2;
								ereport(ERROR,
										(errcode(ERRCODE_SYNTAX_ERROR),
										 errmsg("syntax error at \"%s\"",
												yytext),
										 errdetail("Expected FOR to open a reference cursor.")));
							}

							tok = yylex();
							if (tok == K_EXECUTE)
							{
								new->dynquery = read_sql_stmt("SELECT ");
							}
							else
							{
								plpgsql_push_back_token(tok);
								new->query = read_sql_stmt("");
							}
						}
						else
						{
							if ($3->cursor_explicit_argrow >= 0)
							{
								char   *cp;

								tok = yylex();
								if (tok != '(')
								{
									plpgsql_error_lineno = plpgsql_scanner_lineno();
									ereport(ERROR,
											(errcode(ERRCODE_SYNTAX_ERROR),
											 errmsg("cursor \"%s\" has arguments",
													$3->refname)));
								}

								/*
								 * Push back the '(', else read_sql_stmt
								 * will complain about unbalanced parens.
								 */
								plpgsql_push_back_token(tok);

								new->argquery = read_sql_stmt("SELECT ");

								/*
								 * Now remove the leading and trailing parens,
								 * because we want "select 1, 2", not
								 * "select (1, 2)".
								 */
								cp = new->argquery->query;

								if (strncmp(cp, "SELECT", 6) != 0)
								{
									plpgsql_error_lineno = plpgsql_scanner_lineno();
									/* internal error */
									elog(ERROR, "expected \"SELECT (\", got \"%s\"",
										 new->argquery->query);
								}
								cp += 6;
								while (*cp == ' ') /* could be more than 1 space here */
									cp++;
								if (*cp != '(')
								{
									plpgsql_error_lineno = plpgsql_scanner_lineno();
									/* internal error */
									elog(ERROR, "expected \"SELECT (\", got \"%s\"",
										 new->argquery->query);
								}
								*cp = ' ';

								cp += strlen(cp) - 1;

								if (*cp != ')')
									yyerror("expected \")\"");
								*cp = '\0';
							}
							else
							{
								tok = yylex();
								if (tok == '(')
								{
									plpgsql_error_lineno = plpgsql_scanner_lineno();
									ereport(ERROR,
											(errcode(ERRCODE_SYNTAX_ERROR),
											 errmsg("cursor \"%s\" has no arguments",
													$3->refname)));
								}

								if (tok != ';')
								{
									plpgsql_error_lineno = plpgsql_scanner_lineno();
									ereport(ERROR,
											(errcode(ERRCODE_SYNTAX_ERROR),
											 errmsg("syntax error at \"%s\"",
													yytext)));
								}
							}
						}

						$$ = (PLpgSQL_stmt *)new;
					}
				;

stmt_fetch		: K_FETCH lno cursor_variable K_INTO
					{
						$$ = make_fetch_stmt($2, $3);
					}
				;

stmt_close		: K_CLOSE lno cursor_variable ';'
					{
						PLpgSQL_stmt_close *new;

						new = palloc(sizeof(PLpgSQL_stmt_close));
						new->cmd_type = PLPGSQL_STMT_CLOSE;
						new->lineno = $2;
						new->curvar = $3;

						$$ = (PLpgSQL_stmt *)new;
					}
				;

stmt_null		: K_NULL ';'
					{
						/* We do not bother building a node for NULL */
						$$ = NULL;
					}
				;

cursor_varptr	: T_SCALAR
					{
						if (yylval.scalar->dtype != PLPGSQL_DTYPE_VAR)
							yyerror("cursor variable must be a simple variable");

						if (((PLpgSQL_var *) yylval.scalar)->datatype->typoid != REFCURSOROID)
						{
							plpgsql_error_lineno = plpgsql_scanner_lineno();
							ereport(ERROR,
									(errcode(ERRCODE_DATATYPE_MISMATCH),
									 errmsg("\"%s\" must be of type cursor or refcursor",
											((PLpgSQL_var *) yylval.scalar)->refname)));
						}
						$$ = (PLpgSQL_var *) yylval.scalar;
					}
				;

cursor_variable	: T_SCALAR
					{
						if (yylval.scalar->dtype != PLPGSQL_DTYPE_VAR)
							yyerror("cursor variable must be a simple variable");

						if (((PLpgSQL_var *) yylval.scalar)->datatype->typoid != REFCURSOROID)
						{
							plpgsql_error_lineno = plpgsql_scanner_lineno();
							ereport(ERROR,
									(errcode(ERRCODE_DATATYPE_MISMATCH),
									 errmsg("\"%s\" must be of type refcursor",
											((PLpgSQL_var *) yylval.scalar)->refname)));
						}
						$$ = yylval.scalar->dno;
					}
				;

execsql_start	: T_WORD
					{ $$ = pstrdup(yytext); }
				| T_ERROR
					{ $$ = pstrdup(yytext); }
				;

exception_sect	:
					{ $$ = NULL; }
				| K_EXCEPTION lno
					{
						/*
						 * We use a mid-rule action to add these
						 * special variables to the namespace before
						 * parsing the WHEN clauses themselves.
						 */
						PLpgSQL_exception_block *new = palloc(sizeof(PLpgSQL_exception_block));
						PLpgSQL_variable *var;

						var = plpgsql_build_variable("sqlstate", $2,
													 plpgsql_build_datatype(TEXTOID, -1),
													 true);
						((PLpgSQL_var *) var)->isconst = true;
						new->sqlstate_varno = var->dno;

						var = plpgsql_build_variable("sqlerrm", $2,
													 plpgsql_build_datatype(TEXTOID, -1),
													 true);
						((PLpgSQL_var *) var)->isconst = true;
						new->sqlerrm_varno = var->dno;

						$<exception_block>$ = new;
					}
					proc_exceptions
					{
						PLpgSQL_exception_block *new = $<exception_block>3;
						new->exc_list = $4;

						$$ = new;
					}
				;

proc_exceptions	: proc_exceptions proc_exception
						{
							$$ = lappend($1, $2);
						}
				| proc_exception
						{
							$$ = list_make1($1);
						}
				;

proc_exception	: K_WHEN lno proc_conditions K_THEN proc_sect
					{
						PLpgSQL_exception *new;

						new = palloc0(sizeof(PLpgSQL_exception));
						new->lineno     = $2;
						new->conditions = $3;
						new->action	    = $5;

						$$ = new;
					}
				;

proc_conditions	: proc_conditions K_OR opt_lblname
						{
							PLpgSQL_condition	*old;

							for (old = $1; old->next != NULL; old = old->next)
								/* skip */ ;
							old->next = plpgsql_parse_err_condition($3);

							$$ = $1;
						}
				| opt_lblname
						{
							$$ = plpgsql_parse_err_condition($1);
						}
				;

expr_until_semi :
					{ $$ = plpgsql_read_expression(';', ";"); }
				;

expr_until_rightbracket :
					{ $$ = plpgsql_read_expression(']', "]"); }
				;

expr_until_then :
					{ $$ = plpgsql_read_expression(K_THEN, "THEN"); }
				;

expr_until_loop :
					{ $$ = plpgsql_read_expression(K_LOOP, "LOOP"); }
				;

opt_block_label	:
					{
						plpgsql_ns_push(NULL);
						$$ = NULL;
					}
				| '<' '<' opt_lblname '>' '>'
					{
						plpgsql_ns_push($3);
						$$ = $3;
					}
				;

opt_label	:
					{
						$$ = NULL;
					}
				| T_LABEL
					{
						char *label_name;
						plpgsql_convert_ident(yytext, &label_name, 1);
						$$ = label_name;
					}
				| T_WORD
					{
						/* just to give a better error than "syntax error" */
						yyerror("no such label");
					}
				;

opt_exitcond	: ';'
					{ $$ = NULL; }
				| K_WHEN expr_until_semi
					{ $$ = $2; }
				;

opt_lblname		: T_WORD
					{
						char	*name;

						plpgsql_convert_ident(yytext, &name, 1);
						$$ = name;
					}
				;

lno				:
					{
						$$ = plpgsql_error_lineno = plpgsql_scanner_lineno();
					}
				;

%%


#define MAX_EXPR_PARAMS  1024

/*
 * determine the expression parameter position to use for a plpgsql datum
 *
 * It is important that any given plpgsql datum map to just one parameter.
 * We used to be sloppy and assign a separate parameter for each occurrence
 * of a datum reference, but that fails for situations such as "select DATUM
 * from ... group by DATUM".
 *
 * The params[] array must be of size MAX_EXPR_PARAMS.
 */
static int
assign_expr_param(int dno, int *params, int *nparams)
{
	int		i;

	/* already have an instance of this dno? */
	for (i = 0; i < *nparams; i++)
	{
		if (params[i] == dno)
			return i+1;
	}
	/* check for array overflow */
	if (*nparams >= MAX_EXPR_PARAMS)
	{
		plpgsql_error_lineno = plpgsql_scanner_lineno();
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("too many variables specified in SQL statement")));
	}
	/* add new parameter dno to array */
	params[*nparams] = dno;
	(*nparams)++;
	return *nparams;
}


PLpgSQL_expr *
plpgsql_read_expression(int until, const char *expected)
{
	return read_sql_construct(until, 0, expected, "SELECT ", true, true, NULL);
}

static PLpgSQL_expr *
read_sql_stmt(const char *sqlstart)
{
	return read_sql_construct(';', 0, ";", sqlstart, false, true, NULL);
}

/*
 * Read a SQL construct and build a PLpgSQL_expr for it.
 *
 * until:		token code for expected terminator
 * until2:		token code for alternate terminator (pass 0 if none)
 * expected:	text to use in complaining that terminator was not found
 * sqlstart:	text to prefix to the accumulated SQL text
 * isexpression: whether to say we're reading an "expression" or a "statement"
 * valid_sql:   whether to check the syntax of the expr (prefixed with sqlstart)
 * endtoken:	if not NULL, ending token is stored at *endtoken
 *				(this is only interesting if until2 isn't zero)
 */
static PLpgSQL_expr *
read_sql_construct(int until,
				   int until2,
				   const char *expected,
				   const char *sqlstart,
				   bool isexpression,
				   bool valid_sql,
				   int *endtoken)
{
	int					tok;
	int					lno;
	PLpgSQL_dstring		ds;
	int					parenlevel = 0;
	int					nparams = 0;
	int					params[MAX_EXPR_PARAMS];
	char				buf[32];
	PLpgSQL_expr		*expr;

	lno = plpgsql_scanner_lineno();
	plpgsql_dstring_init(&ds);
	plpgsql_dstring_append(&ds, sqlstart);

	for (;;)
	{
		tok = yylex();
		if (tok == until && parenlevel == 0)
			break;
		if (tok == until2 && parenlevel == 0)
			break;
		if (tok == '(' || tok == '[')
			parenlevel++;
		else if (tok == ')' || tok == ']')
		{
			parenlevel--;
			if (parenlevel < 0)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("mismatched parentheses")));
		}
		/*
		 * End of function definition is an error, and we don't expect to
		 * hit a semicolon either (unless it's the until symbol, in which
		 * case we should have fallen out above).
		 */
		if (tok == 0 || tok == ';')
		{
			plpgsql_error_lineno = lno;
			if (parenlevel != 0)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("mismatched parentheses")));
			if (isexpression)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("missing \"%s\" at end of SQL expression",
								expected)));
			else
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("missing \"%s\" at end of SQL statement",
								expected)));
		}

		if (plpgsql_SpaceScanned)
			plpgsql_dstring_append(&ds, " ");

		switch (tok)
		{
			case T_SCALAR:
				snprintf(buf, sizeof(buf), " $%d ",
						 assign_expr_param(yylval.scalar->dno,
										   params, &nparams));
				plpgsql_dstring_append(&ds, buf);
				break;

			case T_ROW:
				snprintf(buf, sizeof(buf), " $%d ",
						 assign_expr_param(yylval.row->rowno,
										   params, &nparams));
				plpgsql_dstring_append(&ds, buf);
				break;

			case T_RECORD:
				snprintf(buf, sizeof(buf), " $%d ",
						 assign_expr_param(yylval.rec->recno,
										   params, &nparams));
				plpgsql_dstring_append(&ds, buf);
				break;

			default:
				plpgsql_dstring_append(&ds, yytext);
				break;
		}
	}

	if (endtoken)
		*endtoken = tok;

	expr = palloc(sizeof(PLpgSQL_expr) + sizeof(int) * nparams - sizeof(int));
	expr->dtype			= PLPGSQL_DTYPE_EXPR;
	expr->query			= pstrdup(plpgsql_dstring_get(&ds));
	expr->plan			= NULL;
	expr->nparams		= nparams;
	while(nparams-- > 0)
		expr->params[nparams] = params[nparams];
	plpgsql_dstring_free(&ds);

	if (valid_sql)
		check_sql_expr(expr->query);

	return expr;
}

static PLpgSQL_type *
read_datatype(int tok)
{
	int					lno;
	PLpgSQL_dstring		ds;
	PLpgSQL_type		*result;
	bool				needspace = false;
	int					parenlevel = 0;

	lno = plpgsql_scanner_lineno();

	/* Often there will be a lookahead token, but if not, get one */
	if (tok == YYEMPTY)
		tok = yylex();

	if (tok == T_DTYPE)
	{
		/* lexer found word%TYPE and did its thing already */
		return yylval.dtype;
	}

	plpgsql_dstring_init(&ds);

	while (tok != ';')
	{
		if (tok == 0)
		{
			plpgsql_error_lineno = lno;
			if (parenlevel != 0)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("mismatched parentheses")));
			ereport(ERROR,
					(errcode(ERRCODE_SYNTAX_ERROR),
					 errmsg("incomplete datatype declaration")));
		}
		/* Possible followers for datatype in a declaration */
		if (tok == K_NOT || tok == K_ASSIGN || tok == K_DEFAULT)
			break;
		/* Possible followers for datatype in a cursor_arg list */
		if ((tok == ',' || tok == ')') && parenlevel == 0)
			break;
		if (tok == '(')
			parenlevel++;
		else if (tok == ')')
			parenlevel--;
		if (needspace)
			plpgsql_dstring_append(&ds, " ");
		needspace = true;
		plpgsql_dstring_append(&ds, yytext);

		tok = yylex();
	}

	plpgsql_push_back_token(tok);

	plpgsql_error_lineno = lno;	/* in case of error in parse_datatype */

	result = plpgsql_parse_datatype(plpgsql_dstring_get(&ds));

	plpgsql_dstring_free(&ds);

	return result;
}

static PLpgSQL_stmt *
make_select_stmt(int lineno)
{
	PLpgSQL_dstring		ds;
	int					nparams = 0;
	int					params[MAX_EXPR_PARAMS];
	char				buf[32];
	PLpgSQL_expr		*expr;
	PLpgSQL_row			*row = NULL;
	PLpgSQL_rec			*rec = NULL;
	int					tok;
	bool				have_into = false;

	plpgsql_dstring_init(&ds);
	plpgsql_dstring_append(&ds, "SELECT ");

	while (1)
	{
		tok = yylex();

		if (tok == ';')
			break;
		if (tok == 0)
		{
			plpgsql_error_lineno = plpgsql_scanner_lineno();
			ereport(ERROR,
					(errcode(ERRCODE_SYNTAX_ERROR),
					 errmsg("unexpected end of function definition")));
		}
		if (tok == K_INTO)
		{
			if (have_into)
			{
				plpgsql_error_lineno = plpgsql_scanner_lineno();
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("INTO specified more than once")));
			}
			tok = yylex();
			switch (tok)
			{
				case T_ROW:
					row = yylval.row;
					have_into = true;
					break;

				case T_RECORD:
					rec = yylval.rec;
					have_into = true;
					break;

				case T_SCALAR:
					row = read_into_scalar_list(yytext, yylval.scalar);
					have_into = true;
					break;

				default:
					/* Treat the INTO as non-special */
					plpgsql_dstring_append(&ds, " INTO ");
					plpgsql_push_back_token(tok);
					break;
			}
			continue;
		}

		if (plpgsql_SpaceScanned)
			plpgsql_dstring_append(&ds, " ");

		switch (tok)
		{
			case T_SCALAR:
				snprintf(buf, sizeof(buf), " $%d ",
						 assign_expr_param(yylval.scalar->dno,
										   params, &nparams));
				plpgsql_dstring_append(&ds, buf);
				break;

			case T_ROW:
				snprintf(buf, sizeof(buf), " $%d ",
						 assign_expr_param(yylval.row->rowno,
										   params, &nparams));
				plpgsql_dstring_append(&ds, buf);
				break;

			case T_RECORD:
				snprintf(buf, sizeof(buf), " $%d ",
						 assign_expr_param(yylval.rec->recno,
										   params, &nparams));
				plpgsql_dstring_append(&ds, buf);
				break;

			default:
				plpgsql_dstring_append(&ds, yytext);
				break;
		}
	}

	expr = palloc(sizeof(PLpgSQL_expr) + sizeof(int) * nparams - sizeof(int));
	expr->dtype			= PLPGSQL_DTYPE_EXPR;
	expr->query			= pstrdup(plpgsql_dstring_get(&ds));
	expr->plan			= NULL;
	expr->nparams		= nparams;
	while(nparams-- > 0)
		expr->params[nparams] = params[nparams];
	plpgsql_dstring_free(&ds);

	check_sql_expr(expr->query);

	if (have_into)
	{
		PLpgSQL_stmt_select *select;

		select = palloc0(sizeof(PLpgSQL_stmt_select));
		select->cmd_type = PLPGSQL_STMT_SELECT;
		select->lineno   = lineno;
		select->rec		 = rec;
		select->row		 = row;
		select->query	 = expr;

		return (PLpgSQL_stmt *)select;
	}
	else
	{
		PLpgSQL_stmt_execsql *execsql;

		execsql = palloc(sizeof(PLpgSQL_stmt_execsql));
		execsql->cmd_type = PLPGSQL_STMT_EXECSQL;
		execsql->lineno   = lineno;
		execsql->sqlstmt  = expr;

		return (PLpgSQL_stmt *)execsql;
	}
}


static PLpgSQL_stmt *
make_fetch_stmt(int lineno, int curvar)
{
	int					tok;
	PLpgSQL_row		   *row = NULL;
	PLpgSQL_rec		   *rec = NULL;
	PLpgSQL_stmt_fetch *fetch;

	/* We have already parsed everything through the INTO keyword */

	tok = yylex();
	switch (tok)
	{
		case T_ROW:
			row = yylval.row;
			break;

		case T_RECORD:
			rec = yylval.rec;
			break;

		case T_SCALAR:
			row = read_into_scalar_list(yytext, yylval.scalar);
			break;

		default:
			yyerror("syntax error");
	}

	tok = yylex();
	if (tok != ';')
		yyerror("syntax error");

	fetch = palloc0(sizeof(PLpgSQL_stmt_fetch));
	fetch->cmd_type = PLPGSQL_STMT_FETCH;
	fetch->lineno	= lineno;
	fetch->rec		= rec;
	fetch->row		= row;
	fetch->curvar	= curvar;

	return (PLpgSQL_stmt *) fetch;
}


static PLpgSQL_stmt *
make_return_stmt(int lineno)
{
	PLpgSQL_stmt_return *new;

	new = palloc0(sizeof(PLpgSQL_stmt_return));
	new->cmd_type = PLPGSQL_STMT_RETURN;
	new->lineno   = lineno;
	new->expr	  = NULL;
	new->retvarno = -1;

	if (plpgsql_curr_compile->fn_retset)
	{
		if (yylex() != ';')
			yyerror("RETURN cannot have a parameter in function returning set; use RETURN NEXT");
	}
	else if (plpgsql_curr_compile->out_param_varno >= 0)
	{
		if (yylex() != ';')
			yyerror("RETURN cannot have a parameter in function with OUT parameters");
		new->retvarno = plpgsql_curr_compile->out_param_varno;
	}
	else if (plpgsql_curr_compile->fn_rettype == VOIDOID)
	{
		if (yylex() != ';')
			yyerror("RETURN cannot have a parameter in function returning void");
	}
	else if (plpgsql_curr_compile->fn_retistuple)
	{
		switch (yylex())
		{
			case K_NULL:
				/* we allow this to support RETURN NULL in triggers */
				break;

			case T_ROW:
				new->retvarno = yylval.row->rowno;
				break;

			case T_RECORD:
				new->retvarno = yylval.rec->recno;
				break;

			default:
				yyerror("RETURN must specify a record or row variable in function returning tuple");
				break;
		}
		if (yylex() != ';')
			yyerror("RETURN must specify a record or row variable in function returning tuple");
	}
	else
	{
		/*
		 * Note that a well-formed expression is
		 * _required_ here; anything else is a
		 * compile-time error.
		 */
		new->expr = plpgsql_read_expression(';', ";");
	}

	return (PLpgSQL_stmt *) new;
}


static PLpgSQL_stmt *
make_return_next_stmt(int lineno)
{
	PLpgSQL_stmt_return_next *new;

	if (!plpgsql_curr_compile->fn_retset)
		yyerror("cannot use RETURN NEXT in a non-SETOF function");

	new = palloc0(sizeof(PLpgSQL_stmt_return_next));
	new->cmd_type	= PLPGSQL_STMT_RETURN_NEXT;
	new->lineno		= lineno;
	new->expr		= NULL;
	new->retvarno	= -1;

	if (plpgsql_curr_compile->out_param_varno >= 0)
	{
		if (yylex() != ';')
			yyerror("RETURN NEXT cannot have a parameter in function with OUT parameters");
		new->retvarno = plpgsql_curr_compile->out_param_varno;
	}
	else if (plpgsql_curr_compile->fn_retistuple)
	{
		switch (yylex())
		{
			case T_ROW:
				new->retvarno = yylval.row->rowno;
				break;

			case T_RECORD:
				new->retvarno = yylval.rec->recno;
				break;

			default:
				yyerror("RETURN NEXT must specify a record or row variable in function returning tuple");
				break;
		}
		if (yylex() != ';')
			yyerror("RETURN NEXT must specify a record or row variable in function returning tuple");
	}
	else
		new->expr = plpgsql_read_expression(';', ";");

	return (PLpgSQL_stmt *) new;
}


static void
check_assignable(PLpgSQL_datum *datum)
{
	switch (datum->dtype)
	{
		case PLPGSQL_DTYPE_VAR:
			if (((PLpgSQL_var *) datum)->isconst)
			{
				plpgsql_error_lineno = plpgsql_scanner_lineno();
				ereport(ERROR,
						(errcode(ERRCODE_ERROR_IN_ASSIGNMENT),
						 errmsg("\"%s\" is declared CONSTANT",
								((PLpgSQL_var *) datum)->refname)));
			}
			break;
		case PLPGSQL_DTYPE_ROW:
			/* always assignable? */
			break;
		case PLPGSQL_DTYPE_REC:
			/* always assignable?  What about NEW/OLD? */
			break;
		case PLPGSQL_DTYPE_RECFIELD:
			/* always assignable? */
			break;
		case PLPGSQL_DTYPE_ARRAYELEM:
			/* always assignable? */
			break;
		case PLPGSQL_DTYPE_TRIGARG:
			yyerror("cannot assign to tg_argv");
			break;
		default:
			elog(ERROR, "unrecognized dtype: %d", datum->dtype);
			break;
	}
}

/*
 * Given the first datum and name in the INTO list, continue to read
 * comma-separated scalar variables until we run out. Then construct
 * and return a fake "row" variable that represents the list of
 * scalars.
 */
static PLpgSQL_row *
read_into_scalar_list(const char *initial_name,
					  PLpgSQL_datum *initial_datum)
{
	int				 nfields;
	char			*fieldnames[1024];
	int				 varnos[1024];
	PLpgSQL_row		*row;
	int				 tok;

	check_assignable(initial_datum);
	fieldnames[0] = pstrdup(initial_name);
	varnos[0]	  = initial_datum->dno;
	nfields		  = 1;

	while ((tok = yylex()) == ',')
	{
		/* Check for array overflow */
		if (nfields >= 1024)
		{
			plpgsql_error_lineno = plpgsql_scanner_lineno();
			ereport(ERROR,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("too many INTO variables specified")));
		}

		tok = yylex();
		switch(tok)
		{
			case T_SCALAR:
				check_assignable(yylval.scalar);
				fieldnames[nfields] = pstrdup(yytext);
				varnos[nfields++]	= yylval.scalar->dno;
				break;

			default:
				plpgsql_error_lineno = plpgsql_scanner_lineno();
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("\"%s\" is not a variable",
								yytext)));
		}
	}

	/*
	 * We read an extra, non-comma character from yylex(), so push it
	 * back onto the input stream
	 */
	plpgsql_push_back_token(tok);

	row = palloc(sizeof(PLpgSQL_row));
	row->dtype = PLPGSQL_DTYPE_ROW;
	row->refname = pstrdup("*internal*");
	row->lineno = plpgsql_scanner_lineno();
	row->rowtupdesc = NULL;
	row->nfields = nfields;
	row->fieldnames = palloc(sizeof(char *) * nfields);
	row->varnos = palloc(sizeof(int) * nfields);
	while (--nfields >= 0)
	{
		row->fieldnames[nfields] = fieldnames[nfields];
		row->varnos[nfields] = varnos[nfields];
	}

	plpgsql_adddatum((PLpgSQL_datum *)row);

	return row;
}

/*
 * When the PL/PgSQL parser expects to see a SQL statement, it is very
 * liberal in what it accepts; for example, we often assume an
 * unrecognized keyword is the beginning of a SQL statement. This
 * avoids the need to duplicate parts of the SQL grammar in the
 * PL/PgSQL grammar, but it means we can accept wildly malformed
 * input. To try and catch some of the more obviously invalid input,
 * we run the strings we expect to be SQL statements through the main
 * SQL parser.
 *
 * We only invoke the raw parser (not the analyzer); this doesn't do
 * any database access and does not check any semantic rules, it just
 * checks for basic syntactic correctness. We do this here, rather
 * than after parsing has finished, because a malformed SQL statement
 * may cause the PL/PgSQL parser to become confused about statement
 * borders. So it is best to bail out as early as we can.
 */
static void
check_sql_expr(const char *stmt)
{
	ErrorContextCallback  syntax_errcontext;
	ErrorContextCallback *previous_errcontext;
	MemoryContext oldCxt;

	if (!plpgsql_check_syntax)
		return;

	/*
	 * Setup error traceback support for ereport(). The previous
	 * ereport callback is installed by pl_comp.c, but we don't want
	 * that to be invoked (since it will try to transpose the syntax
	 * error to be relative to the CREATE FUNCTION), so temporarily
	 * remove it from the list of callbacks.
	 */
	Assert(error_context_stack->callback == plpgsql_compile_error_callback);

	previous_errcontext = error_context_stack;
	syntax_errcontext.callback = plpgsql_sql_error_callback;
	syntax_errcontext.arg = (char *) stmt;
	syntax_errcontext.previous = error_context_stack->previous;
	error_context_stack = &syntax_errcontext;

	oldCxt = MemoryContextSwitchTo(compile_tmp_cxt);
	(void) raw_parser(stmt);
	MemoryContextSwitchTo(oldCxt);

	/* Restore former ereport callback */
	error_context_stack = previous_errcontext;
}

static void
plpgsql_sql_error_callback(void *arg)
{
	char *sql_stmt = (char *) arg;

	Assert(plpgsql_error_funcname);

	errcontext("SQL statement in PL/PgSQL function \"%s\" near line %d",
			   plpgsql_error_funcname, plpgsql_error_lineno);
	internalerrquery(sql_stmt);
	internalerrposition(geterrposition());
	errposition(0);
}

static void
check_labels(const char *start_label, const char *end_label)
{
	if (end_label)
	{
		if (!start_label)
		{
			plpgsql_error_lineno = plpgsql_scanner_lineno();
			ereport(ERROR,
					(errcode(ERRCODE_SYNTAX_ERROR),
					 errmsg("end label \"%s\" specified for unlabelled block",
							end_label)));
		}

		if (strcmp(start_label, end_label) != 0)
		{
			plpgsql_error_lineno = plpgsql_scanner_lineno();
			ereport(ERROR,
					(errcode(ERRCODE_SYNTAX_ERROR),
					 errmsg("end label \"%s\" differs from block's label \"%s\"",
							end_label, start_label)));
		}
	}
}

#include "pl_scan.c"
